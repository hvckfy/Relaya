using System;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace Relaya.Platform;

/// Контрастные темы Windows («Пустыня», «Сумерки», «Водная», «Ночное небо»): интерфейс берёт их из ресурсов темы
/// сам, а свои цвета (терминал, цвета хостов, подсветка) в этом режиме уступают системным. На Uno (Linux) контрастного
/// режима нет — On всегда false.
internal static class Contrast
{
    private static readonly AccessibilitySettings? accessibility = Create();

    public static event Action? Changed;

    public static bool On => accessibility?.HighContrast == true;

    /// Системный цвет контрастной темы (окно, текст, выделение); null — не удалось прочитать.
    public static Color? SystemColor(UIElementType element)
    {
        try { return new UISettings().UIElementColor(element); }
        catch (Exception e) when (e is NotImplementedException or NotSupportedException or InvalidOperationException or global::System.Runtime.InteropServices.COMException)
        {
            Terminal.TerminalView.Trace("contrast color: " + e.Message);
            return null;
        }
    }

    private static AccessibilitySettings? Create()
    {
        try
        {
            var a = new AccessibilitySettings();
            a.HighContrastChanged += (_, _) => Changed?.Invoke();
            return a;
        }
        catch (Exception e) when (e is NotImplementedException or NotSupportedException or InvalidOperationException or global::System.Runtime.InteropServices.COMException)
        {
            Terminal.TerminalView.Trace("contrast: " + e.Message);
            return null;
        }
    }
}
