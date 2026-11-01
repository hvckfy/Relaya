namespace Relaya.Platform;

internal static partial class Accent
{
    // Windows: WinUI сам берёт акцент системы и следит за его сменой — переопределять нечего.
    private static partial Windows.UI.Color? PlatformSystemAccent() => null;
}
