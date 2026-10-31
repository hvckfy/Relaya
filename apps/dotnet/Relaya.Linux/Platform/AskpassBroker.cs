using System;
using System.Collections.Concurrent;
using System.IO;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;

namespace Relaya.Platform;

/// Секреты для askpass без открытого доступа к Secret Service (M8, как на Mac и Windows).
/// Процесс, который запускает ssh/sftp, слушает UNIX-сокет в $XDG_RUNTIME_DIR/relaya (каталог 0700, сокет 0600)
/// и выдаёт одноразовый токен на учётку: ~60 с, одно использование, только после привязки к PID запущенного
/// ssh или sftp. Секрет отдаётся, только если собеседник (SO_PEERCRED) — тот же пользователь, его exe — наш
/// relaya, родитель — настоящий ssh (полный путь), и это либо привязанный процесс, либо потомок привязанного sftp.
/// Хосты, где ssh запускает программы из конфига (config_runs_commands), токен не получают (M8-1).
internal static class AskpassBroker
{
    private sealed record Grant(string Account, DateTime Expires) { public int Uses; public int Pid; }

    private static readonly ConcurrentDictionary<string, Grant> grants = new();
    private static readonly object startLock = new();
    private static string? socketPath;

    /// Путь сокета; RELAYA_ASKPASS_PIPE в окружении ssh — то же имя, что на Windows.
    public static string PipeName
    {
        get
        {
            lock (startLock)
            {
                if (socketPath == null)
                {
                    var runtime = Environment.GetEnvironmentVariable("XDG_RUNTIME_DIR");
                    var dir = Path.Combine(string.IsNullOrEmpty(runtime) ? Path.GetTempPath() : runtime, "relaya");
                    Directory.CreateDirectory(dir);
                    File.SetUnixFileMode(dir, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
                    var path = Path.Combine(dir, $"askpass-{Environment.ProcessId}-{Convert.ToHexString(RandomNumberGenerator.GetBytes(8)).ToLowerInvariant()}.sock");
                    var listener = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
                    listener.Bind(new UnixDomainSocketEndPoint(path));
                    File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
                    listener.Listen(8);
                    AppDomain.CurrentDomain.ProcessExit += (_, _) => { try { File.Delete(path); } catch (Exception) { } };
                    socketPath = path;
                    _ = Task.Run(() => Serve(listener));
                }
                return socketPath;
            }
        }
    }

    /// Клиентская сторона (askpass-режим).
    public static Stream Connect(string path)
    {
        var s = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
        s.Connect(new UnixDomainSocketEndPoint(path));
        return new NetworkStream(s, ownsSocket: true);
    }

    /// Связать токен с процессом, который мы только что запустили (без привязки токен не работает).
    public static void Bind(string token, int pid)
    {
        if (grants.TryGetValue(token, out var g)) lock (g) g.Pid = pid;
    }

    /// Токен на учётку: живёт 60 с, одно использование.
    public static string Issue(string account)
    {
        if (Askpass.RunsCommands(account)) return ""; // пустой токен не совпадёт ни с одним грантом
        _ = PipeName;
        foreach (var (k, g) in grants) if (g.Expires < DateTime.UtcNow) grants.TryRemove(k, out _);
        var token = Convert.ToHexString(RandomNumberGenerator.GetBytes(16));
        grants[token] = new Grant(account, DateTime.UtcNow.AddSeconds(60));
        return token;
    }

    private static async Task Serve(Socket listener)
    {
        while (true)
        {
            Socket client;
            try { client = await listener.AcceptAsync(); }
            catch (Exception) { await Task.Delay(1000); continue; }
            _ = Task.Run(() => Handle(client));
        }
    }

    private static void Handle(Socket client)
    {
        using var stream = new NetworkStream(client, ownsSocket: true);
        try
        {
            client.ReceiveTimeout = 5000;
            var reader = new StreamReader(stream, new UTF8Encoding(false), false, 1024, leaveOpen: true);
            var token = reader.ReadLine() ?? "";
            var prompt = reader.ReadLine() ?? "";
            var secret = Answer(client, token, prompt);
            stream.Write(Encoding.UTF8.GetBytes(secret != null ? "OK\n" + secret + "\n" : "NO\n"));
            stream.Flush();
        }
        catch (Exception) { }
    }

    private static string? Answer(Socket client, string token, string prompt)
    {
        if (!grants.TryGetValue(token, out var g)) return null;
        if (g.Expires < DateTime.UtcNow) { grants.TryRemove(token, out _); return null; }
        if (!PasswordPrompt.Matches(prompt)) return null;
        // Привязка ставится сразу после Process.Start; запрос пароля почти всегда позже, но подождём до 2 с.
        var bound = 0;
        for (var i = 0; i < 20 && bound <= 0; i++)
        {
            lock (g) bound = g.Pid;
            if (bound <= 0) System.Threading.Thread.Sleep(100);
        }
        if (bound <= 0) return null;
        if (Peer(client) is not { } peer || peer.Uid != getuid() || !CallerIsOurSsh(peer.Pid, bound)) return null;
        lock (g)
        {
            if (++g.Uses > 1) { grants.TryRemove(token, out _); return null; }
        }
        grants.TryRemove(token, out _);
        // Настройка «Подтверждать каждое использование пароля»: системный вопрос с «Нет» по умолчанию.
        if (Settings.GetFresh("security.confirmPassword", "0") == "1"
            && !Consent.Ask(Strings.L("ssh просит пароль %@:", g.Account) + "\n\n" + prompt)) return null;
        return CredentialStore.Read(g.Account);
    }

    // Клиент — наш relaya; родитель — настоящий ssh (полный путь из PATH). Либо родитель и есть привязанный ssh,
    // либо привязанный sftp — родитель этого ssh. Привязанный процесс — наш прямой потомок.
    private static bool CallerIsOurSsh(int client, int bound)
    {
        var self = Environment.ProcessPath;
        if (self == null || !SamePath(ImagePath(client), self)) return false;
        var parent = ParentOf(client);
        if (parent <= 0 || Dialogs.Which(Data.AppState.SshExe) is not { } ssh || !SamePath(ImagePath(parent), ssh)) return false;
        if (ParentOf(bound) != Environment.ProcessId) return false;
        if (parent == bound) return true;
        return ParentOf(parent) == bound && Dialogs.Which(Data.AppState.SftpExe) is { } sftp && SamePath(ImagePath(bound), sftp);
    }

    // Сравнение по настоящему файлу: /usr/bin/ssh и /bin/ssh (usrmerge) — один и тот же.
    private static bool SamePath(string? a, string b)
    {
        if (a == null) return false;
        try
        {
            var target = File.ResolveLinkTarget(b, returnFinalTarget: true)?.FullName ?? Path.GetFullPath(b);
            return string.Equals(Path.GetFullPath(a), target, StringComparison.Ordinal);
        }
        catch (Exception) { return false; }
    }

    // /proc/<pid>/exe — ссылка на исполняемый файл; ядро уже разрешило все симлинки.
    private static string? ImagePath(int pid)
    {
        try { return File.ResolveLinkTarget($"/proc/{pid}/exe", returnFinalTarget: false)?.FullName; }
        catch (Exception) { return null; }
    }

    // /proc/<pid>/stat: «pid (comm) state ppid …»; comm может содержать пробелы и скобки — режем по последней «)».
    private static int ParentOf(int pid)
    {
        try
        {
            var stat = File.ReadAllText($"/proc/{pid}/stat");
            var fields = stat[(stat.LastIndexOf(')') + 2)..].Split(' ');
            return int.Parse(fields[1]);
        }
        catch (Exception) { return -1; }
    }

    private readonly record struct Cred(int Pid, uint Uid);

    // SO_PEERCRED: struct ucred { pid_t pid; uid_t uid; gid_t gid; } — ядро заполняет на connect(), подделать нельзя.
    private static Cred? Peer(Socket s)
    {
        var buf = new byte[12];
        try
        {
            if (s.GetRawSocketOption(SolSocket, SoPeercred, buf) < 12) return null;
            return new Cred(BitConverter.ToInt32(buf, 0), BitConverter.ToUInt32(buf, 4));
        }
        catch (Exception) { return null; }
    }

    private const int SolSocket = 1, SoPeercred = 17;

    [DllImport("libc")] private static extern uint getuid();
}
