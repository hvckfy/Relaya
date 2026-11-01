using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Relaya.Data;
using uniffi.relaya_core;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;
using static Relaya.Strings;

namespace Relaya.Pages;

/// Файлы хоста по SFTP: навигация, скачивание, загрузка (кнопкой или перетаскиванием из Проводника), папки, переименование, удаление.
/// Каждая операция — пакет команд `sftp -b -` (Windows OpenSSH); список разбирает ядро, как на Mac.
internal sealed class SftpPage : UserControl
{
    private readonly string alias;
    private string path = ".";
    private readonly TextBox location = new() { MinWidth = 300 };
    private readonly ListView list = new() { SelectionMode = ListViewSelectionMode.Extended };
    private readonly TextBlock status = Ui.Secondary("");
    private readonly ProgressBar busy = new() { IsIndeterminate = true, Visibility = Visibility.Collapsed };
    // Передача (UI-W7): определённый прогресс, когда размер известен, сколько передано и «Отмена».
    private readonly ProgressBar progress = new() { Minimum = 0, Maximum = 1, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock progressText = Ui.Secondary("");
    private readonly Grid transferBar = new() { ColumnSpacing = 12, Visibility = Visibility.Collapsed };
    private System.Threading.CancellationTokenSource? transferCancel;
    private List<RemoteFile> files = new();

    public SftpPage(string alias)
    {
        this.alias = alias;
        location.KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter) _ = Open(location.Text.Trim()); };
        list.DoubleTapped += (_, _) => { if (Selected().FirstOrDefault() is { } f && (f.isDirectory || f.isLink)) _ = Open(Join(f.name)); };
        var toolbar = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 4,
            Children =
            {
                Ui.IconButton("", L("Наверх"), () => _ = Open(Parent(path))),
                Ui.IconButton("", L("Домой"), () => _ = Open(".")),
                Ui.IconButton("", L("Обновить"), () => _ = Open(path)),
                location,
                Ui.Button(L("Скачать"), () => _ = Download(), glyph: ""),
                Ui.Button(L("Загрузить"), () => _ = Upload(), glyph: ""),
                Ui.IconButton("", L("Новая папка"), () => _ = NewFolder()),
                Ui.IconButton("\uE70F", L("Открыть в редакторе"), Edit),
                Ui.IconButton("", L("Переименовать"), () => _ = Rename()),
                Ui.IconButton("", L("Удалить"), () => _ = Delete()),
            },
        };
        var root = new Grid
        {
            Margin = new Thickness(16), RowSpacing = 8,
            RowDefinitions = { new() { Height = GridLength.Auto }, new() { Height = GridLength.Auto }, new(), new() { Height = GridLength.Auto } },
        };
        root.Children.Add(toolbar);
        var cancel = Ui.Button(L("Отмена"), () => transferCancel?.Cancel());
        transferBar.ColumnDefinitions.Add(new ColumnDefinition());
        transferBar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        transferBar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        transferBar.Children.Add(progress);
        Grid.SetColumn(progressText, 1);
        transferBar.Children.Add(progressText);
        Grid.SetColumn(cancel, 2);
        transferBar.Children.Add(cancel);
        var bars = new Grid { Children = { busy, transferBar } };
        Grid.SetRow(bars, 1);
        root.Children.Add(bars);
        Grid.SetRow(list, 2);
        root.Children.Add(list);
        var clear = new HyperlinkButton { Content = L("Очистить") };
        clear.Click += (_, _) => { jobs.RemoveAll(j => j.State is JobState.Done or JobState.Failed or JobState.Cancelled); RenderJobs(); };
        var queueHeader = new Grid { ColumnDefinitions = { new(), new() { Width = GridLength.Auto } } };
        queueHeader.Children.Add(new TextBlock { Text = L("Передачи"), Style = Ui.Style("BodyStrongTextBlockStyle"), VerticalAlignment = VerticalAlignment.Center });
        Grid.SetColumn(clear, 1);
        queueHeader.Children.Add(clear);
        queuePanel.Child = new StackPanel { Spacing = 4, Children = { queueHeader, new ScrollViewer { Content = jobRows, MaxHeight = 160 } } };
        var footer = new StackPanel { Spacing = 8, Children = { queuePanel, status } };
        Grid.SetRow(footer, 3);
        root.Children.Add(footer);
        Content = root;
        // Сочетания как в файловом менеджере (Е.19): Enter — открыть, Backspace — наверх, F5 — обновить,
        // F2 — переименовать, Delete — удалить, Ctrl+Shift+N — новая папка.
        void Key(Windows.System.VirtualKey key, Windows.System.VirtualKeyModifiers mods, Action action)
        {
            var k = new Microsoft.UI.Xaml.Input.KeyboardAccelerator { Key = key, Modifiers = mods };
            k.Invoked += (_, e) => { if (Microsoft.UI.Xaml.Input.FocusManager.GetFocusedElement(XamlRoot) is TextBox) return; e.Handled = true; action(); };
            list.KeyboardAccelerators.Add(k);
        }
        var none = Windows.System.VirtualKeyModifiers.None;
        Key(Windows.System.VirtualKey.Enter, none, () => { if (Selected().FirstOrDefault() is { } f && (f.isDirectory || f.isLink)) _ = Open(Join(f.name)); });
        Key(Windows.System.VirtualKey.Back, none, () => _ = Open(Parent(path)));
        Key(Windows.System.VirtualKey.F5, none, () => _ = Open(path));
        Key(Windows.System.VirtualKey.F2, none, () => _ = Rename());
        Key(Windows.System.VirtualKey.Delete, none, () => _ = Delete());
        Key(Windows.System.VirtualKey.N, Windows.System.VirtualKeyModifiers.Control | Windows.System.VirtualKeyModifiers.Shift, () => _ = NewFolder());
        AllowDrop = true;
        DragOver += (_, e) => { e.AcceptedOperation = DataPackageOperation.Copy; e.DragUIOverride.Caption = L("Загрузить в %@", path); };
        Drop += async (_, e) =>
        {
            if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
            var items = await e.DataView.GetStorageItemsAsync();
            await Put(items.Select(i => i.Path));
        };
        Loaded += async (_, _) => await Open(".");
        Unloaded += (_, _) => { foreach (var w in edits) w.Dispose(); edits.Clear(); };
    }

    private List<RemoteFile> Selected() => list.SelectedItems.OfType<ListViewItem>().Select(i => (RemoteFile)i.Tag).ToList();

    private string Join(string name) => path == "/" ? "/" + name : path.TrimEnd('/') + "/" + name;

    private static string Parent(string p)
    {
        if (p is "." or "/" or "~") return p == "." ? ".." : p;
        var i = p.TrimEnd('/').LastIndexOf('/');
        return i <= 0 ? (p.StartsWith('/') ? "/" : p + "/..") : p[..i];
    }

    // Аргумент sftp-батча в кавычках: сначала обратные слэши, потом кавычки (К24) — иначе `C:\dir\` ломает команду.
    private static string Q(string s) => "\"" + s.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";

    // Навигация и мелкие операции — 60 с; передачи файлов ограничены только ConnectTimeout и ServerAlive (Н6):
    // фиксированный таймаут обрывал большие загрузки посреди передачи.
    private const int CommandTimeout = 60, TransferTimeout = 7 * 24 * 3600;

    private Task<AppState.Result> Batch(params string[] commands) => Run(CommandTimeout, commands);

    /// Передача с прогрессом: done() — сколько байт уже есть у получателя (или null, если не знаем), total — сколько всего.
    private bool cancelled;

    private async Task<AppState.Result> Transfer(string[] commands, long total, Func<long?>? done, Action<long>? onBytes = null)
    {
        transferCancel = new System.Threading.CancellationTokenSource();
        cancelled = false;
        busy.Visibility = Visibility.Collapsed;
        transferBar.Visibility = Visibility.Visible;
        progress.IsIndeterminate = done == null || total <= 0;
        progress.Value = 0;
        progressText.Text = total > 0 ? Platform.Format.Bytes(total) : "";
        var timer = DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromMilliseconds(500);
        timer.Tick += (_, _) =>
        {
            if (done?.Invoke() is not { } bytes || total <= 0) return;
            onBytes?.Invoke(bytes);
            progress.Value = Math.Min(1, bytes / (double)total);
            progressText.Text = L("%@ из %@", Platform.Format.Bytes(Math.Min(bytes, total)), Platform.Format.Bytes(total));
        };
        timer.Start();
        try { return await Run(TransferTimeout, commands, transferCancel.Token); }
        finally
        {
            cancelled = transferCancel.IsCancellationRequested;
            timer.Stop();
            transferBar.Visibility = Visibility.Collapsed;
            transferCancel = null;
        }
    }

    private async Task<AppState.Result> Run(int timeoutSeconds, string[] commands, System.Threading.CancellationToken cancel = default)
    {
        if (transferCancel == null) busy.Visibility = Visibility.Visible;
        var r = await AppState.Run(AppState.SftpExe,
            new[] { "-o", "BatchMode=no", "-b", "-", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4", alias },
            alias, string.Join("\n", commands) + "\n", timeoutSeconds, cancel);
        busy.Visibility = Visibility.Collapsed;
        if (r.Status != 0)
            status.Text = Platform.SshErrors.Describe(string.Join("\n", r.Stderr.Split('\n').Where(l => !l.StartsWith("sftp>"))), L("Ошибка sftp"));
        return r;
    }

    private async Task Open(string target)
    {
        var r = await Batch($"cd {Q(target)}", "pwd", "ls -la");
        if (r.Status != 0) return;
        var pwd = r.Stdout.Split('\n').FirstOrDefault(l => l.StartsWith("Remote working directory:"));
        path = pwd?.Split(':', 2)[1].Trim() ?? target;
        location.Text = path;
        files = RelayaCoreMethods.SftpParseListing(r.Stdout).Where(f => f.name is not "." and not "..").ToList();
        list.Items.Clear();
        foreach (var f in files)
        {
            var row = new Grid { ColumnDefinitions = { new() { Width = GridLength.Auto }, new(), new() { Width = new GridLength(110) }, new() { Width = new GridLength(160) }, new() { Width = new GridLength(110) } }, ColumnSpacing = 12 };
            void Cell(UIElement e, int c) { Grid.SetColumn((FrameworkElement)e, c); row.Children.Add(e); }
            Cell(new FontIcon { Glyph = f.isDirectory ? "" : f.isLink ? "" : "", FontSize = Ui.IconMedium }, 0);
            Cell(new TextBlock { Text = f.name, TextTrimming = TextTrimming.CharacterEllipsis }, 1);
            Cell(Ui.Secondary(f.isDirectory ? "" : Platform.Format.Bytes(f.size)), 2);
            Cell(Ui.Secondary(f.modified), 3);
            Cell(Ui.Secondary(f.permissions), 4);
            list.Items.Add(new ListViewItem { Content = row, Tag = f });
        }
        status.Text = L("%@ объектов", files.Count);
    }

    // Windows: пикер привязывается к окну; на Linux (Uno) этого не нужно.
    /// Окно-владелец для системных диалогов выбора файла (WinUI без окна их не показывает).
    internal static void Attach(object picker)
    {
#if !HAS_UNO
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(MainWindow.Current!));
#endif
    }

    private async Task Download()
    {
        var sel = Selected();
        if (sel.Count == 0) { status.Text = L("Выберите файлы"); return; }
        var picker = new FolderPicker();
        picker.FileTypeFilter.Add("*");
        Attach(picker);
        if (await picker.PickSingleFolderAsync() is not { } folder) return;
        // Прогресс — по размеру скачанного файла в папке назначения; для папок размер неизвестен.
        foreach (var f in sel)
        {
            var target = System.IO.Path.Combine(folder.Path, f.name);
            Enqueue(new Job
            {
                Name = f.name, Commands = new[] { $"get -r {Q(Join(f.name))} {Q(folder.Path)}" }, Total = f.isDirectory ? 0 : f.size,
                Done = () => new System.IO.FileInfo(target) is { Exists: true } fi ? fi.Length : 0,
                Finished = () => { status.Text = L("Скачано в %@", folder.Path); return Task.CompletedTask; },
            });
        }
    }

    private async Task Upload()
    {
        var picker = new FileOpenPicker();
        picker.FileTypeFilter.Add("*");
        Attach(picker);
        var picked = await picker.PickMultipleFilesAsync();
        if (picked.Count > 0) await Put(picked.Select(f => f.Path));
    }

    private Task Put(IEnumerable<string> local)
    {
        // Загрузка: размер знаем, сколько уже на сервере — нет (sftp -b молчит), поэтому полоса неопределённая.
        var dir = path;
        foreach (var l in local)
            Enqueue(new Job
            {
                Name = System.IO.Path.GetFileName(l.TrimEnd('\\', '/')), Commands = new[] { $"put -r {Q(l)} {Q(dir)}" },
                Total = System.IO.File.Exists(l) ? new System.IO.FileInfo(l).Length : 0,
                Finished = async () => { if (path == dir) await Open(path); },
            });
        return Task.CompletedTask;
    }

    // 6.4, как на Mac: очередь передач — по одной за раз, у каждой состояние, скорость, «Отменить» и «Повторить».
    private enum JobState { Queued, Running, Done, Failed, Cancelled }

    private sealed class Job
    {
        public required string Name;
        public required string[] Commands;
        public long Total;
        public Func<long?>? Done;
        public Func<Task>? Finished;
        public JobState State;
        public string Error = "";
        public long Bytes;
        public DateTime Started;
        public DateTime Ended;
    }

    private readonly List<Job> jobs = new();
    private Job? running;
    private readonly StackPanel jobRows = new() { Spacing = 4 };
    private readonly Border queuePanel = new() { Visibility = Visibility.Collapsed };

    private void Enqueue(Job job)
    {
        jobs.Add(job);
        RenderJobs();
        if (running == null) _ = ProcessJobsAsync();
    }

    private async Task ProcessJobsAsync()
    {
        while (jobs.FirstOrDefault(j => j.State == JobState.Queued) is { } job)
        {
            running = job;
            job.State = JobState.Running;
            job.Started = DateTime.UtcNow;
            job.Bytes = 0;
            RenderJobs();
            var r = await Transfer(job.Commands, job.Total, job.Done, b => { job.Bytes = b; RenderJobs(); });
            job.Ended = DateTime.UtcNow;
            job.State = r.Status == 0 ? JobState.Done : cancelled ? JobState.Cancelled : JobState.Failed;
            job.Error = r.Status == 0 ? "" : status.Text;
            running = null;
            RenderJobs();
            if (job.State == JobState.Done && job.Finished != null) await job.Finished();
        }
    }

    private void RenderJobs()
    {
        jobRows.Children.Clear();
        queuePanel.Visibility = jobs.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        foreach (var job in jobs)
        {
            var row = new Grid { ColumnDefinitions = { new(), new() { Width = GridLength.Auto }, new() { Width = GridLength.Auto } }, ColumnSpacing = 12 };
            row.Children.Add(new TextBlock { Text = job.Name, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center });
            var state = Ui.Secondary(JobText(job));
            state.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(state, 1);
            row.Children.Add(state);
            UIElement? action = job.State switch
            {
                JobState.Queued => Ui.IconButton("", L("Отменить"), () => { job.State = JobState.Cancelled; RenderJobs(); }),
                JobState.Running => Ui.IconButton("", L("Отменить"), () => transferCancel?.Cancel()),
                JobState.Failed or JobState.Cancelled => Ui.IconButton("", L("Повторить"), () =>
                {
                    job.State = JobState.Queued;
                    RenderJobs();
                    if (running == null) _ = ProcessJobsAsync();
                }),
                _ => null,
            };
            if (action is FrameworkElement a) { Grid.SetColumn(a, 2); row.Children.Add(a); }
            jobRows.Children.Add(row);
        }
    }

    private static string JobText(Job job)
    {
        switch (job.State)
        {
            case JobState.Queued: return L("В очереди");
            case JobState.Cancelled: return L("Отменено");
            case JobState.Failed: return job.Error;
            case JobState.Done: return job.Total > 0 ? Platform.Format.Bytes(job.Total) : L("Готово");
        }
        var parts = new List<string>();
        if (job.Bytes > 0) parts.Add(job.Total > 0 ? L("%@ из %@", Platform.Format.Bytes(job.Bytes), Platform.Format.Bytes(job.Total)) : Platform.Format.Bytes(job.Bytes));
        var seconds = (DateTime.UtcNow - job.Started).TotalSeconds;
        if (job.Bytes > 0 && seconds >= 1) parts.Add(Platform.Format.Bytes((long)(job.Bytes / seconds)) + L("/с"));
        return string.Join(" · ", parts);
    }

    // 6.6, как на Mac: файл скачивается в личную папку Relaya (не в общий /tmp), открывается приложением по умолчанию,
    // каждое сохранение уходит обратно в ту же папку на сервере. Слежка — пока открыта страница файлов.
    private readonly List<System.IO.FileSystemWatcher> edits = new();

    private void Edit()
    {
        if (Selected() is not [{ isDirectory: false } f]) { status.Text = L("Выберите один файл"); return; }
        var remoteDir = path;
        var dir = System.IO.Path.Combine(AppState.Support, "edit", Guid.NewGuid().ToString("N"));
        System.IO.Directory.CreateDirectory(dir);
        var local = System.IO.Path.Combine(dir, f.name);
        long? Done() => new System.IO.FileInfo(local) is { Exists: true } fi ? fi.Length : 0;
        // Скачивание — через ту же очередь (одна передача за раз), открытие — когда оно закончилось.
        Enqueue(new Job
        {
            Name = f.name, Commands = new[] { $"get {Q(Join(f.name))} {Q(local)}" }, Total = f.size, Done = Done,
            Finished = () => StartEditing(f.name, dir, local, remoteDir),
        });
    }

    private async Task StartEditing(string name, string dir, string local, string remoteDir)
    {
        var watcher = new System.IO.FileSystemWatcher(dir, name) { NotifyFilter = System.IO.NotifyFilters.LastWrite | System.IO.NotifyFilters.Size };
        var ui = DispatcherQueue;
        var pending = false;
        // Редакторы пишут файл несколькими событиями подряд — загружаем раз, через секунду после первого.
        watcher.Changed += (_, _) => ui.TryEnqueue(async () =>
        {
            if (pending) return;
            pending = true;
            await Task.Delay(1000);
            pending = false;
            Enqueue(new Job
            {
                Name = name, Commands = new[] { $"put {Q(local)} {Q(remoteDir)}" }, Total = new System.IO.FileInfo(local).Length,
                Finished = () => { status.Text = L("Сохранено на сервере: %@", name); return Task.CompletedTask; },
            });
        });
        watcher.EnableRaisingEvents = true;
        edits.Add(watcher);
        try { Platform.Shell.OpenFile(local); status.Text = L("Изменения в %@ сохраняются на сервер, пока открыта эта вкладка", name); }
        catch (System.IO.IOException e) { await Ui.ShowError(XamlRoot, L("Не удалось открыть файл"), e.Message); }
    }

    private async Task NewFolder()
    {
        var name = await Ask(L("Новая папка"), "", L("Создать"));
        if (name is { Length: > 0 }) { await Batch($"mkdir {Q(Join(name))}"); await Open(path); }
    }

    private async Task Rename()
    {
        if (Selected().FirstOrDefault() is not { } f) return;
        var name = await Ask(L("Переименовать"), f.name, L("Переименовать"));
        if (name is { Length: > 0 } && name != f.name) { await Batch($"rename {Q(Join(f.name))} {Q(Join(name))}"); await Open(path); }
    }

    private async Task Delete()
    {
        var sel = Selected();
        if (sel.Count == 0) return;
        if (!await Ui.Confirm(XamlRoot, L("Удалить %@ объект(ов) на сервере?", sel.Count), string.Join("\n", sel.Select(f => f.name)), L("Удалить"))) return;
        // sftp не удаляет непустые папки рекурсивно — для них ssh rm -r.
        var dirs = sel.Where(f => f.isDirectory).ToList();
        if (sel.Except(dirs).Any()) await Batch(sel.Except(dirs).Select(f => $"rm {Q(Join(f.name))}").ToArray());
        foreach (var d in dirs)
        {
            var r = await AppState.RunOnHost(alias, "rm -r -- " + RelayaCoreMethods.CoreShellQuote(Join(d.name)));
            if (r.Status != 0) { await Open(path); status.Text = Platform.SshErrors.Describe(r.Stderr, L("Ошибка sftp")); return; }
        }
        await Open(path);
    }

    private async Task<string?> Ask(string title, string text, string action)
    {
        var box = new TextBox { Text = text };
        var d = new ContentDialog
        {
            Title = title, Content = box, PrimaryButtonText = action, CloseButtonText = L("Отмена"),
            DefaultButton = ContentDialogButton.Primary, XamlRoot = XamlRoot,
        };
        return await d.ShowAsync() == ContentDialogResult.Primary ? box.Text.Trim() : null;
    }
}
