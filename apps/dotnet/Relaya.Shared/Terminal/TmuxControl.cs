using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Relaya.Data;
using Relaya.Platform;
using uniffi.relaya_core;
using static Relaya.Strings;

namespace Relaya.Terminal;

/// tmux control mode (`tmux -CC`, чек-лист 4.17), как TmuxControlClient на Mac: одно соединение
/// `ssh -tt host tmux -CC attach`, каждое окно tmux — отдельная вкладка Relaya. Разбор уведомлений и команды — в ядре
/// (tmux_control.rs); здесь — процесс, очередь ответов и вкладки.
internal sealed class TmuxControlClient
{
    private static readonly List<TmuxControlClient> clients = new();

    private readonly string alias;
    private readonly DispatcherQueue ui = DispatcherQueue.GetForCurrentThread();
    private readonly TmuxParser parser = new();
    // Ответы приходят по порядку команд — очередь обработчиков.
    private readonly Queue<Action<List<string>, bool>> replies = new();
    private readonly List<TmuxWindowTab> windows = new();
    private Process? process;
    private Stream? input;

    public string SessionName { get; }
    public bool Ended { get; private set; }

    private TmuxControlClient(string alias, string sessionName)
    {
        this.alias = alias;
        SessionName = sessionName;
    }

    /// Открыть сессию хоста окнами-вкладками; если она уже открыта — новое окно в ней.
    public static async Task OpenAsync(string alias, XamlRoot root)
    {
        var name = RelayaCoreMethods.TmuxHostPrefix(alias) + "cc";
        if (clients.FirstOrDefault(c => c.SessionName == name && !c.Ended) is { } existing) { existing.NewWindow(); return; }
        try
        {
            var ttl = long.TryParse(Settings.Get("tmux.idle", "60"), out var m) ? m : 60;
            var r = await AppState.RunOnHost(alias, RelayaCoreMethods.TmuxPrepareControlCommand(name, ttl));
            if (r.Stdout.Contains("RELAYA_NO_TMUX")) { await DesktopLauncher.Message(root, L("На %@ не установлен tmux.", alias)); return; }
            if (r.Status != 0) { await DesktopLauncher.Message(root, r.Stderr.Trim().Length > 0 ? r.Stderr.Trim() : L("Команда не выполнена.")); return; }
            var client = new TmuxControlClient(alias, name);
            clients.Add(client);
            client.Start();
        }
        catch (Exception e) { await DesktopLauncher.Message(root, e.Message); }
    }

    private void Start()
    {
        var info = new ProcessStartInfo(AppState.SshExe)
        {
            UseShellExecute = false, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
        };
        foreach (var a in new[] { "-tt", alias, RelayaCoreMethods.TmuxCcAttach(SessionName) }) info.ArgumentList.Add(a);
        Askpass.Configure(info, alias);
        var p = Process.Start(info) ?? throw new InvalidOperationException(L("Не удалось запустить ssh: %@", alias));
        Askpass.Started(info, p);
        process = p;
        input = p.StandardInput.BaseStream;
        p.EnableRaisingEvents = true;
        p.Exited += (_, _) => ui.TryEnqueue(Finish);
        _ = Task.Run(() => ReadLoop(p.StandardOutput.BaseStream));
        _ = Task.Run(async () => Trace.WriteLine("tmux -CC: " + await p.StandardError.ReadToEndAsync()));
        // Сам attach отвечает своим %begin/%end — у него свой пустой обработчик, иначе его ответ забрал бы list-windows.
        replies.Enqueue((_, _) => { });
        Query(RelayaCoreMethods.TmuxCcListWindows(), (lines, _) => SyncWindows(lines));
    }

    private void ReadLoop(Stream output)
    {
        var buf = new byte[16 * 1024];
        try
        {
            int n;
            // Куски — в UI-очередь по порядку: парсер держит хвост строки между вызовами.
            while ((n = output.Read(buf, 0, buf.Length)) > 0)
            {
                var chunk = buf[..n];
                ui.TryEnqueue(() => Handle(chunk));
            }
        }
        catch (Exception e) { TerminalView.Trace("tmux -CC read: " + e.Message); }
    }

    public void Send(string command) => Query(command, (_, _) => { });

    private void Query(string command, Action<List<string>, bool> handler)
    {
        if (Ended || input == null) return;
        try
        {
            input.Write(Encoding.UTF8.GetBytes(command + "\n"));
            input.Flush();
            // У каждой команды есть %begin/%end — очередь держим, даже если ответ не нужен.
            replies.Enqueue(handler);
        }
        catch (Exception e) { TerminalView.Trace("tmux -CC write: " + e.Message); }
    }

    public void NewWindow() => Send("new-window");

    public void Close(TmuxWindowTab w) => Send(RelayaCoreMethods.TmuxCcKillWindow(w.Id));

    /// Отключиться, оставив сессию на сервере (её закроет таймер, если не вернуться).
    public void Detach()
    {
        Send("detach-client");
        try { process?.Kill(); } catch (Exception) { }
    }

