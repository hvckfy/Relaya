using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Threading.Tasks;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Tmds.DBus;
using static Relaya.Strings;

[assembly: InternalsVisibleTo(Tmds.DBus.Connection.DynamicAssemblyName)]

namespace Relaya.Platform;

/// Значок в области уведомлений (чек-лист 8.5, 12.5), как menu bar extra на Mac: StatusNotifierItem + com.canonical.dbusmenu
/// по сессионной D-Bus (KDE, Xfce, Cinnamon, GNOME с AppIndicator). Меню — туннели с запуском/остановкой, временные
/// туннели, «Открыть Relaya», «Выйти». Нет StatusNotifierWatcher — значка нет, приложение работает как раньше.
internal static class TrayIcon
{
    // Держим соединение, пока живёт приложение: с ним уходит и значок.
    private static Connection? connection;

    public static async Task StartAsync()
    {
        var ui = DispatcherQueue.GetForCurrentThread();
        try
        {
            var conn = new Connection(Address.Session);
            await conn.ConnectAsync();
            var service = $"org.kde.StatusNotifierItem-{Environment.ProcessId}-1";
            var menu = new TrayMenu(ui);
            item = new StatusNotifierItem(ui);
            await conn.RegisterObjectAsync(item);
            await conn.RegisterObjectAsync(menu);
            await conn.RegisterServiceAsync(service);
            var watcher = conn.CreateProxy<IStatusNotifierWatcher>("org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher");
            await watcher.RegisterStatusNotifierItemAsync(service);
            TunnelManager.Shared.Changed += () => ui.TryEnqueue(() => { menu.Rebuild(); Refresh(); });
            connection = conn;
            Refresh();
        }
        catch (Exception e) { Terminal.TerminalView.Trace("tray: " + e.Message); }
    }

    private static StatusNotifierItem? item;

    /// Настройка tray.enabled (12.5) и правило Mac: значок виден, только когда есть туннели; иначе — Passive.
    public static bool Enabled => Settings.Get("tray.enabled", "1") == "1";

    /// Окно спрятано в трей (HideToTray); пропал значок — окно возвращается, иначе процесс остался бы невидимым.
    public static bool WindowHidden { get; set; }

    public static void Refresh()
    {
        var active = Enabled && (Data.AppState.Tunnels.Count > 0 || TunnelManager.Shared.Temporary.Count > 0);
        item?.SetStatus(active ? "Active" : "Passive");
        if (!active && WindowHidden) ShowWindow();
    }

    public static bool Visible => item?.Status == "Active";

    internal static void ShowWindow()
    {
        if (MainWindow.Current is not { } w) return;
        WindowHidden = false;
        w.AppWindow.Show();
        w.Activate();
    }
}

[DBusInterface("org.kde.StatusNotifierWatcher")]
internal interface IStatusNotifierWatcher : IDBusObject
{
    Task RegisterStatusNotifierItemAsync(string service);
}

[DBusInterface("org.kde.StatusNotifierItem")]
internal interface IStatusNotifierItem : IDBusObject
{
    Task ActivateAsync(int x, int y);
    Task SecondaryActivateAsync(int x, int y);
    Task ContextMenuAsync(int x, int y);
    Task ScrollAsync(int delta, string orientation);
    Task<object> GetAsync(string prop);
    Task<IDictionary<string, object>> GetAllAsync();
    Task SetAsync(string prop, object val);
    Task<IDisposable> WatchPropertiesAsync(Action<PropertyChanges> handler);
    Task<IDisposable> WatchNewStatusAsync(Action<string> handler, Action<Exception>? onError = null);
}

internal sealed class StatusNotifierItem(DispatcherQueue ui) : IStatusNotifierItem
{
    public ObjectPath ObjectPath => new("/StatusNotifierItem");

    public Task ActivateAsync(int x, int y) { ui.TryEnqueue(TrayIcon.ShowWindow); return Task.CompletedTask; }
    public Task SecondaryActivateAsync(int x, int y) => ActivateAsync(x, y);
    public Task ContextMenuAsync(int x, int y) => Task.CompletedTask;
    public Task ScrollAsync(int delta, string orientation) => Task.CompletedTask;

    public Task<object> GetAsync(string prop) =>
        Task.FromResult(Properties().TryGetValue(prop, out var v) ? v : throw new DBusException("org.freedesktop.DBus.Error.UnknownProperty", prop));

    public Task<IDictionary<string, object>> GetAllAsync() => Task.FromResult<IDictionary<string, object>>(Properties());

