using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Relaya.Data;
using Relaya.Platform;
using uniffi.relaya_core;
using Windows.ApplicationModel.DataTransfer;
using Windows.Foundation;
using Windows.System;
using static Relaya.Strings;
using DispatcherQueue = Microsoft.UI.Dispatching.DispatcherQueue;
using DispatcherQueuePriority = Microsoft.UI.Dispatching.DispatcherQueuePriority;
using DispatcherQueueTimer = Microsoft.UI.Dispatching.DispatcherQueueTimer;
using Rect = Windows.Foundation.Rect;
using Point = Windows.Foundation.Point;

namespace Relaya.Desktop;

/// Удалённый стол RDP во вкладке (RDP в ядре): кадры BGRA, ввод scancode/unicode/мышь,
/// динамическое разрешение, сертификат, буфер обмена. Колбэки ядра приходят из потока сессии —
/// в UI их переносит очередь, снятая в конструкторе (тот же надёжный путь, что у TerminalView).
/// Экран — общий RemoteScreen (тот же, что у VNC); модификаторы, scancode и звук — в приложении:
/// RdpView.Windows.cs, RdpView.Linux.cs.
internal sealed partial class RdpView : UserControl, IDisposable
{
    private RemoteDesktop desktop;
    private readonly DispatcherQueue ui = DispatcherQueue.GetForCurrentThread();
    private readonly RemoteScreen screen = new();

    // --- Платформа ---
    /// Подготовка платформенного ввода (на Linux — отслеживание модификаторов), из конструктора.
    private partial void InitInput();
    /// Нажата ли клавиша-модификатор сейчас.
    private partial bool IsDown(VirtualKey key);
    /// Scancode PC/AT для RDP (0xE0xx — расширенные), 0 — неизвестна.
    private static partial ushort ScanCode(KeyRoutedEventArgs e);
    /// Подпись флажка «сохранить пароль» — по имени хранилища платформы.
    private static partial string SavePasswordText();
    private readonly ProgressRing ring = new() { IsActive = true, Width = 48, Height = 48 };
    private readonly TextBlock ringText = Pages.Ui.Secondary(L("Подключение…"));
    private readonly StackPanel connecting;
    private readonly InfoBar problem = new() { Severity = InfoBarSeverity.Error, IsClosable = false, Margin = new Thickness(8) };
    private readonly AppBarToggleButton fit, clipboard;
    private readonly RdpAudio audio;
    private readonly DispatcherQueueTimer resizeTimer;


    private RemoteSession? session;
    private string? tunnelId;
    private bool connected, disposed, imeActive, settingClipboard, fullScreenApplied;
    private string? pendingSave;
    private readonly bool[] buttons = new bool[5];

