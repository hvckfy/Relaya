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
        Grid.SetRow(busy, 1);
        root.Children.Add(busy);
        Grid.SetRow(list, 2);
        root.Children.Add(list);
        Grid.SetRow(status, 3);
        root.Children.Add(status);
        Content = root;
        AllowDrop = true;
        DragOver += (_, e) => { e.AcceptedOperation = DataPackageOperation.Copy; e.DragUIOverride.Caption = L("Загрузить в %@", path); };
        Drop += async (_, e) =>
        {
            if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
            var items = await e.DataView.GetStorageItemsAsync();
            await Put(items.Select(i => i.Path));
        };
        Loaded += async (_, _) => await Open(".");
    }

    private List<RemoteFile> Selected() => list.SelectedItems.OfType<ListViewItem>().Select(i => (RemoteFile)i.Tag).ToList();

    private string Join(string name) => path == "/" ? "/" + name : path.TrimEnd('/') + "/" + name;

    private static string Parent(string p)
    {
        if (p is "." or "/" or "~") return p == "." ? ".." : p;
        var i = p.TrimEnd('/').LastIndexOf('/');
        return i <= 0 ? (p.StartsWith('/') ? "/" : p + "/..") : p[..i];
    }

    private static string Q(string s) => "\"" + s.Replace("\"", "\\\"") + "\"";

    private async Task<AppState.Result> Batch(params string[] commands)
    {
        busy.Visibility = Visibility.Visible;
        var r = await AppState.Run(AppState.SftpExe, new[] { "-b", "-", "-o", "ConnectTimeout=10", alias }, alias,
            string.Join("\n", commands) + "\n", 600);
        busy.Visibility = Visibility.Collapsed;
        if (r.Status != 0)
            status.Text = (r.Stderr.Trim().Split('\n').LastOrDefault(l => !l.StartsWith("sftp>")) ?? L("Ошибка sftp")).Trim();
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
            Cell(new FontIcon { Glyph = f.isDirectory ? "" : f.isLink ? "" : "", FontSize = 16 }, 0);
            Cell(new TextBlock { Text = f.name, TextTrimming = TextTrimming.CharacterEllipsis }, 1);
            Cell(Ui.Secondary(f.isDirectory ? "" : Size(f.size)), 2);
            Cell(Ui.Secondary(f.modified), 3);
            Cell(Ui.Secondary(f.permissions), 4);
            list.Items.Add(new ListViewItem { Content = row, Tag = f });
        }
        status.Text = L("%@ объектов", files.Count);
    }

    private static string Size(long b)
    {
        double v = b;
        foreach (var u in new[] { "B", "KB", "MB", "GB" })
        {
            if (v < 1024) return $"{v:0.#} {u}";
            v /= 1024;
        }
        return $"{v:0.#} TB";
    }

    private static nint Hwnd => WinRT.Interop.WindowNative.GetWindowHandle(MainWindow.Current!);

    private async Task Download()
    {
        var sel = Selected();
        if (sel.Count == 0) { status.Text = L("Выберите файлы"); return; }
        var picker = new FolderPicker();
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, Hwnd);
        if (await picker.PickSingleFolderAsync() is not { } folder) return;
        var r = await Batch(sel.Select(f => $"get -r {Q(Join(f.name))} {Q(folder.Path)}").ToArray());
        if (r.Status == 0) status.Text = L("Скачано в %@", folder.Path);
    }

    private async Task Upload()
    {
        var picker = new FileOpenPicker();
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, Hwnd);
        var picked = await picker.PickMultipleFilesAsync();
        if (picked.Count > 0) await Put(picked.Select(f => f.Path));
    }

    private async Task Put(IEnumerable<string> local)
    {
        var r = await Batch(local.Select(l => $"put -r {Q(l)} {Q(path)}").ToArray());
        if (r.Status == 0) await Open(path);
    }

    private async Task NewFolder()
    {
        var name = await Ask(L("Новая папка"), "");
        if (name is { Length: > 0 }) { await Batch($"mkdir {Q(Join(name))}"); await Open(path); }
    }

    private async Task Rename()
    {
        if (Selected().FirstOrDefault() is not { } f) return;
        var name = await Ask(L("Переименовать"), f.name);
        if (name is { Length: > 0 } && name != f.name) { await Batch($"rename {Q(Join(f.name))} {Q(Join(name))}"); await Open(path); }
    }

    private async Task Delete()
    {
        var sel = Selected();
        if (sel.Count == 0) return;
        if (!await Ui.Confirm(XamlRoot, L("Удалить %@ объект(ов)?", sel.Count), string.Join("\n", sel.Select(f => f.name)), L("Удалить"))) return;
        // sftp не удаляет непустые папки рекурсивно — для них ssh rm -r.
        var dirs = sel.Where(f => f.isDirectory).ToList();
        if (sel.Except(dirs).Any()) await Batch(sel.Except(dirs).Select(f => $"rm {Q(Join(f.name))}").ToArray());
        foreach (var d in dirs) await AppState.RunOnHost(alias, "rm -r -- " + RelayaCoreMethods.CoreShellQuote(Join(d.name)));
        await Open(path);
    }

    private async Task<string?> Ask(string title, string text)
    {
        var box = new TextBox { Text = text };
        var d = new ContentDialog
        {
            Title = title, Content = box, PrimaryButtonText = "OK", CloseButtonText = L("Отмена"),
            DefaultButton = ContentDialogButton.Primary, XamlRoot = XamlRoot,
        };
        return await d.ShowAsync() == ContentDialogResult.Primary ? box.Text.Trim() : null;
    }
}