    public Task SetAsync(string prop, object val) => Task.CompletedTask;

    public Task<IDisposable> WatchPropertiesAsync(Action<PropertyChanges> handler) => Task.FromResult<IDisposable>(new Nothing(() => { }));

    private readonly object gate = new();
    private string status = "Passive";

    public string Status { get { lock (gate) return status; } }
    private Action<string>? newStatus;

    public void SetStatus(string value)
    {
        Action<string>? notify;
        lock (gate)
        {
            if (status == value) return;
            status = value;
            notify = newStatus;
        }
        notify?.Invoke(value);
    }

    public Task<IDisposable> WatchNewStatusAsync(Action<string> handler, Action<Exception>? onError = null)
    {
        Action<string> wrapped = h => handler(h);
        lock (gate) newStatus += wrapped;
        return Task.FromResult<IDisposable>(new Nothing(() => { lock (gate) newStatus -= wrapped; }));
    }

    private Dictionary<string, object> Properties()
    {
        var p = new Dictionary<string, object>
        {
            ["Category"] = "ApplicationStatus",
            ["Id"] = "relaya",
            ["Title"] = "Relaya",
            ["Status"] = status,
            ["IconName"] = "relaya",
            ["ItemIsMenu"] = false,
            ["Menu"] = new ObjectPath("/MenuBar"),
        };
        // AppImage: иконки не в системной теме, а в usr/share/icons рядом с usr/lib/relaya.
        var theme = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "share", "icons"));
        if (Directory.Exists(theme)) p["IconThemePath"] = theme;
        return p;
    }

    private sealed class Nothing(Action dispose) : IDisposable { public void Dispose() => dispose(); }
}

[DBusInterface("com.canonical.dbusmenu")]
internal interface IDBusMenu : IDBusObject
{
    Task<(uint revision, (int, IDictionary<string, object>, object[]) layout)> GetLayoutAsync(int parentId, int recursionDepth, string[] propertyNames);
    Task<(int, IDictionary<string, object>)[]> GetGroupPropertiesAsync(int[] ids, string[] propertyNames);
    Task<object> GetPropertyAsync(int id, string name);
    Task EventAsync(int id, string eventId, object data, uint timestamp);
    Task<int[]> EventGroupAsync((int, string, object, uint)[] events);
    Task<bool> AboutToShowAsync(int id);
    Task<(int[] updatesNeeded, int[] idErrors)> AboutToShowGroupAsync(int[] ids);
    Task<IDisposable> WatchLayoutUpdatedAsync(Action<(uint revision, int parent)> handler, Action<Exception>? onError = null);
    Task<object> GetAsync(string prop);
    Task<IDictionary<string, object>> GetAllAsync();
    Task SetAsync(string prop, object val);
    Task<IDisposable> WatchPropertiesAsync(Action<PropertyChanges> handler);
}

internal sealed class TrayMenu : IDBusMenu
{
    private sealed record Entry(int Id, Dictionary<string, object> Props, Action? Run);

    private readonly DispatcherQueue ui;
    private readonly object gate = new();
    private List<Entry> entries = new();
    private uint revision;
    private Action<(uint, int)>? layoutUpdated;

    public TrayMenu(DispatcherQueue ui)
    {
        this.ui = ui;
        Rebuild();
    }

    public ObjectPath ObjectPath => new("/MenuBar");

    /// Пересобрать меню из состояния туннелей; вызывается из UI-потока.
    public void Rebuild()
    {
        var list = new List<Entry>();
        var id = 1;
        void Item(string label, Action? run, bool? check = null)
        {
            var p = new Dictionary<string, object> { ["label"] = label.Replace("_", "__"), ["enabled"] = run != null };
            if (check is { } c) { p["toggle-type"] = "checkmark"; p["toggle-state"] = c ? 1 : 0; }
            list.Add(new Entry(id++, p, run));
        }
        void Separator() => list.Add(new Entry(id++, new() { ["type"] = "separator" }, null));
        void Tunnels(IEnumerable<uniffi.relaya_core.Tunnel> tunnels)
        {
            foreach (var t in tunnels)
            {
                var running = TunnelManager.Shared.StatusOf(t).State is TunnelManager.State.Running or TunnelManager.State.Starting;
                Item($"{t.name} · {uniffi.relaya_core.RelayaCoreMethods.TunnelSpec(t)}",
                    () => { if (running) TunnelManager.Shared.Stop(t.id); else TunnelManager.Shared.Start(t); }, running);
            }
        }

        Item(L("Туннели"), null);
        if (Data.AppState.Tunnels.Count == 0) Item(L("Нет туннелей"), null);
        Tunnels(Data.AppState.Tunnels);
        var temporary = TunnelManager.Shared.Temporary;
        if (temporary.Count > 0)
        {
            Separator();
            Item(L("Временные"), null);
            Tunnels(temporary);
        }
        Separator();
        Item(L("Открыть Relaya"), TrayIcon.ShowWindow);
        Item(L("Выйти из Relaya"), () =>
        {
            // Exit() может пройти без Window.Closed — туннели останавливаем сами, как stopAll на Mac.
            TunnelManager.Shared.StopAll();
            Application.Current.Exit();
        });

        Action<(uint, int)>? notify;
        uint rev;
        lock (gate) { entries = list; rev = ++revision; notify = layoutUpdated; }
        notify?.Invoke((rev, 0));
    }

