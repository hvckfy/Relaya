using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Relaya.Platform;
using uniffi.relaya_core;
using Windows.System;
using static Relaya.Strings;
using DispatcherQueue = Microsoft.UI.Dispatching.DispatcherQueue;

namespace Relaya.Desktop;

/// Удалённый стол VNC во вкладке (VncSession ядра на RoyalVNCKit, чек-лист 9.13–9.14): кадры BGRA на RemoteScreen,
/// мышь, колесо, клавиши как X11 keysym, вход по паролю VNC, ARD (macOS) и MS-Logon. Колбэки ядра приходят из потока
/// сессии — в UI их переносит очередь, снятая в конструкторе, как в RdpView.
internal sealed class VncView : UserControl, IDisposable
{
    private RemoteDesktop desktop;
    private readonly DispatcherQueue ui = DispatcherQueue.GetForCurrentThread();
    private readonly RemoteScreen screen = new();
    private readonly StackPanel connecting;
    private readonly InfoBar problem = new() { Severity = InfoBarSeverity.Error, IsClosable = false, Margin = new Thickness(8) };
    private readonly AppBarToggleButton fit;
    private VncSession? session;
    private string? tunnelId;
    private string? pendingSave;
    private bool connected, disposed;
    private readonly bool[] buttons = new bool[5];
    // Нажатые клавиши, отправленные из KeyDown: KeyUp отпускает ровно их (Ctrl+буква, служебные, модификаторы).
    private readonly Dictionary<VirtualKey, uint> pressed = new();

    private string PasswordAccount => "desktop:" + desktop.id;

    public VncView(RemoteDesktop d)
    {
        desktop = d;
        fit = new AppBarToggleButton
        {
            Label = L("Вписать"),
            Icon = new FontIcon { Glyph = "" },
            IsChecked = Platform.Settings.Get($"desktop.{d.id}.fit", d.scaleToFit == false ? "0" : "1") == "1",
        };
        screen.Fit = fit.IsChecked == true;
        fit.Click += (_, _) => { Platform.Settings.Set($"desktop.{d.id}.fit", fit.IsChecked == true ? "1" : "0"); screen.Fit = fit.IsChecked == true; };
        var keys = new MenuFlyout();
        void Combo(string title, params uint[] keysyms)
        {
            var item = new MenuFlyoutItem { Text = title };
            item.Click += (_, _) => SendCombo(keysyms);
            keys.Items.Add(item);
        }
        Combo("Ctrl+Alt+Del", 0xffe3, 0xffe9, 0xffff);
        Combo("Alt+Tab", 0xffe9, 0xff09);
        var send = new AppBarButton { Label = L("Отправить сочетание"), Icon = new FontIcon { Glyph = "" }, Flyout = keys };
        // Во весь экран, как у RDP и на Mac: окно со столом целиком, выход — F11.
        var full = new AppBarButton { Label = L("Во весь экран"), Icon = new FontIcon { Glyph = "\uE740" } };
        full.Click += (_, _) => ToggleFullScreen();
        var stop = new AppBarButton { Label = L("Отключить"), Icon = new FontIcon { Glyph = "" } };
        stop.Click += (_, _) => session?.Disconnect();
        var bar = new CommandBar
        {
            DefaultLabelPosition = CommandBarDefaultLabelPosition.Right,
            IsDynamicOverflowEnabled = true,
            PrimaryCommands = { fit, send, full, stop },
        };
        connecting = new StackPanel
        {
            Spacing = 12,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Children = { new ProgressRing { IsActive = true, Width = 48, Height = 48 }, Pages.Ui.Secondary(L("Подключение…")) },
        };
        problem.IsOpen = false;
        var reconnect = new Button { Content = L("Подключить снова") };
        reconnect.Click += (_, _) => _ = ConnectAsync();
        problem.ActionButton = reconnect;

        var stage = new Grid { Children = { screen, connecting } };
        var root = new Grid { RowDefinitions = { new() { Height = GridLength.Auto }, new() { Height = GridLength.Auto }, new() } };
        root.Children.Add(bar);
        Grid.SetRow(problem, 1);
        root.Children.Add(problem);
        Grid.SetRow(stage, 2);
        root.Children.Add(stage);
        Content = root;

        IsTabStop = true;
        UseSystemFocusVisuals = false;
        screen.Surface.PointerPressed += (_, e) => { Focus(FocusState.Pointer); OnPointer(e); };
        screen.Surface.PointerMoved += (_, e) => OnPointer(e);
        screen.Surface.PointerReleased += (_, e) => OnPointer(e);
        screen.Surface.PointerWheelChanged += OnWheel;
        KeyDown += (_, e) => OnKey(e, true);
        KeyUp += (_, e) => OnKey(e, false);
        CharacterReceived += OnCharacter;
        LostFocus += (_, _) => ReleaseKeys();
        var started = false;
        Loaded += (_, _) => { if (started) return; started = true; _ = ConnectAsync(); };
    }