    public RdpView(RemoteDesktop d)
    {
        desktop = d;
        resizeTimer = ui.CreateTimer();
        resizeTimer.Interval = TimeSpan.FromMilliseconds(400);
        resizeTimer.IsRepeating = false;
        resizeTimer.Tick += (_, _) => SendResize();

        fit = new AppBarToggleButton
        {
            Label = L("Вписать"), Icon = new FontIcon { Glyph = "" },
            IsChecked = Platform.Settings.Get($"desktop.{d.id}.fit", d.scaleToFit == false ? "0" : "1") == "1",
        };
        fit.Click += (_, _) => { Platform.Settings.Set($"desktop.{d.id}.fit", fit.IsChecked == true ? "1" : "0"); screen.Fit = fit.IsChecked == true; };
        clipboard = new AppBarToggleButton
        {
            Label = L("Общий буфер обмена"), Icon = new FontIcon { Glyph = "" },
            IsChecked = Platform.Settings.Get($"desktop.{d.id}.clipboard", "1") == "1",
        };
        clipboard.Click += (_, _) =>
        {
            Platform.Settings.Set($"desktop.{d.id}.clipboard", clipboard.IsChecked == true ? "1" : "0");
            // Выключили обмен — на сервере не должен остаться наш последний текст (W-RDP-2).
            if (clipboard.IsChecked != true && connected) session?.SetClipboard("");
            else _ = SendLocalClipboard();
        };

        var keys = new MenuFlyout();
        void Combo(string title, params ushort[] codes)
        {
            var item = new MenuFlyoutItem { Text = title };
            item.Click += (_, _) => SendCombo(codes);
            keys.Items.Add(item);
        }
        Combo("Ctrl+Alt+Del", 0x1D, 0x38, 0xE053);
        Combo("Win", 0xE05B);
        Combo("Alt+Tab", 0x38, 0x0F);
        var send = new AppBarButton { Label = L("Отправить сочетание"), Icon = new FontIcon { Glyph = "" }, Flyout = keys };
        var full = new AppBarButton { Label = L("Во весь экран"), Icon = new FontIcon { Glyph = "" } };
        full.Click += (_, _) => ToggleFullScreen();
        // Звук: громкость и «без звука» на нашей стороне, хранится в настройках стола.
        audio = new RdpAudio(Platform.Settings.Get($"desktop.{d.id}.volume", "100"));
        var volume = new Slider { Minimum = 0, Maximum = 100, Width = 200, Value = audio.VolumePercent, Header = L("Громкость") };
        volume.ValueChanged += (_, e) => { audio.VolumePercent = (int)e.NewValue; Platform.Settings.Set($"desktop.{d.id}.volume", ((int)e.NewValue).ToString()); };
        var sound = new AppBarButton
        {
            Label = L("Звук"), Icon = new FontIcon { Glyph = "\uE767" },
            Flyout = new Flyout { Content = volume },
        };
        var resolution = new AppBarButton { Label = L("Разрешение"), Icon = new FontIcon { Glyph = "\uE740" }, Flyout = ResolutionMenu() };
        var stop = new AppBarButton { Label = L("Отключить"), Icon = new FontIcon { Glyph = "" } };
        stop.Click += (_, _) => session?.Disconnect();
        var bar = new CommandBar
        {
            DefaultLabelPosition = CommandBarDefaultLabelPosition.Right, IsDynamicOverflowEnabled = true,
            PrimaryCommands = { fit, resolution, clipboard, sound, send, full, stop },
        };

        connecting = new StackPanel
        {
            Spacing = 12, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            Children = { ring, ringText },
        };
        problem.IsOpen = false;
        var reconnect = new Button { Content = L("Подключить снова") };
        reconnect.Click += (_, _) => _ = Connect();
        problem.ActionButton = reconnect;

        screen.Fit = fit.IsChecked == true;
        InitInput();
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
        SizeChanged += (_, _) => { if (connected) { resizeTimer.Stop(); resizeTimer.Start(); } };
        // Скрытая вкладка не рисует; кадры копятся в буфере, при показе — одна перерисовка.
        RegisterPropertyChangedCallback(VisibilityProperty, (_, _) =>
        {
            if (Visibility != Visibility.Visible) return;
            _ = SendLocalClipboard();
        });
        Clipboard.ContentChanged += OnLocalClipboard;
        var started = false;
        Loaded += (_, _) => { if (started) return; started = true; _ = Connect(); };
    }

    // --- Подключение ---

    private string PasswordAccount => "desktop:" + desktop.id;

    private async Task Connect()
    {
        if (disposed) return;
        problem.IsOpen = false;
        connecting.Visibility = Visibility.Visible;
        session?.Disconnect();
        session = null;
        connected = false;

        if (CredentialStore.Read(PasswordAccount) is not { } password)
        {
            if (await AskPassword() is not { } entered) { ShowProblem(L("Нужен пароль"), L("Введите пароль, чтобы подключиться.")); return; }
            password = entered;
        }
        var (host, port, tunnel, error) = await DesktopLauncher.Endpoint(desktop);
        tunnelId = tunnel;
        if (error != null) { ShowProblem(L("Не удалось подключиться"), error); return; }

        var scale = XamlRoot?.RasterizationScale ?? 1.0;
        var (w, h) = PhysicalSize();
        var (user, domain) = SplitUser(desktop.user);
        var config = new RdpConfig(host, (ushort)port, user, password, domain, w, h, (uint)Math.Round((desktop.rdpRetina == false ? 1.0 : scale) * 100),
            TrustedCert(), desktop.gatewayHost, GatewayUser(), CredentialStore.Read("desktop-gateway:" + desktop.id), GatewayDomain(),
            OpenH264.LibraryPath); // H.264 — только включённый и проверенный кодек (9.12)
        var s = RemoteSession.Rdp(config, new Listener(this));
        s.SetClipboardListener(new ClipListener(this));
        s.SetAudioListener(audio);
        session = s;
        await Task.Run(s.Connect);
    }

