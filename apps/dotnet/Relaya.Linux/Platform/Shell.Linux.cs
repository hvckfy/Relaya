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

    public static partial void Reveal(string path) => OpenFolder(Path.GetDirectoryName(path) ?? path);

    // gio trash (GLib) — Корзина freedesktop; ошибку видит пользователь.
    public static partial void Trash(string path)
    {
        var info = new ProcessStartInfo(Dialogs.Which("gio") ?? "gio") { UseShellExecute = false, RedirectStandardError = true };
        info.ArgumentList.Add("trash");
        info.ArgumentList.Add(path);
        using var p = Process.Start(info)!;
        p.WaitForExit(10000);
        if (p.ExitCode != 0) throw new IOException(p.StandardError.ReadToEnd().Trim());
    }
}
