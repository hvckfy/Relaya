using System;
using System.Collections.Generic;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Input;
using SkiaSharp;
using Uno.WinUI.Graphics2DSK;
using Windows.Foundation;
using Windows.System;
using static Relaya.Strings;

namespace Relaya.Desktop;

/// Холст удалённого стола на Linux: SkiaSharp (SKCanvasElement), scancode — по VirtualKey (в Uno X11 KeyStatus.ScanCode нет).
internal sealed partial class RdpView
{
    private Surface surface = null!;
    // Модификаторы — по KeyDown/KeyUp этой вкладки (как в TerminalView.Skia), сброс при потере фокуса.
    private readonly HashSet<VirtualKey> down = new();

    private partial void CreateCanvas()
    {
        surface = new Surface(this);
        canvas = surface;
        AddHandler(KeyDownEvent, new KeyEventHandler((_, e) => Track(e.Key, true)), handledEventsToo: true);
        AddHandler(KeyUpEvent, new KeyEventHandler((_, e) => Track(e.Key, false)), handledEventsToo: true);
        LostFocus += (_, _) => { lock (down) down.Clear(); };
    }

    private void Track(VirtualKey key, bool pressed)
    {
        var k = key switch
        {
            VirtualKey.LeftControl or VirtualKey.RightControl => VirtualKey.Control,
            VirtualKey.LeftShift or VirtualKey.RightShift => VirtualKey.Shift,
            VirtualKey.LeftMenu or VirtualKey.RightMenu => VirtualKey.Menu,
            _ => key,
        };
        lock (down) { if (pressed) down.Add(k); else down.Remove(k); }
    }

    private partial void InvalidateCanvas() => surface.Invalidate();

    private partial void RemoveCanvas() { }

    private partial bool IsDown(VirtualKey key) { lock (down) return down.Contains(key); }

    private static partial string SavePasswordText() => L("Сохранить в связке ключей");

    private static partial ushort ScanCode(KeyRoutedEventArgs e) => Codes.TryGetValue(e.Key, out var c) ? c : (ushort)0;

    // Scancode set 1 (то, что ждёт RDP); 0xE0xx — расширенные клавиши.
    private static readonly Dictionary<VirtualKey, ushort> Codes = Build();

    private static Dictionary<VirtualKey, ushort> Build()
    {
        var m = new Dictionary<VirtualKey, ushort>
        {
            [VirtualKey.Escape] = 0x01, [VirtualKey.Back] = 0x0E, [VirtualKey.Tab] = 0x0F, [VirtualKey.Enter] = 0x1C,
            [VirtualKey.Control] = 0x1D, [VirtualKey.LeftControl] = 0x1D, [VirtualKey.RightControl] = 0xE01D,
            [VirtualKey.Shift] = 0x2A, [VirtualKey.LeftShift] = 0x2A, [VirtualKey.RightShift] = 0x36,
            [VirtualKey.Menu] = 0x38, [VirtualKey.LeftMenu] = 0x38, [VirtualKey.RightMenu] = 0xE038,
            [VirtualKey.Space] = 0x39, [VirtualKey.CapitalLock] = 0x3A, [VirtualKey.NumberKeyLock] = 0x45, [VirtualKey.Scroll] = 0x46,
            [VirtualKey.LeftWindows] = 0xE05B, [VirtualKey.RightWindows] = 0xE05C, [VirtualKey.Application] = 0xE05D,
            [VirtualKey.Insert] = 0xE052, [VirtualKey.Delete] = 0xE053, [VirtualKey.Home] = 0xE047, [VirtualKey.End] = 0xE04F,
            [VirtualKey.PageUp] = 0xE049, [VirtualKey.PageDown] = 0xE051,
            [VirtualKey.Up] = 0xE048, [VirtualKey.Down] = 0xE050, [VirtualKey.Left] = 0xE04B, [VirtualKey.Right] = 0xE04D,
            [VirtualKey.Snapshot] = 0xE037, [VirtualKey.Divide] = 0xE035, [VirtualKey.Multiply] = 0x37,
            [VirtualKey.Subtract] = 0x4A, [VirtualKey.Add] = 0x4E, [VirtualKey.Decimal] = 0x53,
            [VirtualKey.NumberPad7] = 0x47, [VirtualKey.NumberPad8] = 0x48, [VirtualKey.NumberPad9] = 0x49,
            [VirtualKey.NumberPad4] = 0x4B, [VirtualKey.NumberPad5] = 0x4C, [VirtualKey.NumberPad6] = 0x4D,
            [VirtualKey.NumberPad1] = 0x4F, [VirtualKey.NumberPad2] = 0x50, [VirtualKey.NumberPad3] = 0x51, [VirtualKey.NumberPad0] = 0x52,
            // OEM-клавиши US-раскладки: ; = , - . / ` [ \ ] '
            [(VirtualKey)186] = 0x27, [(VirtualKey)187] = 0x0D, [(VirtualKey)188] = 0x33, [(VirtualKey)189] = 0x0C,
            [(VirtualKey)190] = 0x34, [(VirtualKey)191] = 0x35, [(VirtualKey)192] = 0x29, [(VirtualKey)219] = 0x1A,
            [(VirtualKey)220] = 0x2B, [(VirtualKey)221] = 0x1B, [(VirtualKey)222] = 0x28,
        };
        // Цифры 1…9, 0 — 0x02…0x0B; F1…F10 — 0x3B…0x44, F11 0x57, F12 0x58.
        for (var i = 1; i <= 9; i++) m[VirtualKey.Number0 + i] = (ushort)(0x01 + i);
        m[VirtualKey.Number0] = 0x0B;
        for (var i = 0; i < 10; i++) m[VirtualKey.F1 + i] = (ushort)(0x3B + i);
        m[VirtualKey.F11] = 0x57;
        m[VirtualKey.F12] = 0x58;
        // Буквы по рядам QWERTY.
        void Row(string keys, ushort first) { for (var i = 0; i < keys.Length; i++) m[(VirtualKey)keys[i]] = (ushort)(first + i); }
        Row("QWERTYUIOP", 0x10);
        Row("ASDFGHJKL", 0x1E);
        Row("ZXCVBNM", 0x2C);
        return m;
    }

    private void DrawFrame(SKCanvas sk, Size area)
    {
        sk.Clear(SKColors.Black);
        try
        {
            SKImage image;
            Rect at;
            lock (frameLock)
            {
                if (remoteW == 0 || remoteH == 0) return;
                image = SKImage.FromPixelCopy(new SKImageInfo(remoteW, remoteH, SKColorType.Bgra8888, SKAlphaType.Opaque), buffer);
                at = Layout(area.Width, area.Height);
            }
            using (image)
            using (var paint = new SKPaint { FilterQuality = SKFilterQuality.Medium })
                sk.DrawImage(image, new SKRect((float)at.X, (float)at.Y, (float)(at.X + at.Width), (float)(at.Y + at.Height)), paint);
        }
        catch (Exception e) { Terminal.TerminalView.Trace("RDP draw: " + e.Message); }
    }

    private sealed class Surface(RdpView view) : SKCanvasElement
    {
        protected override void RenderOverride(SKCanvas canvas, Size area) => view.DrawFrame(canvas, area);
    }
}