    private (ushort, ushort) PhysicalSize()
    {
        // Фиксированное разрешение из настроек стола (9.8, как на Mac); ширина/высота зажимаются в допустимые для RDP.
        if (desktop.rdpWidth is { } fw && desktop.rdpHeight is { } fh)
        {
            var cw = (int)Math.Clamp(fw, 640, 8192);
            cw -= cw % 2;
            return ((ushort)cw, (ushort)Math.Clamp(fh, 480, 8192));
        }
        // «100%» — пиксели окна без масштаба экрана (больше места), «Retina» — с масштабом (крупнее).
        var scale = desktop.rdpRetina == false ? 1.0 : XamlRoot?.RasterizationScale ?? 1.0;
        var w = (int)Math.Max(640, ActualWidth * scale);
        var h = (int)Math.Max(480, (ActualHeight - 48) * scale);
        w -= w % 2; // чётная ширина — требование RDP к динамическому разрешению
        return ((ushort)Math.Min(w, 8192), (ushort)Math.Min(h, 8192));
    }

    private static readonly (int W, int H)[] Presets = { (1280, 720), (1440, 900), (1920, 1080), (2560, 1440), (3840, 2160) };

    /// «Разрешение»: по размеру окна или фиксированное, масштаб Retina/100% — меняется на лету, сохраняется в столе (9.8).
    private MenuFlyout ResolutionMenu()
    {
        var menu = new MenuFlyout();
        ToggleMenuFlyoutItem Check(string text, bool on, Action apply)
        {
            var i = new ToggleMenuFlyoutItem { Text = text, IsChecked = on };
            i.Click += (_, _) => { apply(); SendResize(); Refresh(); };
            return i;
        }
        void Refresh()
        {
            menu.Items.Clear();
            menu.Items.Add(Check(L("По размеру окна"), desktop.rdpWidth == null, () => Persist(desktop with { rdpWidth = null, rdpHeight = null })));
            menu.Items.Add(new MenuFlyoutSeparator());
            foreach (var (pw, ph) in Presets)
                menu.Items.Add(Check($"{pw} × {ph}", desktop.rdpWidth == pw && desktop.rdpHeight == ph,
                    () => Persist(desktop with { rdpWidth = pw, rdpHeight = ph })));
            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(Check(L("Масштаб Retina — крупный интерфейс"), desktop.rdpRetina != false, () => Persist(desktop with { rdpRetina = true })));
            menu.Items.Add(Check(L("Масштаб 100% — больше места"), desktop.rdpRetina == false, () => Persist(desktop with { rdpRetina = false })));
        }
        Refresh();
        return menu;
    }

    private void Persist(RemoteDesktop updated)
    {
        desktop = updated;
        var list = AppState.Desktops;
        var i = list.FindIndex(d => d.id == updated.id);
        if (i >= 0) { list[i] = updated; AppState.Desktops = list; }
    }

    private void SendResize()
    {
        if (session is not { } s || !connected) return;
        var (w, h) = PhysicalSize();
        if (screen.Size == (w, h)) return;
        s.Resize(w, h);
    }

    // Шлюз: пользователь `DOMAIN\user` раскладывается так же, как у сервера; пустой — те же данные, что для сервера.
    private string? GatewayUser() => desktop.gatewayUser is { Length: > 0 } u ? SplitUser(u).User : null;
    private string? GatewayDomain() =>
        desktop.gatewayDomain is { Length: > 0 } d ? d : desktop.gatewayUser is { Length: > 0 } u ? SplitUser(u).Domain : null;

    // `DOMAIN\user` или `user@domain` — домен отдельно.
    private static (string User, string? Domain) SplitUser(string user)
    {
        var i = user.IndexOf('\\');
        return i > 0 ? (user[(i + 1)..], user[..i]) : (user, null);
    }

    private async Task<string?> AskPassword()
    {
        var box = new PasswordBox { Header = L("Пароль") };
        var save = new CheckBox { Content = SavePasswordText(), IsChecked = true };
        var dialog = new ContentDialog
        {
            Title = L("Пароль для %@", desktop.name), Content = new StackPanel { Spacing = 8, Children = { box, save } },
            PrimaryButtonText = L("Подключить"), CloseButtonText = L("Отмена"), DefaultButton = ContentDialogButton.Primary, XamlRoot = XamlRoot,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || box.Password.Length == 0) return null;
        // Сохраняем только после успешного входа (К12, как на Mac): неверный пароль в хранилище не попадает.
        pendingSave = save.IsChecked == true ? box.Password : null;
        return box.Password;
    }

    private void ShowProblem(string title, string message)
    {
        connecting.Visibility = Visibility.Collapsed;
        problem.Title = title;
        problem.Message = message;
        problem.IsOpen = true;
    }

