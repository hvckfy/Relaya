namespace Relaya.Platform;

internal static partial class Accent
{
    // Акцент GNOME/KDE — следующим шагом; пока — акцент Uno по умолчанию.
    private static partial Windows.UI.Color? PlatformSystemAccent() => null;
}
