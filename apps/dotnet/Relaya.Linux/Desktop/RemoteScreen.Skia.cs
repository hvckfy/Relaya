using System;
using SkiaSharp;
using Uno.WinUI.Graphics2DSK;
using Windows.Foundation;

namespace Relaya.Desktop;

/// Холст удалённого экрана на Linux: SkiaSharp (SKCanvasElement); картинка — из буфера целиком на кадр.
internal sealed partial class RemoteScreen
{
    private SkiaSurface surface = null!;

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
            SKImage image;
            Rect at;
            lock (frameLock)
            {
                if (remoteW == 0 || remoteH == 0) return;
                image = SKImage.FromPixelCopy(new SKImageInfo(remoteW, remoteH, SKColorType.Bgra8888, SKAlphaType.Opaque), buffer);
                dirty.Clear();
                fullDirty = false;
                at = Layout(area.Width, area.Height);
            }
            using (image)
            using (var paint = new SKPaint { FilterQuality = SKFilterQuality.Medium })
                sk.DrawImage(image, new SKRect((float)at.X, (float)at.Y, (float)(at.X + at.Width), (float)(at.Y + at.Height)), paint);
        }
        catch (Exception e) { Terminal.TerminalView.Trace("remote screen draw: " + e.Message); }
    }

    private sealed class SkiaSurface(RemoteScreen view) : SKCanvasElement
    {
        protected override void RenderOverride(SKCanvas canvas, Size area) => view.DrawFrame(canvas, area);
    }
}