    // --- Подключение ---

    private async Task ConnectAsync()
    {
        try
        {
            if (disposed) return;
            problem.IsOpen = false;
            connecting.Visibility = Visibility.Visible;
            session?.Disconnect();
            session = null;
            connected = false;
            var (host, port, tunnel, error) = await DesktopLauncher.Endpoint(desktop);
            tunnelId = tunnel;
            if (error != null) { ShowProblem(L("Не удалось подключиться"), error); return; }
            // Сохранённый пароль — сразу; нет — ядро спросит через VncAuthListener, когда сервер скажет, какой вход нужен.
            var config = new VncConfig(host, (ushort)port, desktop.user.Length > 0 ? desktop.user : null, CredentialStore.Read(PasswordAccount), true);
            var s = VncSession.Vnc(config, new Listener(this));
            s.SetAuthListener(new AuthListener(this));
            session = s;
            await Task.Run(s.Connect);
        }
        catch (Exception e) { ShowProblem(L("Не удалось подключиться"), e.Message); }
    }

    private async Task AskCredentialsAsync(VncAuthKind kind, bool needsUser)
    {
        if (session is not { } s) return;
        try
        {
            var user = new TextBox { Header = L("Пользователь"), Text = desktop.user };
            var box = new PasswordBox { Header = L("Пароль") };
            var save = new CheckBox { Content = L("Сохранить пароль"), IsChecked = true };
            var panel = new StackPanel { Spacing = 8 };
            // V-3: прошлая попытка отклонена — причина прямо в форме, а не отдельной карточкой.
            if (authError is { } reason)
            {
                authError = null;
                panel.Children.Add(new InfoBar { Severity = InfoBarSeverity.Error, IsOpen = true, IsClosable = false, Title = reason });
            }
            if (kind == VncAuthKind.Vnc) panel.Children.Add(Pages.Ui.Secondary(L("Пароль VNC: у классического VNC учитываются только первые 8 символов.")));
            if (kind == VncAuthKind.AppleRemoteDesktop) panel.Children.Add(Pages.Ui.Secondary(L("Имя и пароль пользователя macOS.")));
            if (needsUser) panel.Children.Add(user);
            panel.Children.Add(box);
            panel.Children.Add(save);
            var dialog = new ContentDialog
            {
                Title = L("Вход на %@", desktop.name),
                Content = panel,
                PrimaryButtonText = L("Подключить"),
                CloseButtonText = L("Отмена"),
                DefaultButton = ContentDialogButton.Primary,
                XamlRoot = XamlRoot,
            };
            // Пустой пароль допустим, как в RDP (#32): сервер VNC может пускать без него.
            if (await dialog.ShowAsync() != ContentDialogResult.Primary)
            {
                credentialsCancelled = true;
                s.CancelCredentials();
                return;
            }
            // Пароль сохраняется только после успешного входа (как К12 у RDP).
            if (save.IsChecked == true && box.Password.Length > 0) pendingSave = box.Password;
            // V-2: имя для ARD и MS-Logon сохраняется в стол вместе с паролем, как на Mac.
            pendingUser = save.IsChecked == true && needsUser && user.Text.Trim() is { Length: > 0 } name && name != desktop.user ? name : null;
            credentialsCancelled = false;
            s.ProvideCredentials(needsUser ? user.Text.Trim() : null, box.Password);
        }
        catch (Exception e)
        {
            Terminal.TerminalView.Trace("VNC credentials: " + e.Message);
            s.CancelCredentials();
        }
    }

    private string? authError, pendingUser;
    private bool credentialsCancelled;

    private void ShowProblem(string title, string message)
    {
        connecting.Visibility = Visibility.Collapsed;
        problem.Title = title;
        problem.Message = message;
        problem.IsOpen = true;
    }

