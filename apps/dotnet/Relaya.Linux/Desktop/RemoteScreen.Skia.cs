using System;
using SkiaSharp;
using Uno.WinUI.Graphics2DSK;
using Windows.Foundation;

namespace Relaya.Desktop;

/// Холст удалённого экрана на Linux: SkiaSharp (SKCanvasElement). Своя копия экрана (retained) обновляется
/// только по грязным прямоугольникам (Я-1), а не копией всего буфера на каждый кадр.
internal sealed partial class RemoteScreen
{
    private SkiaSurface surface = null!;
    private SKBitmap? retained; // только в потоке отрисовки

    private partial void CreateCanvas()
    {
        surface = new SkiaSurface(this);
        canvas = surface;
    }

    private partial void InvalidateCanvas() => surface.Invalidate();

    private void DrawFrame(SKCanvas sk, Size area)
    {
        sk.Clear(SKColors.Black);
        try
        {
            Rect at;
            lock (frameLock)
            {
                if (remoteW == 0 || remoteH == 0) return;
                if (retained == null || retained.Width != remoteW || retained.Height != remoteH)
                {
                    retained?.Dispose();
                    retained = new SKBitmap(new SKImageInfo(remoteW, remoteH, SKColorType.Bgra8888, SKAlphaType.Opaque));
                    fullDirty = true;
                }
                CopyDirty(retained);
                dirty.Clear();
                fullDirty = false;
                at = Layout(area.Width, area.Height);
            }
            using var paint = new SKPaint { FilterQuality = SKFilterQuality.Medium };
            sk.DrawBitmap(retained, new SKRect((float)at.X, (float)at.Y, (float)(at.X + at.Width), (float)(at.Y + at.Height)), paint);
        }
        catch (Exception e) { Terminal.TerminalView.Trace("remote screen draw: " + e.Message); }
    }

    // Под frameLock: в копию переносятся только изменившиеся строки прямоугольников; границы — от сервера, проверяются.
    private void CopyDirty(SKBitmap target)
    {
        var pixels = target.GetPixels();
        var rowBytes = target.RowBytes;
        var stride = remoteW * 4;
        if (fullDirty || rowBytes != stride)
        {
            for (var row = 0; row < remoteH; row++)
                System.Runtime.InteropServices.Marshal.Copy(buffer, row * stride, pixels + row * rowBytes, stride);
        }
        else
        {
            foreach (var (x, y, w, h) in dirty)
            {
                int x0 = Math.Clamp(x, 0, remoteW), y0 = Math.Clamp(y, 0, remoteH);
                int x1 = Math.Clamp(x + w, x0, remoteW), y1 = Math.Clamp(y + h, y0, remoteH);
                for (var row = y0; row < y1; row++)
                    System.Runtime.InteropServices.Marshal.Copy(buffer, row * stride + x0 * 4, pixels + row * rowBytes + x0 * 4, (x1 - x0) * 4);
            }
        }
        target.NotifyPixelsChanged();
    }

    private sealed class SkiaSurface(RemoteScreen view) : SKCanvasElement
    {
        protected override void RenderOverride(SKCanvas canvas, Size area) => view.DrawFrame(canvas, area);
    }
}
