using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Threading.Tasks;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Relaya.Data;
using Relaya.Platform;
using uniffi.relaya_core;
using Windows.ApplicationModel.DataTransfer;
using Windows.Foundation;
using Windows.Graphics.DirectX;
using Windows.System;
using static Relaya.Strings;
using DispatcherQueue = Microsoft.UI.Dispatching.DispatcherQueue;
using DispatcherQueuePriority = Microsoft.UI.Dispatching.DispatcherQueuePriority;
using DispatcherQueueTimer = Microsoft.UI.Dispatching.DispatcherQueueTimer;
using Rect = Windows.Foundation.Rect;
using Point = Windows.Foundation.Point;

namespace Relaya.Desktop;

/// Удалённый стол RDP во вкладке (FreeRDP в ядре): кадры BGRA на Win2D, ввод scancode/unicode/мышь,
/// динамическое разрешение, сертификат, буфер обмена. Колбэки ядра приходят из потока сессии —
/// в UI их переносит очередь, снятая в конструкторе (тот же надёжный путь, что у TerminalView).
internal sealed class RdpView : UserControl, IDisposable
{
    private readonly RemoteDesktop desktop;
    private readonly DispatcherQueue ui = DispatcherQueue.GetForCurrentThread();
    private readonly CanvasControl canvas = new();
    private readonly ProgressRing ring = new() { IsActive = true, Width = 48, Height = 48 };
    private readonly TextBlock ringText = Pages.Ui.Secondary(L("Подключение…"));
    private readonly StackPanel connecting;
    private readonly InfoBar problem = new() { Severity = InfoBarSeverity.Error, IsClosable = false, Margin = new Thickness(8) };
    private readonly AppBarToggleButton fit, clipboard;
    private readonly RdpAudio audio;
    private readonly DispatcherQueueTimer resizeTimer;

    private readonly object frameLock = new();
    private byte[] buffer = Array.Empty<byte>();
    private int remoteW, remoteH;

