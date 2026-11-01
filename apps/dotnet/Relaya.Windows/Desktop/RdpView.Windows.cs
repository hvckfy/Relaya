using Microsoft.UI.Input;
using Microsoft.UI.Xaml.Input;
using Windows.System;
using static Relaya.Strings;

namespace Relaya.Desktop;

/// Удалённый стол на Windows: модификаторы из InputKeyboardSource, scancode — из KeyStatus. Экран — RemoteScreen.Win2D.
internal sealed partial class RdpView
{
    private partial void InitInput() { }

    private partial bool IsDown(VirtualKey key) =>
        InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

    private static partial ushort ScanCode(KeyRoutedEventArgs e)
    {
        var code = (ushort)e.KeyStatus.ScanCode;
        if (code != 0 && e.KeyStatus.IsExtendedKey) code |= 0xE000;
        return code;
    }

    private static partial string SavePasswordText() => L("Сохранить в диспетчере учётных данных");
}
