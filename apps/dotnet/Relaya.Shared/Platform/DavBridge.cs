using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading.Tasks;
using Relaya.Data;
using uniffi.relaya_core;
using static Relaya.Strings;

namespace Relaya.Platform;

/// «Файлы хоста как диск» (чек-лист 6.7), как WebDAVBridge на Mac: WebDAV-сервер на 127.0.0.1 со случайным портом,
/// секретным путём и Basic-паролем этого подключения превращает запросы файлового менеджера в sftp/ssh. Разбор HTTP
/// и ответы — в ядре (webdav.rs); подключение диска — у платформы (Linux — gio/gvfs).
internal sealed partial class DavBridge
{
    private static readonly Dictionary<string, DavBridge> bridges = new();

    public const string User = "relaya";

    private readonly string alias;
    private readonly string requestedRoot;
    private readonly string volumeName;
    private readonly string password = Guid.NewGuid().ToString("N") + Guid.NewGuid().ToString("N");
    private readonly string prefix;
    private readonly object gate = new();
    // Служебные файлы Finder (`._*`, `.DS_Store`) живут только в памяти моста.
    private readonly Dictionary<string, byte[]> junk = new();
    private readonly Dictionary<string, (List<RemoteFile> Files, DateTime At)> listings = new();
    private TcpListener? listener;
    private string root = "/";

    public string Url { get; private set; } = "";

    private DavBridge(string alias, string requestedRoot)
    {
        this.alias = alias;
        this.requestedRoot = requestedRoot;
        volumeName = VolumeName(alias, requestedRoot);
        prefix = $"/{Guid.NewGuid():N}/{volumeName}";
    }

    /// Умеет ли платформа подключать диск; без этого пункт меню скрыт. Shared не знает ОС — решает partial платформы.
    public static bool Supported => PlatformSupported();

    public static bool IsMounted(string alias) { lock (bridges) return bridges.ContainsKey(alias); }

    /// Поднять сервер, подключить диск и открыть его в файловом менеджере.
    public static async Task MountAsync(string alias, string remoteRoot)
    {
        var bridge = new DavBridge(alias, remoteRoot);
        await bridge.PrepareAsync();
        bridge.Listen();
        try { await MountVolumeAsync(bridge.Url, User, bridge.password); }
        catch { bridge.listener?.Stop(); throw; }
        lock (bridges) bridges[alias] = bridge;
        OpenVolume(bridge.Url);
    }

    public static async Task UnmountAsync(string alias)
    {
        DavBridge? bridge;
        lock (bridges) { bridges.Remove(alias, out bridge); }
        if (bridge == null) return;
        try { await UnmountVolumeAsync(bridge.Url); }
        finally { bridge.listener?.Stop(); }
    }