    private RemoteSession? session;
    private string? tunnelId;
    private bool connected, disposed, imeActive, settingClipboard;
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
            IsChecked = Settings.Get($"desktop.{d.id}.fit", d.scaleToFit == false ? "0" : "1") == "1",
        };
        fit.Click += (_, _) => { Settings.Set($"desktop.{d.id}.fit", fit.IsChecked == true ? "1" : "0"); canvas.Invalidate(); };
        clipboard = new AppBarToggleButton
        {
            Label = L("Общий буфер обмена"), Icon = new FontIcon { Glyph = "" },
            IsChecked = Settings.Get($"desktop.{d.id}.clipboard", "1") == "1",
        };
        clipboard.Click += (_, _) => Settings.Set($"desktop.{d.id}.clipboard", clipboard.IsChecked == true ? "1" : "0");

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
        audio = new RdpAudio(Settings.Get($"desktop.{d.id}.volume", "100"));
        var volume = new Slider { Minimum = 0, Maximum = 100, Width = 200, Value = audio.VolumePercent, Header = L("Громкость") };
        volume.ValueChanged += (_, e) => { audio.VolumePercent = (int)e.NewValue; Settings.Set($"desktop.{d.id}.volume", ((int)e.NewValue).ToString()); };
        var sound = new AppBarButton
        {
            Label = L("Звук"), Icon = new FontIcon { Glyph = "\uE767" },
            Flyout = new Flyout { Content = volume },
        };
        var stop = new AppBarButton { Label = L("Отключить"), Icon = new FontIcon { Glyph = "" } };
        stop.Click += (_, _) => session?.Disconnect();
        var bar = new CommandBar
        {
            DefaultLabelPosition = CommandBarDefaultLabelPosition.Right, IsDynamicOverflowEnabled = true,
            PrimaryCommands = { fit, clipboard, sound, send, full, stop },
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

        var stage = new Grid { Children = { canvas, connecting } };
        var root = new Grid { RowDefinitions = { new() { Height = GridLength.Auto }, new() { Height = GridLength.Auto }, new() } };
        root.Children.Add(bar);
        Grid.SetRow(problem, 1);
        root.Children.Add(problem);
        Grid.SetRow(stage, 2);
        root.Children.Add(stage);
        Content = root;

        canvas.Draw += OnDraw;
        IsTabStop = true;
        UseSystemFocusVisuals = false;
        canvas.PointerPressed += (_, e) => { Focus(FocusState.Pointer); OnPointer(e); };
        canvas.PointerMoved += (_, e) => OnPointer(e);
        canvas.PointerReleased += (_, e) => OnPointer(e);
        canvas.PointerWheelChanged += OnWheel;
        KeyDown += (_, e) => OnKey(e, true);
        KeyUp += (_, e) => OnKey(e, false);
        CharacterReceived += OnCharacter;
        SizeChanged += (_, _) => { if (connected) { resizeTimer.Stop(); resizeTimer.Start(); } };
        // Скрытая вкладка не рисует; кадры копятся в буфере, при показе — одна перерисовка.
        RegisterPropertyChangedCallback(VisibilityProperty, (_, _) => { if (Visibility == Visibility.Visible) canvas.Invalidate(); });
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
        var config = new RdpConfig(host, (ushort)port, user, password, domain, w, h, (uint)Math.Round(scale * 100),
            TrustedCert(), desktop.gatewayHost, GatewayUser(), CredentialStore.Read("desktop-gateway:" + desktop.id), GatewayDomain(), null);
        var s = RemoteSession.Rdp(config, new Listener(this));
        s.SetClipboardListener(new ClipListener(this));
        s.SetAudioListener(audio);
        session = s;
        await Task.Run(s.Connect);
    }

    private (ushort, ushort) PhysicalSize()
    {
        var scale = XamlRoot?.RasterizationScale ?? 1.0;
        var w = (int)Math.Max(640, ActualWidth * scale);
        var h = (int)Math.Max(480, (ActualHeight - 48) * scale);
        w -= w % 2; // чётная ширина — требование RDP к динамическому разрешению
        return ((ushort)Math.Min(w, 8192), (ushort)Math.Min(h, 8192));
    }

    private void SendResize()
    {
        if (session is not { } s || !connected) return;
        var (w, h) = PhysicalSize();
        if (w == remoteW && h == remoteH) return;
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
        var save = new CheckBox { Content = L("Сохранить в диспетчере учётных данных"), IsChecked = true };
        var dialog = new ContentDialog
        {
            Title = L("Пароль для %@", desktop.name), Content = new StackPanel { Spacing = 8, Children = { box, save } },
            PrimaryButtonText = L("Подключить"), CloseButtonText = L("Отмена"), DefaultButton = ContentDialogButton.Primary, XamlRoot = XamlRoot,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || box.Password.Length == 0) return null;
        if (save.IsChecked == true) CredentialStore.Write(PasswordAccount, box.Password);
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

    private void Trust(string sha256)
    {
        var map = LoadTrust();
        map[TrustKey] = sha256;
        Directory.CreateDirectory(AppState.Support);
        File.WriteAllText(TrustFile, JsonSerializer.Serialize(map));
    }

    private async void AskCert(string sha256, string subject)
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
        lock (frameLock) { remoteW = w; remoteH = h; buffer = new byte[w * h * 4]; }
        ui.TryEnqueue(() =>
        {
            connected = true;
            connecting.Visibility = Visibility.Collapsed;
            problem.IsOpen = false;
            Focus(FocusState.Programmatic);
            if (desktop.fullScreen) SetFullScreen(true);
            SendResize();
        });
    }

    private void OnFrameCore(List<FrameRect> rects)
    {
        lock (frameLock)
        {
            foreach (var r in rects)
            {
                if (r.x + r.width > remoteW || r.y + r.height > remoteH) continue;
                var row = r.width * 4;
                for (var y = 0; y < r.height; y++)
                    Buffer.BlockCopy(r.bgra, y * row, buffer, ((r.y + y) * remoteW + r.x) * 4, row);
            }
        }
        ui.TryEnqueue(() => { if (Visibility == Visibility.Visible) canvas.Invalidate(); });
    }

    private Rect target; // где на канве нарисован удалённый экран (DIP)

    private void OnDraw(CanvasControl sender, CanvasDrawEventArgs args)
    {
        var ds = args.DrawingSession;
        ds.Clear(Microsoft.UI.Colors.Black);
        CanvasBitmap? bitmap = null;
        try
        {
            lock (frameLock)
            {
                if (remoteW == 0 || remoteH == 0) return;
                bitmap = CanvasBitmap.CreateFromBytes(sender, buffer, remoteW, remoteH,
                    DirectXPixelFormat.B8G8R8A8UIntNormalized, 96, CanvasAlphaMode.Ignore);
            }
            var scale = XamlRoot?.RasterizationScale ?? 1.0;
            double cw = sender.ActualWidth, ch = sender.ActualHeight;
            double k = fit.IsChecked == true ? Math.Min(cw / remoteW, ch / remoteH) : 1.0 / scale;
            double w = remoteW * k, h = remoteH * k;
            target = new Rect(Math.Max(0, (cw - w) / 2), Math.Max(0, (ch - h) / 2), w, h);
            ds.DrawImage(bitmap, target, new Rect(0, 0, remoteW, remoteH));
        }
        catch (Exception e) { Terminal.TerminalView.Trace("RDP draw: " + e.Message); }
        finally { bitmap?.Dispose(); }
    }

    // --- Ввод ---

    private (ushort X, ushort Y)? Remote(Point p)
    {
        if (target.Width <= 0 || remoteW == 0) return null;
        var x = (p.X - target.X) * remoteW / target.Width;
        var y = (p.Y - target.Y) * remoteH / target.Height;
        if (x < 0 || y < 0 || x >= remoteW || y >= remoteH) return null;
        return ((ushort)x, (ushort)y);
    }

    private void OnPointer(PointerRoutedEventArgs e)
    {
        if (session is not { } s || !connected) return;
        var point = e.GetCurrentPoint(canvas);
        if (Remote(point.Position) is { } at) s.Pointer(at.X, at.Y);
        var p = point.Properties;
        var state = new[] { p.IsLeftButtonPressed, p.IsMiddleButtonPressed, p.IsRightButtonPressed, p.IsXButton1Pressed, p.IsXButton2Pressed };
        for (var i = 0; i < 5; i++)
            if (state[i] != buttons[i]) { buttons[i] = state[i]; s.Button((byte)i, state[i]); }
        e.Handled = true;
    }

    private void OnWheel(object sender, PointerRoutedEventArgs e)
    {
        if (session is not { } s || !connected) return;
        var p = e.GetCurrentPoint(canvas).Properties;
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
        var code = (ushort)e.KeyStatus.ScanCode;
        if (code == 0) return;
        if (e.KeyStatus.IsExtendedKey) code |= 0xE000;
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

    private static bool IsDown(VirtualKey key) =>
        InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

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

    private async void OnLocalClipboard(object? sender, object e)
    {
        if (settingClipboard || clipboard.IsChecked != true || session is not { } s || !connected) return;
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
        canvas.RemoveFromVisualTree();
    }

    private sealed class Listener(RdpView view) : RemoteListener
    {
        public void OnConnected(ushort width, ushort height) => view.OnConnectedCore(width, height);
        public void OnFrame(List<FrameRect> rects) => view.OnFrameCore(rects);
        public void OnResize(ushort width, ushort height) => view.OnConnectedCore(width, height);
        public void OnCert(string sha256, string subject) => view.ui.TryEnqueue(() => view.AskCert(sha256, subject));
        public void OnClosed(RemoteClose close) => view.OnClosedCore(close);
    }

    private sealed class ClipListener(RdpView view) : RemoteClipboardListener
    {
        public void OnRemoteClipboard(string text) => view.OnRemoteClipboard(text);
    }
}
