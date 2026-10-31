using System;
using System.Runtime.InteropServices;

namespace Relaya.Platform;

/// Системный вопрос Да/Нет без XAML (процесс --mcp, поток askpass): MessageBox поверх всех окон, «Нет» по умолчанию.
internal static class Dialogs
{
    public static bool YesNo(string text, bool warning = false)
    {
        var flags = 0x4u /* YESNO */ | (warning ? 0x30u /* ICONWARNING */ : 0x20u /* ICONQUESTION */)
            | 0x100 /* DEFBUTTON2 */ | 0x40000 /* TOPMOST */ | 0x10000 /* SETFOREGROUND */;
        if (MessageBoxW(IntPtr.Zero, text, "Relaya", flags) != 6) return false;
        // Предупреждение — это команда агента (M-MCP-5): после «Да» ещё и Windows Hello, как Touch ID на Mac.
        // Текст команды человек уже прочитал в окне выше; Hello подтверждает, что ответил он сам.
        return !warning || Consent.Verify(Strings.L("Подтвердите выполнение команды агента"));
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);
}
