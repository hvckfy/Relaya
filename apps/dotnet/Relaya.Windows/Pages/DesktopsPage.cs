using System;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Relaya.Data;
using uniffi.relaya_core;
using static Relaya.Strings;

namespace Relaya.Pages;

/// Удалённые столы (VNC/RDP): тот же desktops.json, что на Mac; открываются системным RDP или установленным VNC-клиентом.
internal sealed class DesktopsPage : UserControl
{
    public DesktopsPage() => Build();

    private void Build()
    {
        var (page, body) = Ui.Scaffold(L("Удалённые столы"), Ui.Button(L("Новый стол"), async () => await Edit(null), accent: true, glyph: ""));
        Content = page;
        var list = AppState.Desktops;
        if (list.Count == 0) body.Children.Add(Ui.Card(Ui.Secondary(L("Добавьте RDP- или VNC-подключение. Можно ходить через SSH-хост — туннель поднимется сам."))));
        foreach (var d in list)
        {
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
            actions.Children.Add(Ui.Button(L("Открыть"), () => Platform.DesktopLauncher.Open(d, XamlRoot), accent: true));
            actions.Children.Add(Ui.IconButton("", L("Изменить"), async () => await Edit(d)));
            actions.Children.Add(Ui.IconButton("", L("Удалить"), () =>
            {
                AppState.Desktops = AppState.Desktops.Where(x => x.id != d.id).ToList();
                AppState.LoadHosts();
                Build();
            }));
            var via = d.viaSshHost is { Length: > 0 } v ? " · " + L("через %@", v) : "";
            body.Children.Add(Ui.Row(d.kind == DesktopKind.Rdp ? "" : "", d.name,
                $"{(d.kind == DesktopKind.Rdp ? "RDP" : "VNC")} {d.address}:{d.port}" + (d.user.Length > 0 ? $" · {d.user}" : "") + via, actions));
        }
    }

    private async Task Edit(RemoteDesktop? d)
    {
        var name = new TextBox { Header = L("Название"), Text = d?.name ?? "" };
        var kind = new ComboBox { Header = L("Протокол"), Items = { "RDP", "VNC" }, SelectedIndex = d?.kind == DesktopKind.Vnc ? 1 : 0, HorizontalAlignment = HorizontalAlignment.Stretch };
        var address = new TextBox { Header = L("Адрес"), Text = d?.address ?? "" };
        var port = new NumberBox { Header = L("Порт"), Value = d?.port ?? 3389, Minimum = 1, Maximum = 65535 };
        kind.SelectionChanged += (_, _) => { if (port.Value is 3389 or 5900) port.Value = kind.SelectedIndex == 0 ? 3389 : 5900; };
        var user = new TextBox { Header = L("Пользователь (для RDP)"), Text = d?.user ?? "" };
        var via = new ComboBox { Header = L("Через SSH-хост"), HorizontalAlignment = HorizontalAlignment.Stretch };
        via.Items.Add(L("Напрямую"));
        foreach (var h in AppState.Hosts) via.Items.Add(h.alias);
        via.SelectedItem = d?.viaSshHost is { Length: > 0 } v ? v : via.Items[0];
        var full = new ToggleSwitch { Header = L("Во весь экран"), IsOn = d?.fullScreen == true };
        var dialog = new ContentDialog
        {
            Title = d == null ? L("Новый удалённый стол") : L("Изменить стол"),
            Content = new ScrollViewer { Content = new StackPanel { Spacing = 10, MinWidth = 400, Children = { name, kind, address, port, user, via, full } } },
            PrimaryButtonText = L("Сохранить"), CloseButtonText = L("Отмена"), DefaultButton = ContentDialogButton.Primary, XamlRoot = XamlRoot,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || address.Text.Trim().Length == 0) return;
        var item = new RemoteDesktop(d?.id ?? RelayaCoreMethods.CoreNewId(),
            name.Text.Trim().Length > 0 ? name.Text.Trim() : address.Text.Trim(), kind.SelectedIndex == 0 ? DesktopKind.Rdp : DesktopKind.Vnc,
            address.Text.Trim(), (long)port.Value, user.Text.Trim(), via.SelectedIndex > 0 ? via.SelectedItem as string : null, full.IsOn,
            d?.scaleToFit, d?.rdpWidth, d?.rdpHeight, d?.rdpRetina, d?.group);
        AppState.Desktops = AppState.Desktops.Where(x => x.id != item.id).Append(item).ToList();
        AppState.LoadHosts();
        Build();
    }
}
