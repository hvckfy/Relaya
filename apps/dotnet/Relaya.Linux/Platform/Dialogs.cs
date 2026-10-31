using System;
using System.Diagnostics;
using System.IO;

namespace Relaya.Platform;

/// Системный вопрос Да/Нет без XAML (процесс --mcp, поток askpass): zenity (GNOME), иначе kdialog (KDE).
/// «Нет» по умолчанию; нет ни одного из них или окно закрыли — ответ «нет».
internal static class Dialogs
{
    public static bool YesNo(string text, bool warning = false)
    {
        if (Which("zenity") is { } zenity)
            return Ask(zenity, "--question", "--default-cancel", "--no-markup", "--title=Relaya",
                warning ? "--icon=dialog-warning" : "--icon=dialog-question", "--text=" + text);
        if (Which("kdialog") is { } kdialog)
            return Ask(kdialog, "--title", "Relaya", warning ? "--warningyesno" : "--yesno", text);
        return false;
    }

    private static bool Ask(string exe, params string[] args)
    {
        try
        {
            var info = new ProcessStartInfo(exe) { UseShellExecute = false };
            foreach (var a in args) info.ArgumentList.Add(a);
            using var p = Process.Start(info)!;
            p.WaitForExit();
            return p.ExitCode == 0;
        }
        catch (Exception) { return false; }
    }

    /// Полный путь программы из PATH.
    public static string? Which(string name)
    {
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "/usr/bin:/bin").Split(':'))
        {
            if (dir.Length == 0) continue;
            var path = Path.Combine(dir, name);
            if (File.Exists(path)) return path;
        }
        return null;
    }
}