    private void Handle(byte[] bytes)
    {
        foreach (var e in parser.Feed(bytes))
        {
            switch (e)
            {
                case TmuxEvent.Output o:
                    windows.FirstOrDefault(w => w.Pane == o.pane)?.Receive(o.data);
                    break;
                case TmuxEvent.WindowAdd:
                    Query(RelayaCoreMethods.TmuxCcListWindows(), (lines, _) => SyncWindows(lines));
                    break;
                case TmuxEvent.WindowClose c:
                    if (windows.FirstOrDefault(w => w.Id == c.window) is { } closed)
                    {
                        windows.Remove(closed);
                        MainWindow.Current?.CloseTabOf(closed);
                    }
                    break;
                case TmuxEvent.WindowRenamed r:
                    windows.FirstOrDefault(w => w.Id == r.window)?.Rename(r.name);
                    break;
                case TmuxEvent.WindowPaneChanged pc:
                    if (windows.FirstOrDefault(w => w.Id == pc.window) is { } win) win.Pane = pc.pane;
                    break;
                case TmuxEvent.Reply rep:
                    if (replies.Count > 0) replies.Dequeue()(rep.lines, rep.error);
                    break;
                case TmuxEvent.Exit:
                    Finish();
                    break;
            }
        }
    }

    private void SyncWindows(List<string> lines)
    {
        foreach (var info in RelayaCoreMethods.TmuxCcParseWindows(lines))
        {
            if (windows.FirstOrDefault(w => w.Id == info.window) is { } known)
            {
                known.Pane = info.pane;
                known.Rename(info.name);
                continue;
            }
            var tab = new TmuxWindowTab(this, info.window, info.pane, info.name);
            windows.Add(tab);
            // Текущее содержимое экрана — сразу, дальше идут %output.
            Query(RelayaCoreMethods.TmuxCcCapture(info.pane), (captured, error) =>
            {
                if (!error) tab.Receive(Encoding.UTF8.GetBytes(string.Join("\r\n", captured)));
            });
            MainWindow.Current?.OpenTab($"tmux · {info.name}", "", tab, tab);
        }
    }

    private void Finish()
    {
        if (Ended) return;
        Ended = true;
        try { input?.Dispose(); } catch (Exception) { }
        clients.Remove(this);
        foreach (var w in windows.ToList()) MainWindow.Current?.CloseTabOf(w);
        windows.Clear();
    }

    internal void Forget(TmuxWindowTab w) => windows.Remove(w);
}

/// Вкладка с окном tmux: терминал без своего процесса — вывод из `%output`, ввод уходит в `send-keys`.
internal sealed class TmuxWindowTab : UserControl, IDisposable
{
    private readonly TmuxControlClient client;
    private readonly TerminalView view = new();
    private readonly TextBlock title;
    private bool disposed;

    public string Id { get; }
    public string Pane { get; set; }

    public TmuxWindowTab(TmuxControlClient client, string id, string pane, string name)
    {
        this.client = client;
        Id = id;
        Pane = pane;
        title = new TextBlock { Style = Pages.Ui.Style("CaptionTextBlockStyle"), VerticalAlignment = VerticalAlignment.Center };
        Rename(name);
        var newWindow = Pages.Ui.Button(L("Новое окно"), client.NewWindow);
        var detach = Pages.Ui.Button(L("Отключиться"), client.Detach);
        ToolTipService.SetToolTip(detach, L("Сессия останется на сервере; её закроет таймер, если не вернуться"));
        var bar = new Grid { ColumnDefinitions = { new(), new() { Width = GridLength.Auto }, new() { Width = GridLength.Auto } }, ColumnSpacing = 8, Margin = new Thickness(8, 4, 8, 4) };
        bar.Children.Add(title);
        Grid.SetColumn(newWindow, 1);
        bar.Children.Add(newWindow);
        Grid.SetColumn(detach, 2);
        bar.Children.Add(detach);
        var root = new Grid { RowDefinitions = { new() { Height = GridLength.Auto }, new() } };
        root.Children.Add(bar);
        Grid.SetRow(view, 1);
        root.Children.Add(view);
        Content = root;
        view.Input += data => client.Send(RelayaCoreMethods.TmuxCcSendKeys(Pane, data));
        view.Resized += (cols, rows) => client.Send(RelayaCoreMethods.TmuxCcResize(Id, cols, rows));
        Loaded += (_, _) => view.Focus(FocusState.Programmatic);
    }

    public void Rename(string name) => title.Text = $"tmux · {client.SessionName} · {Id} · {name}";

    public void Receive(byte[] data) => view.Feed(data);

    /// Закрытие вкладки пользователем закрывает окно tmux; закрытие по уведомлению сервера — только вкладку.
    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        client.Forget(this);
        if (!client.Ended) client.Close(this);
        view.Dispose();
    }
}
