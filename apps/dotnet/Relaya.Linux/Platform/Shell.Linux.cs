using System;
using System.Diagnostics;
using System.IO;

using static Relaya.Strings;

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
        using var p = Process.Start(info) ?? throw new IOException(L("Не удалось запустить gio trash."));
        // stderr — до ожидания, чтобы полный буфер не держал процесс; не ответил за 10 с — понятная ошибка, а не ExitCode живого процесса.
        var error = p.StandardError.ReadToEndAsync();
        if (!p.WaitForExit(10000))
        {
            try { p.Kill(); } catch (InvalidOperationException) { } // уже завершился
            throw new IOException(L("gio trash не ответил за 10 секунд."));
        }
        if (p.ExitCode != 0) throw new IOException(error.Result.Trim());
    }
}
