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

    public static partial void Reveal(string path)
    {
        var info = new ProcessStartInfo("explorer.exe") { UseShellExecute = false };
        info.ArgumentList.Add("/select," + path);
        try { Process.Start(info); }
        catch (System.Exception e) { Trace.WriteLine($"Shell.Reveal: {e.Message}"); }
    }

    public static partial void Trash(string path) =>
        Microsoft.VisualBasic.FileIO.FileSystem.DeleteFile(path,
            Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs, Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin);
}