    // --- Колбэки ядра (поток сессии) ---

    private void OnConnectedCore(ushort w, ushort h)
    {
        screen.Reset(w, h);
        ui.TryEnqueue(() =>
        {
            connected = true;
            if (pendingSave is { } pass)
            {
                pendingSave = null;
                try { CredentialStore.Write(PasswordAccount, pass); }
                catch (Exception e) { Terminal.TerminalView.Trace("VNC password save: " + e.GetType().Name); }
            }
            if (pendingUser is { } name)
            {
                pendingUser = null;
                desktop = desktop with { user = name };
                Data.AppState.Desktops = Data.AppState.Desktops.Select(d => d.id == desktop.id ? d with { user = name } : d).ToList();
            }
            connecting.Visibility = Visibility.Collapsed;
            problem.IsOpen = false;
            Focus(FocusState.Programmatic);
        });
    }

    private void OnClosedCore(RemoteClose close) => ui.TryEnqueue(() =>
    {
        connected = false;
        if (disposed) return;
        if (close.kind == RemoteCloseKind.ClosedByUser) { ShowProblem(L("Отключено"), L("Сеанс завершён.")); return; }
        // Неверный пароль: сохранённый забываем и сразу переподключаемся — форма входа покажет причину (V-3, как RDP).
        // Временная блокировка сервера (AccountProblem, V-1) пароль не стирает — карточка с объяснением.
        if (close.kind == RemoteCloseKind.AuthFailed)
        {
            CredentialStore.Delete(PasswordAccount);
            authError = RelayaCoreMethods.RemoteExplain(RemoteProtocol.Vnc, close.message) is { } why ? L(why.title) : close.message;
            // Форму отменили — не спрашиваем по кругу, остаётся карточка.
            if (!credentialsCancelled) { _ = ConnectAsync(); return; }
            authError = null;
        }
        if (RelayaCoreMethods.RemoteExplain(RemoteProtocol.Vnc, close.message) is { } p) ShowProblem(L(p.title), L(p.hint));
        else ShowProblem(L("Соединение закрыто"), close.message);
    });

    // --- Ввод ---

    private void OnPointer(PointerRoutedEventArgs e)
    {
        if (session is not { } s || !connected) return;
        var point = e.GetCurrentPoint(screen.Surface);
        if (screen.ToRemote(point.Position) is { } at) s.Pointer(at.X, at.Y);
        var p = point.Properties;
        var state = new[] { p.IsLeftButtonPressed, p.IsMiddleButtonPressed, p.IsRightButtonPressed, p.IsXButton1Pressed, p.IsXButton2Pressed };
        for (var i = 0; i < 5; i++)
            if (state[i] != buttons[i]) { buttons[i] = state[i]; s.Button((byte)i, state[i]); }
        e.Handled = true;
    }

    private void OnWheel(object sender, PointerRoutedEventArgs e)
    {
        if (session is not { } s || !connected) return;
        var p = e.GetCurrentPoint(screen.Surface).Properties;
        var units = (short)Math.Clamp(p.MouseWheelDelta / 120 == 0 ? Math.Sign(p.MouseWheelDelta) : p.MouseWheelDelta / 120, short.MinValue, short.MaxValue);
        s.Wheel(p.IsHorizontalMouseWheel ? (short)-units : units, !p.IsHorizontalMouseWheel);
        e.Handled = true;
    }

    // Служебные клавиши и модификаторы — keysym из KeyDown/KeyUp; Ctrl+буква — тоже здесь (на Uno X11 символ в
    // CharacterReceived с Ctrl не приходит); остальные символы — из CharacterReceived через vnc_keysym_for_char.
    private void OnKey(KeyRoutedEventArgs e, bool down)
    {
        if (e.Key == VirtualKey.F11 && down) { e.Handled = true; ToggleFullScreen(); return; }
        if (session is not { } s || !connected) return;
        if (!down)
        {
            if (pressed.Remove(e.Key, out var ks)) { s.Key(ks, false); e.Handled = true; }
            return;
        }
        uint? keysym = Keysym(e.Key);
        if (keysym == null && e.Key is >= VirtualKey.A and <= VirtualKey.Z && (pressed.ContainsKey(VirtualKey.Control)
                || pressed.ContainsKey(VirtualKey.LeftControl) || pressed.ContainsKey(VirtualKey.RightControl)))
            keysym = (uint)('a' + (e.Key - VirtualKey.A));
        if (keysym is not { } k) return;
        if (!pressed.ContainsKey(e.Key)) pressed[e.Key] = k;
        s.Key(k, true);
        e.Handled = true;
    }

