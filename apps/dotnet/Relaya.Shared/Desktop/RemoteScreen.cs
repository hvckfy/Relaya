using System;
using System.Collections.Generic;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using uniffi.relaya_core;
using Point = Windows.Foundation.Point;
using Rect = Windows.Foundation.Rect;

namespace Relaya.Desktop;

/// Экран удалённого стола: буфер BGRA, изменённые прямоугольники (П8), «вписать» или 1:1, пересчёт точки в координаты
/// сервера. Кадры приходят из потока сессии ядра; холст — в приложении: RemoteScreen.Win2D.cs и RemoteScreen.Skia.cs.
/// Используется VncView; RdpView пока со своим холстом того же устройства.
internal sealed partial class RemoteScreen : UserControl
{
    private readonly DispatcherQueue ui = DispatcherQueue.GetForCurrentThread();
    private readonly object frameLock = new();
    private byte[] buffer = Array.Empty<byte>();
    private int remoteW, remoteH;
    private readonly List<(int X, int Y, int W, int H)> dirty = new();
    private bool fullDirty = true;
    private Rect target;
    private bool fit = true;
    private FrameworkElement canvas = null!;

    private partial void CreateCanvas();
    private partial void InvalidateCanvas();

    public RemoteScreen()
    {
        CreateCanvas();
        Content = canvas;
        // Скрытая вкладка не рисует; при показе — одна перерисовка из буфера.
        RegisterPropertyChangedCallback(VisibilityProperty, (_, _) => { if (Visibility == Visibility.Visible) InvalidateCanvas(); });
    }

    /// Холст для событий мыши.
    public FrameworkElement Surface => canvas;

    public bool Fit
    {
        get => fit;
        set { fit = value; InvalidateCanvas(); }
    }

    public (int Width, int Height) Size { get { lock (frameLock) return (remoteW, remoteH); } }

    /// Новый размер экрана сервера (из потока сессии).
    public void Reset(ushort w, ushort h)
    {
        lock (frameLock) { remoteW = w; remoteH = h; buffer = new byte[w * h * 4]; dirty.Clear(); fullDirty = true; }
        ui.TryEnqueue(InvalidateCanvas);
    }

    /// Изменённые прямоугольники (из потока сессии).
    public void Update(List<FrameRect> rects)
    {
        lock (frameLock)
        {
            foreach (var r in rects)
            {
                if (r.x + r.width > remoteW || r.y + r.height > remoteH) continue;
                var row = r.width * 4;
                for (var y = 0; y < r.height; y++)
                    Buffer.BlockCopy(r.bgra, y * row, buffer, ((r.y + y) * remoteW + r.x) * 4, row);
                if (!fullDirty) dirty.Add((r.x, r.y, r.width, r.height));
            }
            if (dirty.Count > 64) { dirty.Clear(); fullDirty = true; }
        }
        ui.TryEnqueue(() => { if (Visibility == Visibility.Visible) InvalidateCanvas(); });
    }

    /// Точка на холсте → пиксель сервера; вне картинки — null.
    public (ushort X, ushort Y)? ToRemote(Point p)
    {
        if (target.Width <= 0 || remoteW == 0) return null;
        var x = (p.X - target.X) * remoteW / target.Width;
        var y = (p.Y - target.Y) * remoteH / target.Height;
        if (x < 0 || y < 0 || x >= remoteW || y >= remoteH) return null;
        return ((ushort)x, (ushort)y);
    }

    // Под frameLock: где рисовать (вписать или 1:1 в физических пикселях).
    private Rect Layout(double cw, double ch)
    {
        var scale = XamlRoot?.RasterizationScale ?? 1.0;
        double k = fit ? Math.Min(cw / remoteW, ch / remoteH) : 1.0 / scale;
        double w = remoteW * k, h = remoteH * k;
        target = new Rect(Math.Max(0, (cw - w) / 2), Math.Max(0, (ch - h) / 2), w, h);
        return target;
    }
}
