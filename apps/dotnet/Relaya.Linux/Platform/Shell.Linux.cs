using System.Diagnostics;
using System.IO;

namespace Relaya.Platform;

/// Папка открывается в файловом менеджере по умолчанию через xdg-open (freedesktop), без оболочки.
internal static partial class Shell
{
    public static partial void OpenFolder(string path)
    {
        Directory.CreateDirectory(path);
        var info = new ProcessStartInfo(Dialogs.Which("xdg-open") ?? "xdg-open") { UseShellExecute = false };
        info.ArgumentList.Add(path);
        // Из обработчика кнопки: без файлового менеджера — запись в трассировку, а не падение.
        try { Process.Start(info); }
        catch (System.Exception e) { Trace.WriteLine($"Shell.OpenFolder: {e.Message}"); }
    }
}
