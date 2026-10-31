using System;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Relaya.Data;
using Relaya.Platform;
using uniffi.relaya_core;
using static Relaya.Strings;

namespace Relaya.Pages;

/// Туннели -L/-R/-D: запуск и остановка, автостарт, статус — как на Mac.
internal sealed class TunnelsPage : UserControl
{
    public TunnelsPage()
    {
        TunnelManager.Shared.Changed += OnChanged;
        Unloaded += (_, _) => TunnelManager.Shared.Changed -= OnChanged;
        Build();
    }

    private void OnChanged() => DispatcherQueue.TryEnqueue(Build);

    private void Build()
    {
        var (page, body) = Ui.Scaffold(L("Туннели"), Ui.Button(L("Новый туннель"), async () => await Edit(null), accent: true, glyph: ""));
        Content = page;
        var list = AppState.Tunnels;
        var temporary = TunnelManager.Shared.Temporary;
        if (list.Count == 0 && temporary.Count == 0) body.Children.Add(Ui.Card(Ui.Secondary(L("Туннелей пока нет. Локальный (-L) открывает порт сервера у вас, удалённый (-R) — ваш порт на сервере, SOCKS (-D) — прокси через сервер."))));
        foreach (var t in list)
        {
            var (state, error) = TunnelManager.Shared.StatusOf(t);
            var on = state is TunnelManager.State.Running or TunnelManager.State.Starting;
            var toggle = new ToggleSwitch { IsOn = on, OnContent = "", OffContent = "", MinWidth = 0 };
            toggle.Toggled += (_, _) => { if (toggle.IsOn) TunnelManager.Shared.Start(t); else TunnelManager.Shared.Stop(t.id); };
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Children = { toggle } };
            actions.Children.Add(Ui.IconButton("", L("Изменить"), async () => await Edit(t)));
            actions.Children.Add(Ui.IconButton("", L("Удалить"), () =>
            {
                TunnelManager.Shared.Stop(t.id);
                AppState.Tunnels = AppState.Tunnels.Where(x => x.id != t.id).ToList();
                Build();
            }));
            var kind = t.kind switch { TunnelKind.Local => "-L", TunnelKind.Remote => "-R", _ => "-D" };
            var status = state switch
            {
                TunnelManager.State.Running => L("работает"),
                TunnelManager.State.Starting => L("запускается…"),
                TunnelManager.State.Failed => L("ошибка: %@", error ?? ""),
                _ => L("остановлен"),
            };
            body.Children.Add(Ui.Row("", t.name, $"{t.hostAlias} {kind} {RelayaCoreMethods.TunnelSpec(t)} · {status}" + (t.autoStart ? " · " + L("автостарт") : ""), actions));
        }
        // Туннели удалённых столов: живут, пока открыт клиент; здесь их можно только остановить.
        foreach (var t in temporary)
        {
            var (state, error) = TunnelManager.Shared.StatusOf(t);
            var stop = Ui.IconButton("\ue71a", L("Остановить"), () => TunnelManager.Shared.Stop(t.id));
            var status = state switch
            {
                TunnelManager.State.Running => L("работает"),
                TunnelManager.State.Starting => L("запускается…"),
                TunnelManager.State.Failed => L("ошибка: %@", error ?? ""),
                _ => L("остановлен"),
            };
            body.Children.Add(Ui.Row("\ue7f4", t.name, $"{t.hostAlias} -L {RelayaCoreMethods.TunnelSpec(t)} · {status}", stop));
        }
    }

    private async Task Edit(Tunnel? t)
    {
        var name = new TextBox { Header = L("Название"), Text = t?.name ?? "" };
        var host = new ComboBox { Header = L("Хост"), HorizontalAlignment = HorizontalAlignment.Stretch };
        foreach (var h in AppState.Hosts) host.Items.Add(h.alias);
        host.SelectedItem = t?.hostAlias ?? AppState.Hosts.FirstOrDefault()?.alias;
        var kind = new ComboBox { Header = L("Тип"), HorizontalAlignment = HorizontalAlignment.Stretch,
            Items = { L("Локальный (-L)"), L("Удалённый (-R)"), L("SOCKS-прокси (-D)") }, SelectedIndex = t == null ? 0 : (int)t.kind };
        var listen = new NumberBox { Header = L("Порт у вас"), Value = t?.listenPort ?? 8080, Minimum = 1, Maximum = 65535 };
        var target = new TextBox { Header = L("Куда (адрес со стороны сервера)"), Text = t?.targetHost ?? "localhost" };
        var targetPort = new NumberBox { Header = L("Порт назначения"), Value = t?.targetPort ?? 80, Minimum = 1, Maximum = 65535 };
        var auto = new ToggleSwitch { Header = L("Запускать вместе с Relaya"), IsOn = t?.autoStart == true };
        void Sync() => target.IsEnabled = targetPort.IsEnabled = kind.SelectedIndex != 2;
        kind.SelectionChanged += (_, _) => Sync();
        Sync();
        var d = new ContentDialog
        {
            Title = t == null ? L("Новый туннель") : L("Изменить туннель"),
            Content = new ScrollViewer { Content = new StackPanel { Spacing = 10, MinWidth = 400, Children = { name, host, kind, listen, target, targetPort, auto } } },
            PrimaryButtonText = L("Сохранить"), CloseButtonText = L("Отмена"), DefaultButton = ContentDialogButton.Primary, XamlRoot = XamlRoot,
        };
        if (await d.ShowAsync() != ContentDialogResult.Primary || host.SelectedItem is not string alias) return;
        var item = new Tunnel(t?.id ?? RelayaCoreMethods.CoreNewId(),
            name.Text.Trim().Length > 0 ? name.Text.Trim() : $"{alias}:{(long)listen.Value}", alias, (TunnelKind)kind.SelectedIndex,
            (long)listen.Value, target.Text.Trim(), (long)targetPort.Value, auto.IsOn);
        if (t != null) TunnelManager.Shared.Stop(t.id);
        AppState.Tunnels = AppState.Tunnels.Where(x => x.id != item.id).Append(item).ToList();
        Build();
    }
}
