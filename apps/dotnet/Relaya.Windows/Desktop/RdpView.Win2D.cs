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

    private void OnDraw(CanvasControl sender, CanvasDrawEventArgs args)
    {
        var ds = args.DrawingSession;
        ds.Clear(Microsoft.UI.Colors.Black);
        CanvasBitmap? bitmap = null;
        try
        {
            Rect at;
            lock (frameLock)
            {
                if (remoteW == 0 || remoteH == 0) return;
                bitmap = CanvasBitmap.CreateFromBytes(sender, buffer, remoteW, remoteH,
                    DirectXPixelFormat.B8G8R8A8UIntNormalized, 96, CanvasAlphaMode.Ignore);
                at = Layout(sender.ActualWidth, sender.ActualHeight);
            }
            ds.DrawImage(bitmap, at, new Rect(0, 0, bitmap.SizeInPixels.Width, bitmap.SizeInPixels.Height));
        }
        catch (Exception e) { Terminal.TerminalView.Trace("RDP draw: " + e.Message); }
        finally { bitmap?.Dispose(); }
    }
}
