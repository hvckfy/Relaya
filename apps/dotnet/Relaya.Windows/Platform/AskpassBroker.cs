using System;
using System.Collections.Concurrent;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading.Tasks;

namespace Relaya.Platform;

/// Секреты для askpass без открытого доступа к Credential Manager (аналог M8 на Mac).
/// Процесс, который запускает ssh/sftp, держит named pipe с ACL только для текущего пользователя и выдаёт
/// одноразовый токен на учётку: ~60 с, не больше 3 использований (ssh может переспросить). Askpass-режим
/// Relaya.exe шлёт в pipe токен и текст запроса; секрет отдаётся, только если клиент — Relaya.exe,
/// его родитель — ssh.exe, а выше по цепочке (не дальше 3 уровней) — этот процесс.
internal static class AskpassBroker
{
    private sealed record Grant(string Account, DateTime Expires) { public int Uses; }

    private static readonly ConcurrentDictionary<string, Grant> grants = new();
    private static readonly object startLock = new();
    private static string? pipeName;

    public static string PipeName
    {
        get
        {
            lock (startLock)
            {
                if (pipeName == null)
                {
                    pipeName = $"relaya-askpass-{Environment.ProcessId}-{Convert.ToHexString(RandomNumberGenerator.GetBytes(8)).ToLowerInvariant()}";
                    _ = Task.Run(Serve);
                }
                return pipeName;
            }
        }
    }

    /// Токен на учётку: живёт 60 с, до 3 использований.
    public static string Issue(string account)
    {
        _ = PipeName;
        foreach (var (k, g) in grants) if (g.Expires < DateTime.UtcNow) grants.TryRemove(k, out _);
        var token = Convert.ToHexString(RandomNumberGenerator.GetBytes(16));
        grants[token] = new Grant(account, DateTime.UtcNow.AddSeconds(60));
        return token;
    }

    private static async Task Serve()
    {
        var security = new PipeSecurity();
        security.AddAccessRule(new PipeAccessRule(WindowsIdentity.GetCurrent().User!, PipeAccessRights.ReadWrite, AccessControlType.Allow));
        while (true)
        {
            NamedPipeServerStream server;
            try
            {
                server = NamedPipeServerStreamAcl.Create(pipeName!, PipeDirection.InOut, NamedPipeServerStream.MaxAllowedServerInstances,
                    PipeTransmissionMode.Byte, PipeOptions.Asynchronous, 0, 0, security);
            }
            catch (Exception) { await Task.Delay(1000); continue; }
            try { await server.WaitForConnectionAsync(); }
            catch (Exception) { server.Dispose(); continue; }
            _ = Task.Run(() => Handle(server));
        }
    }

    private static void Handle(NamedPipeServerStream server)
    {
        using (server)
        {
            try
            {
                var reader = new StreamReader(server, new UTF8Encoding(false), false, 1024, leaveOpen: true);
                var token = reader.ReadLine() ?? "";
                var prompt = reader.ReadLine() ?? "";
                var secret = Answer(server, token, prompt);
                var reply = Encoding.UTF8.GetBytes(secret != null ? "OK\n" + secret + "\n" : "NO\n");
                server.Write(reply);
                server.Flush();
                server.WaitForPipeDrain();
            }
            catch (Exception) { }
        }
    }

    private static string? Answer(NamedPipeServerStream server, string token, string prompt)
    {
        if (!grants.TryGetValue(token, out var g)) return null;
        if (g.Expires < DateTime.UtcNow) { grants.TryRemove(token, out _); return null; }
        if (!PasswordPrompt.Matches(prompt)) return null;
        if (!GetNamedPipeClientProcessId(server.SafePipeHandle.DangerousGetHandle(), out var client) || !CallerIsOurSsh((int)client))
            return null;
        lock (g)
        {
            if (++g.Uses > 3) { grants.TryRemove(token, out _); return null; }
        }
        // Настройка «Подтверждать каждое использование пароля»: системный диалог, «Нет» по умолчанию.
        if (Settings.GetFresh("security.confirmPassword", "0") == "1")
        {
            var text = Strings.L("ssh просит пароль %@:", g.Account) + "\n\n" + prompt;
            const uint flags = 0x4 /* YESNO */ | 0x20 /* ICONQUESTION */ | 0x100 /* DEFBUTTON2 */ | 0x40000 /* TOPMOST */ | 0x10000 /* SETFOREGROUND */;
            if (MessageBoxW(IntPtr.Zero, text, "Relaya", flags) != 6) return null;
        }
        return CredentialStore.Read(g.Account);
    }

    // Клиент — Relaya.exe (тот же файл), родитель — ssh.exe, выше не дальше 3 уровней — мы.
    private static bool CallerIsOurSsh(int client)
    {
        var self = Environment.ProcessPath;
        if (self == null || !SamePath(ImagePath(client), self)) return false;
        var parent = ParentOf(client);
        if (parent <= 0 || !string.Equals(Path.GetFileName(ImagePath(parent)), "ssh.exe", StringComparison.OrdinalIgnoreCase)) return false;
        var p = parent;
        for (var i = 0; i < 3; i++)
        {
            p = ParentOf(p);
            if (p <= 0) return false;
            if (p == Environment.ProcessId) return true;
        }
        return false;
    }

    private static bool SamePath(string? a, string b) =>
        a != null && string.Equals(Path.GetFullPath(a), Path.GetFullPath(b), StringComparison.OrdinalIgnoreCase);

    private static string? ImagePath(int pid)
    {
        var h = OpenProcess(ProcessQueryLimitedInformation, false, pid);
        if (h == IntPtr.Zero) return null;
        try
        {
            var sb = new StringBuilder(1024);
            var size = sb.Capacity;
            return QueryFullProcessImageNameW(h, 0, sb, ref size) ? sb.ToString(0, size) : null;
        }
        finally { CloseHandle(h); }
    }

    private static int ParentOf(int pid)
    {
        var h = OpenProcess(ProcessQueryLimitedInformation, false, pid);
        if (h == IntPtr.Zero) return -1;
        try
        {
            var info = new ProcessBasicInformation();
            return NtQueryInformationProcess(h, 0, ref info, Marshal.SizeOf<ProcessBasicInformation>(), out _) == 0
                ? (int)info.InheritedFromUniqueProcessId : -1;
        }
        finally { CloseHandle(h); }
    }

    private const int ProcessQueryLimitedInformation = 0x1000;

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessBasicInformation
    {
        public IntPtr ExitStatus, PebBaseAddress, AffinityMask, BasePriority, UniqueProcessId, InheritedFromUniqueProcessId;
    }

    [DllImport("ntdll.dll")]
    private static extern int NtQueryInformationProcess(IntPtr process, int infoClass, ref ProcessBasicInformation info, int length, out int returned);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(int access, bool inherit, int pid);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool QueryFullProcessImageNameW(IntPtr process, int flags, StringBuilder name, ref int size);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetNamedPipeClientProcessId(IntPtr pipe, out uint clientProcessId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);
}
