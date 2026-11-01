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

    /// Сразу редактор стола (из контекстного меню боковой панели).
    public DesktopsPage(string editId)
    {
        Build();
        if (AppState.Desktops.FirstOrDefault(x => x.id == editId) is { } d) _ = Edit(d);
    }

    private void Build()
    {
        var (page, body) = Ui.Scaffold(L("Удалённые столы"), Ui.Button(L("Новый стол"), async () => await Edit(null), accent: true, glyph: ""));
        Content = page;
        Ui.UnreadableBar(body, "desktops.json");
        var list = AppState.Desktops;
        if (list.Count == 0) body.Children.Add(Ui.Card(Ui.Secondary(L("Добавьте RDP- или VNC-подключение. Можно ходить через SSH-хост — туннель поднимется сам."))));
        foreach (var d in list)
        {
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
            actions.Children.Add(Ui.Button(L("Открыть"), () => Platform.DesktopLauncher.Open(d, XamlRoot), accent: true));
            // Запасной путь — внешний клиент платформы (mstsc / VNC-клиент Windows, FreeRDP / vncviewer / Remmina на Linux).
            actions.Children.Add(Ui.IconButton("\ue8a7", d.kind == DesktopKind.Rdp ? Platform.PlatformText.ExternalRdp() : Platform.PlatformText.ExternalVnc(),
                () => Platform.DesktopLauncher.OpenExternal(d, XamlRoot)));
            actions.Children.Add(Ui.IconButton("", L("Изменить"), async () => await Edit(d)));
            actions.Children.Add(Ui.IconButton("", L("Удалить"), async () => { if (await DeleteAsync(d, XamlRoot)) Build(); }));
            var via = d.viaSshHost is { Length: > 0 } v ? " · " + L("через %@", v) : "";
            body.Children.Add(Ui.Row(d.kind == DesktopKind.Rdp ? "" : "", d.name,
                $"{(d.kind == DesktopKind.Rdp ? "RDP" : "VNC")} {d.address}:{d.port}" + (d.user.Length > 0 ? $" · {d.user}" : "") + via, actions));
        }
    }

    /// Удаление стола с подтверждением и его паролями; общее для страницы и меню в боковой панели.
    public static async Task<bool> DeleteAsync(RemoteDesktop d, XamlRoot root)
    {
        if (!await Ui.Confirm(root, L("Удалить %@?", d.name), L("Удалённый стол будет удалён; сохранённые пароли тоже."), L("Удалить"))) return false;
        Platform.CredentialStore.Delete("desktop:" + d.id);
        Platform.CredentialStore.Delete("desktop-gateway:" + d.id);
        AppState.Desktops = AppState.Desktops.Where(x => x.id != d.id).ToList();
        AppState.LoadHosts();
        return true;
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
        // Группа стола (9.1): столы с одной группой собираются в папку в боковой панели.
        var group = new TextBox { Header = L("Группа"), Text = d?.group ?? "", PlaceholderText = L("необязательно") };
        var full = new ToggleSwitch { Header = L("Во весь экран"), IsOn = d?.fullScreen == true };
        // RD Gateway (RDP): адрес, пользователь и домен — в desktops.json, пароль — в хранилище учётных данных.
        var gwHost = new TextBox { Header = L("Шлюз (host или host:port)"), Text = d?.gatewayHost ?? "", PlaceholderText = L("пусто — без шлюза") };
        var gwUser = new TextBox { Header = L("Пользователь шлюза"), Text = d?.gatewayUser ?? "", PlaceholderText = L("пусто — как для сервера") };
        var gwDomain = new TextBox { Header = L("Домен шлюза"), Text = d?.gatewayDomain ?? "" };
        var gwPass = new PasswordBox
        {
            Header = L("Пароль шлюза"),
            PlaceholderText = d != null && Platform.CredentialStore.Has("desktop-gateway:" + d.id) ? L("Сохранён — введите новый, чтобы сменить") : L("пусто — как для сервера"),
        };
        var gateway = new Expander
        {
            Header = "RD Gateway", HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            IsExpanded = d?.gatewayHost is { Length: > 0 },
            Content = new StackPanel { Spacing = 8, Children = { gwHost, gwUser, gwDomain, gwPass } },
        };
        // Форма на всю страницу вместо ContentDialog (UI-W3): «Отмена» и «Сохранить» в заголовке.
        var error = new TextBlock { Foreground = Ui.Brush("SystemFillColorCriticalBrush"), TextWrapping = TextWrapping.Wrap };
        // V-SEC-1: VNC напрямую не шифрует экран и ввод и не проверяет сервер — предупреждаем, не запрещаем.
        var vncWarning = new InfoBar
        {
            Severity = InfoBarSeverity.Warning, IsClosable = false,
            Message = L("VNC без SSH-туннеля не шифрует экран и ввод и не проверяет, тот ли это сервер. Выберите SSH-хост в «Через SSH-хост», если сеть не доверенная."),
        };
        // Сброс доверия сертификату RDP (9.4) — только если оно сохранено.
        var trust = Ui.Button(L("Сбросить доверие"), () => { if (d != null) Desktop.RdpView.ForgetTrust(d.id); });
        trust.Visibility = d != null && d.kind == DesktopKind.Rdp && Desktop.RdpView.HasTrust(d.id) ? Visibility.Visible : Visibility.Collapsed;
        ToolTipService.SetToolTip(trust, L("При следующем подключении Relaya снова покажет сертификат сервера"));
        void SyncVnc() => vncWarning.IsOpen = kind.SelectedIndex == 1 && via.SelectedIndex <= 0;
        kind.SelectionChanged += (_, _) => SyncVnc();
        via.SelectionChanged += (_, _) => SyncVnc();
        SyncVnc();
        async Task SaveAsync()
        {
            if (address.Text.Trim().Length == 0) { error.Text = L("Укажите адрес"); return; }
            var item = new RemoteDesktop(d?.id ?? RelayaCoreMethods.CoreNewId(),
                name.Text.Trim().Length > 0 ? name.Text.Trim() : address.Text.Trim(), kind.SelectedIndex == 0 ? DesktopKind.Rdp : DesktopKind.Vnc,
                address.Text.Trim(), (long)port.Value, user.Text.Trim(), via.SelectedIndex > 0 ? via.SelectedItem as string : null, full.IsOn,
                d?.scaleToFit, d?.rdpWidth, d?.rdpHeight, d?.rdpRetina, group.Text.Trim() is { Length: > 0 } grp ? grp : null,
                gatewayHost: gwHost.Text.Trim() is { Length: > 0 } gh ? gh : null,
                gatewayUser: gwUser.Text.Trim() is { Length: > 0 } gu ? gu : null,
                gatewayDomain: gwDomain.Text.Trim() is { Length: > 0 } gd ? gd : null);
            try
            {
                if (gwPass.Password.Length > 0) Platform.CredentialStore.Write("desktop-gateway:" + item.id, gwPass.Password);
                else if (item.gatewayHost == null) Platform.CredentialStore.Delete("desktop-gateway:" + item.id);
            }
            catch (Exception e) { await Ui.ShowError(XamlRoot, L("Не удалось сохранить пароль"), e.Message); }
            AppState.Desktops = AppState.Desktops.Where(x => x.id != item.id).Append(item).ToList();
            AppState.LoadHosts();
            Build();
        }
        var (page, body) = Ui.Scaffold(d == null ? L("Новый удалённый стол") : L("Изменить стол"),
            Ui.Button(L("Отмена"), Build), Ui.Button(L("Сохранить"), () => _ = SaveAsync(), accent: true));
        body.Children.Add(new StackPanel
        {
            Spacing = 12, MaxWidth = 640, HorizontalAlignment = HorizontalAlignment.Left,
            Children = { name, kind, address, port, user, via, vncWarning, group, full, gateway, trust, error },
        });
        Content = page;
    }
}