    /// Выход из приложения: отключить все диски, иначе в файловом менеджере останется мёртвое подключение.
    /// gio живёт отдельным процессом — ждём недолго.
    public static void UnmountAll()
    {
        List<DavBridge> all;
        lock (bridges) { all = bridges.Values.ToList(); bridges.Clear(); }
        // Ждём в пуле: продолжения AppState.Run иначе встали бы в очередь заблокированного UI-потока.
        try { Task.Run(() => Task.WhenAll(all.Select(b => UnmountVolumeAsync(b.Url)))).Wait(TimeSpan.FromSeconds(2)); }
        catch (Exception e) { Terminal.TerminalView.Trace("dav unmount: " + e.Message); }
        foreach (var b in all) b.listener?.Stop();
        // Файлы удаляются после каждого запроса; пустой каталог процесса — при выходе.
        if (tempDir.IsValueCreated)
            try { Directory.Delete(tempDir.Value, true); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { Terminal.TerminalView.Trace("dav temp: " + e.Message); }
    }

    // Платформа: подключить WebDAV-адрес как диск (пароль — не в аргументах), отключить, открыть.
    private static partial Task MountVolumeAsync(string url, string user, string password);
    private static partial Task UnmountVolumeAsync(string url);
    private static partial void OpenVolume(string url);
    private static partial bool PlatformSupported();
    /// Требовать ли Basic-пароль. Mac и Linux — всегда; Windows — нет (см. DavBridge.Windows.cs, решение аудита безопасности).
    private static partial bool RequiresBasic();

    /// Имя диска: хост, а для вложенной папки — «хост · папка».
    private static string VolumeName(string alias, string path)
    {
        var last = path.TrimEnd('/').Split('/').LastOrDefault() ?? "";
        var name = path is "/" or "" || last.Length == 0 ? alias : path == "~" ? $"{alias} · ~" : $"{alias} · {last}";
        return name.Replace("/", "-");
    }

    /// `~` и пустое — домашняя, `~/x` — внутри домашней; несуществующая папка — ошибка.
    private async Task PrepareAsync()
    {
        var r = requestedRoot.Trim();
        if (r.Length == 0 || r == "~") root = await HomeAsync();
        else if (r.StartsWith("~/")) root = Join(await HomeAsync(), r[2..]);
        else root = r.StartsWith('/') ? r : "/" + r;
        await ListAsync(root);
    }

    private void Listen()
    {
        var l = new TcpListener(IPAddress.Loopback, 0);
        l.Start();
        listener = l;
        var port = ((IPEndPoint)l.LocalEndpoint).Port;
        Url = $"dav://{User}@127.0.0.1:{port}" + string.Join("/", prefix.Split('/').Select(Uri.EscapeDataString));
        _ = Task.Run(async () =>
        {
            try
            {
                while (true)
                {
                    var client = await l.AcceptTcpClientAsync();
                    _ = Task.Run(() => ServeAsync(client));
                }
            }
            catch (Exception e) { Terminal.TerminalView.Trace("dav accept: " + e.Message); } // Stop() при отключении
        });
    }

    // Одно соединение: запросы по очереди, ответы в том же порядке.
    private async Task ServeAsync(TcpClient client)
    {
        using var connection = client;
        var stream = client.GetStream();
        var parser = new DavParser();
        var buf = new byte[1 << 16];
        try
        {
            int n;
            while ((n = await stream.ReadAsync(buf)) > 0)
                foreach (var req in parser.Feed(buf[..n]))
                {
                    var reply = await HandleAsync(req);
                    await stream.WriteAsync(reply);
                }
        }
        catch (Exception e) { Terminal.TerminalView.Trace("dav: " + e.Message); }
    }

    private static byte[] Response(ushort status, string reason, Dictionary<string, string>? headers = null, byte[]? body = null) =>
        RelayaCoreMethods.DavResponse(status, reason, headers ?? new(), body ?? Array.Empty<byte>());

    private static Dictionary<string, string> Xml => new() { ["Content-Type"] = "application/xml; charset=utf-8" };

    /// Путь запроса → путь на сервере. Только внутри префикса (с границей `/`) и без `.`/`..`, чтобы ни запрос,
    /// ни Destination у MOVE/COPY не вышли за корень диска.
    private string? RemotePath(string path)
    {
        if (path != prefix && !path.StartsWith(prefix + "/")) return null;
        var parts = path[prefix.Length..].Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Any(p => p is "." or "..")) return null;
        return parts.Length == 0 ? root : Join(root, string.Join("/", parts));
    }

