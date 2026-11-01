using System;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Windows.Graphics.DirectX;
using Rect = Windows.Foundation.Rect;

namespace Relaya.Desktop;

/// Холст удалённого экрана на Windows: Win2D, одна картинка на сессию, обновляются только изменённые прямоугольники (П8).
internal sealed partial class RemoteScreen
{
    private CanvasControl win2d = null!;
    private CanvasBitmap? screen;

    private partial void CreateCanvas()
    {
        win2d = new CanvasControl();
        win2d.Draw += OnDraw;
        canvas = win2d;
        Unloaded += (_, _) => { screen?.Dispose(); screen = null; };
    }

    private partial void InvalidateCanvas() => win2d.Invalidate();

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
            Terminal.TerminalView.Trace("remote screen draw: " + e.Message);
            lock (frameLock) fullDirty = true;
        }
    }
}
