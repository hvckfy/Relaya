using System.Diagnostics;

namespace Relaya.Platform;

internal static partial class Shell
{
    public static partial void OpenFolder(string path)
    {
        var info = new ProcessStartInfo("explorer.exe") { UseShellExecute = false };
        info.ArgumentList.Add(path);
        // Из обработчика кнопки: без файлового менеджера — запись в трассировку, а не падение.
        try { Process.Start(info); }
        catch (System.Exception e) { Trace.WriteLine($"Shell.OpenFolder: {e.Message}"); }
    }
}