    // --- Доверие сертификату: %APPDATA%\Relaya\rdp-trust.json, ключ — стол и SSH-хост (как certificateKey на Mac) ---

    private static readonly string TrustFile = Path.Combine(AppState.Support, "rdp-trust.json");
    private string TrustKey => desktop.id + "|" + (desktop.viaSshHost ?? "");

    private static Dictionary<string, string> LoadTrust()
    {
        try { return JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(TrustFile)) ?? new(); }
        catch (Exception) { return new(); }
    }

    private string? TrustedCert() => LoadTrust().GetValueOrDefault(TrustKey);

    /// Есть ли сохранённое доверие сертификату для стола (любой путь — напрямую или через SSH-хост).
    public static bool HasTrust(string desktopId) => LoadTrust().Keys.Any(k => k.StartsWith(desktopId + "|"));

    /// «Сбросить доверие» (9.4): при следующем подключении сертификат спросят снова.
    public static void ForgetTrust(string desktopId)
    {
        var map = LoadTrust();
        foreach (var k in map.Keys.Where(k => k.StartsWith(desktopId + "|")).ToList()) map.Remove(k);
        AtomicFile.Write(TrustFile, JsonSerializer.Serialize(map));
    }

    private void Trust(string sha256)
    {
        var map = LoadTrust();
        map[TrustKey] = sha256;
        Directory.CreateDirectory(AppState.Support);
        AtomicFile.Write(TrustFile, JsonSerializer.Serialize(map));
    }

    private bool certOpen;

    // Диалоги сертификата — по одному (W-RDP-7); любая ошибка показа — отказ, а не зависшее подключение.
    private async Task AskCertAsync(string sha256, string subject)
    {
        if (certOpen) { session?.AcceptCert(false); return; }
        certOpen = true;
        try { await AskCertCore(sha256, subject); }
        catch (Exception e) { Terminal.TerminalView.Trace("RDP cert dialog: " + e.Message); session?.AcceptCert(false); }
        finally { certOpen = false; }
    }

    private async Task AskCertCore(string sha256, string subject)
    {
        var previous = TrustedCert();
        var content = new StackPanel { Spacing = 8 };
        if (previous != null && previous != sha256)
            content.Children.Add(new InfoBar
            {
                Severity = InfoBarSeverity.Warning, IsOpen = true, IsClosable = false,
                Title = L("Отпечаток изменился"), Message = L("Раньше у этого сервера был другой сертификат. Убедитесь, что подключаетесь к нужному серверу."),
            });
        content.Children.Add(new TextBlock { Text = subject, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
        content.Children.Add(Pages.Ui.Secondary("SHA-256"));
        content.Children.Add(new TextBlock
        {
            Text = sha256, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true,
            FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Cascadia Mono, Consolas"),
        });
        var dialog = new ContentDialog
        {
            Title = L("Проверьте сертификат сервера"), Content = content,
            PrimaryButtonText = L("Доверять"), CloseButtonText = L("Отмена"), DefaultButton = ContentDialogButton.Close, XamlRoot = XamlRoot,
        };
        var ok = await dialog.ShowAsync() == ContentDialogResult.Primary;
        if (ok) Trust(sha256);
        session?.AcceptCert(ok);
    }

    // --- Кадры ---

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
                catch (Exception e) { Terminal.TerminalView.Trace("RDP password save: " + e.GetType().Name); }
            }
            connecting.Visibility = Visibility.Collapsed;
            problem.IsOpen = false;
            Focus(FocusState.Programmatic);
            // Во весь экран — только при первом подключении: OnResize тоже приходит сюда и не должен
            // возвращать полноэкранный режим, из которого пользователь вышел (К11).
            if (desktop.fullScreen && !fullScreenApplied) { fullScreenApplied = true; SetFullScreen(true); }
            SendResize();
        });
    }

    private void OnFrameCore(List<FrameRect> rects) => screen.Update(rects);

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
        var delta = (short)Math.Clamp(p.MouseWheelDelta, short.MinValue, short.MaxValue);
        s.Wheel(p.IsHorizontalMouseWheel ? (short)-delta : delta, !p.IsHorizontalMouseWheel);
        e.Handled = true;
    }

    private void OnKey(KeyRoutedEventArgs e, bool down)
    {
        if (e.Key == VirtualKey.F11 && down) { e.Handled = true; ToggleFullScreen(); return; }
        if (e.Key == VirtualKey.Cancel && down && IsDown(VirtualKey.Control) && IsDown(VirtualKey.Menu)) // Ctrl+Alt+Break
        { e.Handled = true; SetFullScreen(false); return; }
        if (session is not { } s || !connected) return;
        // IME: символы придут в CharacterReceived и уйдут как unicode.
        if ((int)e.Key == 229) { imeActive = true; e.Handled = true; return; }
        imeActive = false;
        var code = ScanCode(e);
        if (code == 0) return;
        s.Key(code, down);
        e.Handled = true;
    }

    private void OnCharacter(UIElement sender, CharacterReceivedRoutedEventArgs e)
    {
        if (!imeActive || session is not { } s || !connected) return;
        s.Unicode(e.Character, true);
        s.Unicode(e.Character, false);
        e.Handled = true;
    }

    private void SendCombo(ushort[] codes)
    {
        if (session is not { } s || !connected) return;
        foreach (var c in codes) s.Key(c, true);
        for (var i = codes.Length - 1; i >= 0; i--) s.Key(codes[i], false);
        Focus(FocusState.Programmatic);
    }

    // --- Во весь экран: окно Relaya целиком (AppWindow FullScreen), выход — F11 или Ctrl+Alt+Break ---

    private void ToggleFullScreen() =>
        SetFullScreen(MainWindow.Current?.AppWindow.Presenter.Kind != AppWindowPresenterKind.FullScreen);

    private static void SetFullScreen(bool on) =>
        MainWindow.Current?.AppWindow.SetPresenter(on ? AppWindowPresenterKind.FullScreen : AppWindowPresenterKind.Default);

    // --- Буфер обмена ---

    // Локальный буфер уходит только на стол, вкладка которого видна (W-RDP-1); при показе вкладки — один раз.
    private async void OnLocalClipboard(object? sender, object e)
    {
        if (settingClipboard || Visibility != Visibility.Visible) return;
        await SendLocalClipboard();
    }

    private async Task SendLocalClipboard()
    {
        if (clipboard.IsChecked != true || session is not { } s || !connected) return;
        try
        {
            var view = Clipboard.GetContent();
            if (view.Contains(StandardDataFormats.Text)) s.SetClipboard(await view.GetTextAsync());
        }
        catch (Exception) { /* буфер занят другим приложением */ }
    }

    private void OnRemoteClipboard(string text) => ui.TryEnqueue(() =>
    {
        if (clipboard.IsChecked != true) return;
        var package = new DataPackage();
        package.SetText(text);
        settingClipboard = true; // своё изменение не отправляем обратно
        try { Clipboard.SetContent(package); }
        catch (Exception) { }
        ui.TryEnqueue(DispatcherQueuePriority.Low, () => settingClipboard = false);
    });

    // --- Закрытие ---

    private void OnClosedCore(RemoteClose close) => ui.TryEnqueue(() =>
    {
        connected = false;
        if (disposed) return;
        if (close.kind == RemoteCloseKind.ClosedByUser) { ShowProblem(L("Отключено"), L("Сеанс завершён.")); return; }
        // Неверный сохранённый пароль: забываем его, иначе «Подключить снова» упирается в тот же отказ (К12).
        if (close.kind == RemoteCloseKind.AuthFailed) CredentialStore.Delete(PasswordAccount);
        if (RelayaCoreMethods.RemoteExplain(RemoteProtocol.Rdp, close.message) is { } p) ShowProblem(L(p.title), L(p.hint));
        else ShowProblem(L("Соединение закрыто"), close.message);
    });

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        Clipboard.ContentChanged -= OnLocalClipboard;
        resizeTimer.Stop();
        try { session?.Disconnect(); } catch (Exception) { }
        session = null;
        if (tunnelId != null) TunnelManager.Shared.Stop(tunnelId);
        audio.Dispose();
    }

    private sealed class Listener(RdpView view) : RemoteListener
    {
        public void OnConnected(ushort width, ushort height) => view.OnConnectedCore(width, height);
        public void OnFrame(List<FrameRect> rects) => view.OnFrameCore(rects);
        public void OnResize(ushort width, ushort height) => view.OnConnectedCore(width, height);
        public void OnCert(string sha256, string subject) => view.ui.TryEnqueue(() => _ = view.AskCertAsync(sha256, subject));
        public void OnClosed(RemoteClose close) => view.OnClosedCore(close);
    }

    private sealed class ClipListener(RdpView view) : RemoteClipboardListener
    {
        public void OnRemoteClipboard(string text) => view.OnRemoteClipboard(text);
    }
}
