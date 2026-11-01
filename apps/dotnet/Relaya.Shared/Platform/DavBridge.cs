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
/// секретным путём и Basic-паролем этого подключения превращает запросы файлового менеджера в sftp/ssh. Разбор HTTP,
/// ответы и все правила (пути, коды, команды) — в ядре (webdav.rs, webdav_policy.rs); здесь только выполнение решений
/// через sftp/ssh. Подключение диска — у платформы (Linux — gio/gvfs, Windows — WebClient).
internal sealed partial class DavBridge
{
    private static readonly Dictionary<string, DavBridge> bridges = new();

    private readonly string alias;
    private readonly string requestedRoot;
    private readonly string volumeName;
    private readonly DavSecrets secrets;
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
        volumeName = RelayaCoreMethods.DavVolumeName(alias, requestedRoot);
        secrets = RelayaCoreMethods.DavNewSecrets(volumeName);
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
        try { await MountVolumeAsync(bridge.Url, bridge.secrets.user, bridge.secrets.password); }
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
        try { RelayaCoreMethods.DavTempCleanup(); }
        catch (CoreException e) { Terminal.TerminalView.Trace("dav temp: " + e.Message); }
    }

    // Платформа: подключить WebDAV-адрес как диск (пароль — не в аргументах), отключить, открыть.
    private static partial Task MountVolumeAsync(string url, string user, string password);
    private static partial Task UnmountVolumeAsync(string url);
    private static partial void OpenVolume(string url);
    private static partial bool PlatformSupported();
    /// Требовать ли Basic-пароль. Mac и Linux — всегда; Windows — нет (см. DavBridge.Windows.cs, решение аудита безопасности).
    private static partial bool RequiresBasic();

    /// Корень диска по правилам ядра (`~`, `~/x`, абсолютный; `.`/`..` — ошибка); несуществующая папка — ошибка листинга.
    private async Task PrepareAsync()
    {
        var home = RelayaCoreMethods.DavRootNeedsHome(requestedRoot) ? await HomeAsync() : "/";
        try { root = RelayaCoreMethods.DavResolveRoot(requestedRoot, home); }
        catch (CoreException) { throw new IOException(L("Не удалось подключить диск: %@", requestedRoot)); }
        await ListAsync(root);
    }

    private void Listen()
    {
        var l = new TcpListener(IPAddress.Loopback, 0);
        l.Start();
        listener = l;
        var port = ((IPEndPoint)l.LocalEndpoint).Port;
        Url = $"dav://{secrets.user}@127.0.0.1:{port}" + string.Join("/", secrets.prefix.Split('/').Select(Uri.EscapeDataString));
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

    private const string DavAllow = "OPTIONS, GET, HEAD, PUT, DELETE, MKCOL, MOVE, COPY, PROPFIND, PROPPATCH, LOCK, UNLOCK";

    private async Task<byte[]> HandleAsync(DavRequest req)
    {
        // Windows: Basic не проверяем — WebClient не шлёт его по http (решение пользователя и аудита безопасности).
        if (RequiresBasic() && !RelayaCoreMethods.DavAuthorized(Header(req, "authorization"), secrets.password))
            return Response(401, "Unauthorized", new() { ["WWW-Authenticate"] = "Basic realm=\"Relaya\"" });
        var action = RelayaCoreMethods.DavDecide(req.method, req.path, Header(req, "destination"), Header(req, "overwrite"), secrets.prefix, root);
        try
        {
            switch (action)
            {
                case DavAction.Reply r:
                    return Response(r.status, r.reason);
                case DavAction.Options: // на любом пути (WebClient спрашивает корень сервера) — решает ядро
                    return Response(200, "OK", new() { ["Allow"] = DavAllow, ["DAV"] = "1, 2" });
                case DavAction.Propfind p:
                    return await PropfindAsync(req, p.remote, p.junk);
                case DavAction.Proppatch:
                    return Response(207, "Multi-Status", Xml, RelayaCoreMethods.DavMultistatus(new()));
                case DavAction.Lock:
                    var lk = RelayaCoreMethods.DavLock(req.path, Header(req, "if"));
                    var lockHeaders = Xml;
                    lockHeaders["Lock-Token"] = lk.lockTokenHeader;
                    return Response(200, "OK", lockHeaders, lk.body);
                case DavAction.Unlock:
                    return Response(204, "No Content");
                case DavAction.Head { junk: true } h:
                    return Junk(h.remote) is { } hd ? Response(200, "OK", new() { ["Content-Length"] = hd.Length.ToString() }) : Response(404, "Not Found");
                case DavAction.Head h:
                    return await StatAsync(h.remote) is { } f ? Response(200, "OK", new() { ["Content-Length"] = f.size.ToString() }) : Response(404, "Not Found");
                case DavAction.Get { junk: true } g:
                    return Junk(g.remote) is { } gd ? Response(200, "OK", null, gd) : Response(404, "Not Found");
                case DavAction.Get g:
                    var down = RelayaCoreMethods.DavTempFile();
                    try
                    {
                        await SftpAsync($"get {Q(g.remote)} {Q(down)}");
                        return Response(200, "OK", new() { ["Content-Type"] = "application/octet-stream" }, await File.ReadAllBytesAsync(down));
                    }
                    finally { File.Delete(down); }
                case DavAction.Put { junk: true } pj:
                    lock (gate) junk[pj.remote] = req.body;
                    return Response(201, "Created");
                case DavAction.Put put:
                    var up = RelayaCoreMethods.DavTempFile();
                    try
                    {
                        await File.WriteAllBytesAsync(up, req.body);
                        await SftpAsync($"put {Q(up)} {Q(put.remote)}");
                    }
                    finally { File.Delete(up); }
                    Invalidate(put.remote);
                    return Response(201, "Created");
                case DavAction.Mkcol m:
                    await SftpAsync($"mkdir {Q(m.remote)}");
                    Invalidate(m.remote);
                    return Response(201, "Created");
                case DavAction.Delete { junk: true } dj:
                    lock (gate) junk.Remove(dj.remote);
                    return Response(204, "No Content");
                case DavAction.Delete d:
                    await ShellAsync(RelayaCoreMethods.DavDeleteCommand(d.remote));
                    Invalidate(d.remote);
                    return Response(204, "No Content");
                case DavAction.Transfer { junk: true } tj:
                    lock (gate)
                    {
                        if (junk.TryGetValue(tj.source, out var data)) junk[tj.destination] = data;
                        if (tj.isMove) junk.Remove(tj.source);
                    }
                    return Response(201, "Created");
                case DavAction.Transfer t:
                    // Есть ли цель — командой ядра (код 0/1), а не по листингу.
                    var exists = await AppState.RunOnHost(alias, RelayaCoreMethods.DavExistsCommand(t.destination), 60);
                    if (exists.Status is not (0 or 1)) throw new IOException(exists.Stderr.Trim().Length > 0 ? exists.Stderr.Trim() : "ssh: " + exists.Status);
                    switch (RelayaCoreMethods.DavTransferPlan(t.source, t.destination, t.isMove, t.overwrite, exists.Status == 0))
                    {
                        case DavTransferPlan.Reply pr:
                            return Response(pr.status, pr.reason);
                        case DavTransferPlan.Run run:
                            await ShellAsync(run.command);
                            Invalidate(t.source);
                            Invalidate(t.destination);
                            return Response(run.status, run.reason);
                    }
                    return Response(500, "Internal Server Error");
                default:
                    return Response(405, "Method Not Allowed");
            }
        }
        catch (Exception e)
        {
            return Response(500, "Internal Server Error", null, Encoding.UTF8.GetBytes(e.Message));
        }
    }

    private byte[]? Junk(string remote)
    {
        lock (gate) return junk.TryGetValue(remote, out var d) ? d : null;
    }

    private async Task<byte[]> PropfindAsync(DavRequest req, string remote, bool isJunk)
    {
        var href = req.path;
        DavEntry self;
        if (remote == root)
            self = new DavEntry(href, volumeName, true, 0, Now());
        else
        {
            var name = remote.Split('/').Last();
            if (isJunk)
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

    // Аргумент команды sftp -b: в кавычках, с экранированием, как в SftpPage.
    private static string Q(string s) => "\"" + s.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";

    private static string Parent(string path)
    {
        var i = path.TrimEnd('/').LastIndexOf('/');
        return i <= 0 ? "/" : path[..i];
    }
}
