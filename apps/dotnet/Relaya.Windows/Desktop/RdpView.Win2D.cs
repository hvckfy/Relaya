using System;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml.Input;
using Windows.Graphics.DirectX;
using Windows.System;
using static Relaya.Strings;
using Rect = Windows.Foundation.Rect;

namespace Relaya.Desktop;

/// Холст удалённого стола на Windows: Win2D, scancode — из KeyStatus.
internal sealed partial class RdpView
{
    private CanvasControl win2d = null!;

    private partial void CreateCanvas()
    {
        win2d = new CanvasControl();
        win2d.Draw += OnDraw;
        canvas = win2d;
    }

    private partial void InvalidateCanvas() => win2d.Invalidate();

    private partial void RemoveCanvas() => win2d.RemoveFromVisualTree();

    private partial bool IsDown(VirtualKey key) =>
        InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

    private static partial ushort ScanCode(KeyRoutedEventArgs e)
    {
        var code = (ushort)e.KeyStatus.ScanCode;
        if (code != 0 && e.KeyStatus.IsExtendedKey) code |= 0xE000;
        return code;
    }

    private static partial string SavePasswordText() => L("Сохранить в диспетчере учётных данных");

    // Одна картинка на сессию (П8): при изменениях — SetPixelBytes только для изменённых прямоугольников,
    // пересоздание — при новом размере или когда изменилось почти всё.
    private CanvasBitmap? screen;

    private void OnDraw(CanvasControl sender, CanvasDrawEventArgs args)
    {
        var ds = args.DrawingSession;
        ds.Clear(Microsoft.UI.Colors.Black);
        try
        {
            Rect at;
            lock (frameLock)
            {
                if (remoteW == 0 || remoteH == 0) return;
                if (fullDirty || screen == null || screen.SizeInPixels.Width != remoteW || screen.SizeInPixels.Height != remoteH)
                {
                    screen?.Dispose();
                    screen = CanvasBitmap.CreateFromBytes(sender, buffer, remoteW, remoteH,
                        DirectXPixelFormat.B8G8R8A8UIntNormalized, 96, CanvasAlphaMode.Ignore);
                    fullDirty = false;
                }
                else
                {
                    foreach (var (x, y, w, h) in dirty)
                    {
                        var part = new byte[w * h * 4];
                        for (var row = 0; row < h; row++)
                            Buffer.BlockCopy(buffer, ((y + row) * remoteW + x) * 4, part, row * w * 4, w * 4);
                        screen.SetPixelBytes(part, x, y, w, h);
                    }
                }
                dirty.Clear();
                at = Layout(sender.ActualWidth, sender.ActualHeight);
            }
            ds.DrawImage(screen, at, new Rect(0, 0, screen.SizeInPixels.Width, screen.SizeInPixels.Height));
        }
        catch (Exception e)
        {
            Terminal.TerminalView.Trace("RDP draw: " + e.Message);
            lock (frameLock) fullDirty = true; // устройство потеряно и т. п. — в следующем кадре картинка заново
        }
    }
}
