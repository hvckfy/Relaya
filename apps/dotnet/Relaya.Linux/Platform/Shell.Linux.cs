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

    public static partial void OpenFile(string path)
    {
        NotExecutable(path);
        var info = new ProcessStartInfo(Dialogs.Which("xdg-open") ?? "xdg-open") { UseShellExecute = false };
        info.ArgumentList.Add(path);
        try { Process.Start(info); }
        catch (System.Exception e) { throw new IOException(e.Message, e); }
    }

    // Редактор text/plain по умолчанию (xdg-mime) через gtk-launch: файл открывается как текст, даже .desktop или .sh.
    public static partial void OpenAsText(string path)
    {
        NotExecutable(path);
        var query = new ProcessStartInfo(Dialogs.Which("xdg-mime") ?? "xdg-mime") { UseShellExecute = false, RedirectStandardOutput = true };
        foreach (var a in new[] { "query", "default", "text/plain" }) query.ArgumentList.Add(a);
        string app;
        try
        {
            using var q = Process.Start(query)!;
            app = q.StandardOutput.ReadToEnd().Trim();
            q.WaitForExit(5000);
        }
        catch (System.Exception e) { throw new IOException(e.Message, e); }
        if (app.Length == 0 || Dialogs.Which("gtk-launch") is not { } launch)
            throw new IOException(Relaya.Strings.L("Нет текстового редактора по умолчанию (xdg-mime text/plain, gtk-launch)."));
        var info = new ProcessStartInfo(launch) { UseShellExecute = false };
        info.ArgumentList.Add(app);
        info.ArgumentList.Add(path);
        try { Process.Start(info); }
        catch (System.Exception e) { throw new IOException(e.Message, e); }
    }

    // Скачанный файл не исполняется ни запуском, ни двойным щелчком: только чтение и запись владельцу.
    private static void NotExecutable(string path) => File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);

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