    public Task<(uint revision, (int, IDictionary<string, object>, object[]) layout)> GetLayoutAsync(int parentId, int recursionDepth, string[] propertyNames)
    {
        lock (gate)
        {
            // Меню плоское: у корня (0) — все пункты, у пунктов детей нет.
            var children = parentId == 0 && recursionDepth != 0
                ? entries.Select(e => (object)(e.Id, (IDictionary<string, object>)e.Props, Array.Empty<object>())).ToArray()
                : Array.Empty<object>();
            IDictionary<string, object> props = parentId == 0
                ? new Dictionary<string, object> { ["children-display"] = "submenu" }
                : entries.FirstOrDefault(e => e.Id == parentId)?.Props ?? new Dictionary<string, object>();
            return Task.FromResult((revision, (parentId, props, children)));
        }
    }

    public Task<(int, IDictionary<string, object>)[]> GetGroupPropertiesAsync(int[] ids, string[] propertyNames)
    {
        lock (gate)
            return Task.FromResult(entries.Where(e => ids.Length == 0 || ids.Contains(e.Id))
                .Select(e => (e.Id, (IDictionary<string, object>)e.Props)).ToArray());
    }

    public Task<object> GetPropertyAsync(int id, string name)
    {
        lock (gate)
            return Task.FromResult(entries.FirstOrDefault(e => e.Id == id)?.Props.GetValueOrDefault(name) ?? "");
    }

    public Task EventAsync(int id, string eventId, object data, uint timestamp)
    {
        if (eventId != "clicked") return Task.CompletedTask;
        Action? run;
        lock (gate) run = entries.FirstOrDefault(e => e.Id == id)?.Run;
        if (run != null) ui.TryEnqueue(() => run());
        return Task.CompletedTask;
    }

    public async Task<int[]> EventGroupAsync((int, string, object, uint)[] events)
    {
        foreach (var (id, eventId, data, timestamp) in events) await EventAsync(id, eventId, data, timestamp);
        return Array.Empty<int>();
    }

    public Task<bool> AboutToShowAsync(int id) => Task.FromResult(false);

    public Task<(int[] updatesNeeded, int[] idErrors)> AboutToShowGroupAsync(int[] ids) =>
        Task.FromResult((Array.Empty<int>(), Array.Empty<int>()));

    public Task<IDisposable> WatchLayoutUpdatedAsync(Action<(uint revision, int parent)> handler, Action<Exception>? onError = null)
    {
        Action<(uint, int)> wrapped = h => handler(h);
        lock (gate) layoutUpdated += wrapped;
        return Task.FromResult<IDisposable>(new Unsubscribe(() => { lock (gate) layoutUpdated -= wrapped; }));
    }

    public Task<object> GetAsync(string prop) => Task.FromResult<object>(prop switch
    {
        "Version" => 3u,
        "Status" => "normal",
        "TextDirection" => "ltr",
        _ => "",
    });

    public Task<IDictionary<string, object>> GetAllAsync() => Task.FromResult<IDictionary<string, object>>(
        new Dictionary<string, object> { ["Version"] = 3u, ["Status"] = "normal", ["TextDirection"] = "ltr" });

    public Task SetAsync(string prop, object val) => Task.CompletedTask;

    public Task<IDisposable> WatchPropertiesAsync(Action<PropertyChanges> handler) => Task.FromResult<IDisposable>(new Unsubscribe(() => { }));

    private sealed class Unsubscribe(Action dispose) : IDisposable { public void Dispose() => dispose(); }
}