    private async Task<byte[]> HandleAsync(DavRequest req)
    {
        var expected = "Basic " + Convert.ToBase64String(Encoding.UTF8.GetBytes($"{User}:{password}"));
        if (RequiresBasic() && Header(req, "authorization") != expected)
            return Response(401, "Unauthorized", new() { ["WWW-Authenticate"] = "Basic realm=\"Relaya\"" });
        if (RemotePath(req.path) is not { } remote) return Response(404, "Not Found");
        if (remote == root && req.method is "DELETE" or "MOVE") return Response(403, "Forbidden");
        var name = remote.Split('/').Last();
        var isJunk = RelayaCoreMethods.DavIsFinderJunk(name);
        try
        {
            switch (req.method)
            {
                case "OPTIONS":
                    return Response(200, "OK", new() { ["Allow"] = "OPTIONS, GET, HEAD, PUT, DELETE, MKCOL, MOVE, COPY, PROPFIND, PROPPATCH, LOCK, UNLOCK", ["DAV"] = "1, 2" });
                case "PROPFIND":
                    return await PropfindAsync(req, remote);
                case "PROPPATCH":
                    return Response(207, "Multi-Status", Xml, RelayaCoreMethods.DavMultistatus(new()));
                case "LOCK":
                    var lk = RelayaCoreMethods.DavLock(req.path, Header(req, "if"));
                    var lockHeaders = Xml;
                    lockHeaders["Lock-Token"] = lk.lockTokenHeader;
                    return Response(200, "OK", lockHeaders, lk.body);
                case "UNLOCK":
                    return Response(204, "No Content");
                case "GET" or "HEAD":
                    if (isJunk)
                    {
                        byte[]? d;
                        lock (gate) junk.TryGetValue(remote, out d);
                        return d == null ? Response(404, "Not Found") : Response(200, "OK", null, req.method == "HEAD" ? null : d);
                    }
                    if (req.method == "HEAD")
                        return await StatAsync(remote) is { } f ? Response(200, "OK", new() { ["Content-Length"] = f.size.ToString() }) : Response(404, "Not Found");
                    var down = TempFile();
                    try
                    {
                        await SftpAsync($"get {Q(remote)} {Q(down)}");
                        return Response(200, "OK", new() { ["Content-Type"] = "application/octet-stream" }, await File.ReadAllBytesAsync(down));
                    }
                    finally { File.Delete(down); }
                case "PUT":
                    if (isJunk) { lock (gate) junk[remote] = req.body; return Response(201, "Created"); }
                    var up = TempFile();
                    try
                    {
                        await File.WriteAllBytesAsync(up, req.body);
                        await SftpAsync($"put {Q(up)} {Q(remote)}");
                    }
                    finally { File.Delete(up); }
                    Invalidate(remote);
                    return Response(201, "Created");
                case "MKCOL":
                    await SftpAsync($"mkdir {Q(remote)}");
                    Invalidate(remote);
                    return Response(201, "Created");
                case "DELETE":
                    if (isJunk) { lock (gate) junk.Remove(remote); return Response(204, "No Content"); }
                    // Файловый менеджер сам спрашивает подтверждение — папки удаляются целиком, как на любом сетевом диске.
                    await ShellAsync("rm -rf -- " + RelayaCoreMethods.CoreShellQuote(remote));
                    Invalidate(remote);
                    return Response(204, "No Content");
                case "MOVE" or "COPY":
                    if (RelayaCoreMethods.DavDestinationPath(Header(req, "destination")) is not { } destPath || RemotePath(destPath) is not { } dest)
                        return Response(400, "Bad Request");
                    if (isJunk)
                    {
                        lock (gate)
                        {
                            if (junk.TryGetValue(remote, out var d)) junk[dest] = d;
                            if (req.method == "MOVE") junk.Remove(remote);
                        }
                        return Response(201, "Created");
                    }
                    var overwrite = Header(req, "overwrite")?.ToUpperInvariant() != "F";
                    // Без перезаписи и цель есть — 412: gvfs превращает его в «уже существует», а `mv -n` молча вышел бы с 0.
                    if (!overwrite && await StatAsync(dest) != null) return Response(412, "Precondition Failed");
                    var tool = req.method == "MOVE" ? "mv" : "cp -a";
                    await ShellAsync($"{tool} {(overwrite ? "" : "-n ")}-- {RelayaCoreMethods.CoreShellQuote(remote)} {RelayaCoreMethods.CoreShellQuote(dest)}");
                    Invalidate(remote);
                    Invalidate(dest);
                    return Response(201, "Created");
                default:
                    return Response(405, "Method Not Allowed");
            }
        }
        catch (Exception e)
        {
            return Response(500, "Internal Server Error", null, Encoding.UTF8.GetBytes(e.Message));
        }
    }

