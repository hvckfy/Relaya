using System;
using System.Runtime.InteropServices;
using Windows.Security.Credentials.UI;

namespace Relaya.Platform;

/// Подтверждение человеком: Windows Hello (лицо, отпечаток, PIN), а без него — системный диалог Да/Нет с «Нет» по умолчанию.
/// Вызывается не из UI-потока (сервер askpass), поэтому ждёт синхронно.
internal static class Consent
{
    public static bool Ask(string text)
    {
        try
        {
            if (UserConsentVerifier.CheckAvailabilityAsync().AsTask().GetAwaiter().GetResult() == UserConsentVerifierAvailability.Available)
            {
                // Окно-владелец: главное окно Relaya, в --mcp его нет — окно на переднем плане.
                var hwnd = MainWindow.Hwnd != IntPtr.Zero ? MainWindow.Hwnd : GetForegroundWindow();
                var result = UserConsentVerifierInterop.RequestVerificationForWindowAsync(hwnd, text).AsTask().GetAwaiter().GetResult();
                return result == UserConsentVerificationResult.Verified;
            }
        }
        catch (Exception) { /* Hello недоступен или отказал в запуске — системный диалог */ }
        const uint flags = 0x4 /* YESNO */ | 0x20 /* ICONQUESTION */ | 0x100 /* DEFBUTTON2 */ | 0x40000 /* TOPMOST */ | 0x10000 /* SETFOREGROUND */;
        return MessageBoxW(IntPtr.Zero, text, "Relaya", flags) == 6;
    }

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);
}