    private void OnCharacter(UIElement sender, CharacterReceivedRoutedEventArgs e)
    {
        if (session is not { } s || !connected) return;
        var ch = e.Character;
        if (ch < ' ' || ch == '\x7f' || char.IsSurrogate(ch)) return; // управляющие — из KeyDown
        var ks = RelayaCoreMethods.VncKeysymForChar(ch);
        s.Key(ks, true);
        s.Key(ks, false);
        e.Handled = true;
    }

    private void ReleaseKeys()
    {
        if (session is { } s) foreach (var ks in pressed.Values) s.Key(ks, false);
        pressed.Clear();
    }

    private void SendCombo(uint[] keysyms)
    {
        if (session is not { } s || !connected) return;
        foreach (var k in keysyms) s.Key(k, true);
        for (var i = keysyms.Length - 1; i >= 0; i--) s.Key(keysyms[i], false);
        Focus(FocusState.Programmatic);
    }

    // X11 keysym служебных клавиш и модификаторов.
    private static uint? Keysym(VirtualKey key) => key switch
    {
        VirtualKey.Back => 0xff08,
        VirtualKey.Tab => 0xff09,
        VirtualKey.Enter => 0xff0d,
        VirtualKey.Escape => 0xff1b,
        VirtualKey.Delete => 0xffff,
        VirtualKey.Insert => 0xff63,
        VirtualKey.Home => 0xff50,
        VirtualKey.End => 0xff57,
        VirtualKey.PageUp => 0xff55,
        VirtualKey.PageDown => 0xff56,
        VirtualKey.Left => 0xff51,
        VirtualKey.Up => 0xff52,
        VirtualKey.Right => 0xff53,
        VirtualKey.Down => 0xff54,
        VirtualKey.Shift or VirtualKey.LeftShift => 0xffe1,
        VirtualKey.RightShift => 0xffe2,
        VirtualKey.Control or VirtualKey.LeftControl => 0xffe3,
        VirtualKey.RightControl => 0xffe4,
        VirtualKey.Menu or VirtualKey.LeftMenu => 0xffe9,
        VirtualKey.RightMenu => 0xffea,
        VirtualKey.LeftWindows => 0xffeb,
        VirtualKey.RightWindows => 0xffec,
        VirtualKey.CapitalLock => 0xffe5,
        >= VirtualKey.F1 and <= VirtualKey.F12 => 0xffbe + (uint)(key - VirtualKey.F1),
        _ => null,
    };

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        try { session?.Disconnect(); } catch (Exception) { }
        session = null;
        if (tunnelId != null) TunnelManager.Shared.Stop(tunnelId);
    }

    private sealed class Listener(VncView view) : RemoteListener
    {
        public void OnConnected(ushort width, ushort height) => view.OnConnectedCore(width, height);
        public void OnFrame(List<FrameRect> rects) => view.screen.Update(rects);
        public void OnResize(ushort width, ushort height) => view.screen.Reset(width, height);
        public void OnCert(string sha256, string subject, CertNode node) { } // у VNC сертификата нет; шифрование — SSH-туннель
        public void OnClosed(RemoteClose close) => view.OnClosedCore(close);
    }

    private sealed class AuthListener(VncView view) : VncAuthListener
    {
        public void OnCredentials(VncAuthKind kind, bool needsUser) =>
            view.ui.TryEnqueue(() => _ = view.AskCredentialsAsync(kind, needsUser));
    }

    /// Окно, в котором показан стол (9.15: отдельное окно); по умолчанию — главное.
    public Window? HostWindow { get; set; }

    private Microsoft.UI.Windowing.AppWindow? Host => (HostWindow ?? MainWindow.Current)?.AppWindow;

    private void ToggleFullScreen() =>
        Host?.SetPresenter(Host.Presenter.Kind == Microsoft.UI.Windowing.AppWindowPresenterKind.FullScreen
            ? Microsoft.UI.Windowing.AppWindowPresenterKind.Default : Microsoft.UI.Windowing.AppWindowPresenterKind.FullScreen);
}