    private async Task<byte[]> PropfindAsync(DavRequest req, string remote)
    {
        var href = req.path;
        DavEntry self;
        if (remote == root)
            self = new DavEntry(href, volumeName, true, 0, Now());
        else
        {
            var name = remote.Split('/').Last();
            if (RelayaCoreMethods.DavIsFinderJunk(name))
            {
                byte[]? d;
                lock (gate) junk.TryGetValue(remote, out d);
                if (d == null) return Response(404, "Not Found");
                self = new DavEntry(href, name, false, d.Length, Now());
            }
            else if (await StatAsync(remote) is { } f) self = Entry(f, href);
            else return Response(404, "Not Found");
        }
        var entries = new List<DavEntry> { self };
        if (RelayaCoreMethods.DavDepth(req) > 0 && self.isDirectory)
        {
            var b = href.EndsWith('/') ? href : href + "/";
            foreach (var f in await ListAsync(remote))
                if (!RelayaCoreMethods.DavIsFinderJunk(f.name))
                    entries.Add(Entry(f, b + f.name + (f.isDirectory ? "/" : "")));
        }
        return Response(207, "Multi-Status", Xml, RelayaCoreMethods.DavMultistatus(entries));
    }

    private static DavEntry Entry(RemoteFile f, string href) =>
        new(href, f.name, f.isDirectory, f.size, RelayaCoreMethods.DavDateFromListing(f.modified, Now()));

    private static double Now() => DateTimeOffset.UtcNow.ToUnixTimeSeconds();

    private static string? Header(DavRequest req, string name) => req.headers.TryGetValue(name, out var v) ? v : null;

    private async Task<List<RemoteFile>> ListAsync(string dir)
    {
        lock (gate)
            if (listings.TryGetValue(dir, out var c) && DateTime.UtcNow - c.At < TimeSpan.FromSeconds(3)) return c.Files;
        var r = await SftpAsync($"ls -la {Q(dir)}");
        var files = RelayaCoreMethods.SftpParseListing(r.Stdout).Where(f => f.name is not "." and not "..").ToList();
        lock (gate) listings[dir] = (files, DateTime.UtcNow);
        return files;
    }

    private async Task<RemoteFile?> StatAsync(string path)
    {
        var name = path.Split('/').Last();
        try { return (await ListAsync(Parent(path))).FirstOrDefault(f => f.name == name); }
        catch (Exception) { return null; } // нет родительской папки — нет и файла
    }

    private void Invalidate(string path)
    {
        lock (gate) { listings.Remove(Parent(path)); listings.Remove(path); }
    }

    private async Task<string> HomeAsync()
    {
        var r = await SftpAsync("pwd");
        var line = r.Stdout.Split('\n').FirstOrDefault(l => l.StartsWith("Remote working directory:"));
        return line?.Split(':', 2)[1].Trim() ?? "/";
    }

    private async Task<AppState.Result> SftpAsync(string command)
    {
        var r = await AppState.Run(AppState.SftpExe,
            new[] { "-o", "BatchMode=no", "-b", "-", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4", alias },
            alias, command + "\n", 7 * 24 * 3600);
        if (r.Status != 0) throw new IOException(SshErrors.Describe(r.Stderr, L("Ошибка sftp")));
        return r;
    }

    private async Task ShellAsync(string command)
    {
        var r = await AppState.RunOnHost(alias, command, 120);
        if (r.Status != 0) throw new IOException(r.Stderr.Trim().Length > 0 ? r.Stderr.Trim() : "ssh: " + r.Status);
    }

    // Содержимое чужих файлов — в своём каталоге 0700 (CreateTempSubdirectory): и sftp get, и наша запись создают
    // файлы по umask, а без XDG_RUNTIME_DIR база — общий /tmp.
    private static readonly Lazy<string> tempDir = new(() =>
        Directory.CreateTempSubdirectory("relaya-dav-").FullName);

    private static string TempFile() => Path.Combine(tempDir.Value, Guid.NewGuid().ToString("N"));

    // Аргумент команды sftp -b: в кавычках, с экранированием, как в SftpPage.
    private static string Q(string s) => "\"" + s.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";

    private static string Join(string a, string b) => a.TrimEnd('/') + "/" + b.TrimStart('/');

    private static string Parent(string path)
    {
        var i = path.TrimEnd('/').LastIndexOf('/');
        return i <= 0 ? "/" : path[..i];
    }
}
