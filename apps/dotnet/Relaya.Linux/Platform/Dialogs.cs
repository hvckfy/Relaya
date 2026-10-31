using System;
using System.Diagnostics;
using System.IO;

namespace Relaya.Platform;

/// Системный вопрос Да/Нет без XAML (процесс --mcp, поток askpass): zenity (GNOME), иначе kdialog (KDE).
/// «Нет» по умолчанию: Enter и Esc не одобряют. Нет ни одного из них или окно закрыли — ответ «нет».
internal static class Dialogs
{
    public static bool YesNo(string text, bool warning = false)
    {
        if (Which("zenity") is { } zenity)
            return Run(zenity, "--question", "--default-cancel", "--no-markup", "--title=Relaya",
                warning ? "--icon=dialog-warning" : "--icon=dialog-question", "--text=" + text).Code == 0;
        // У kdialog --yesno по умолчанию «Да» (M-MCP-4). Выбор из двух пунктов с отмеченным «Нет»:
        // Enter возвращает «no», Esc и закрытие — код 1; одобрение — только явный выбор «Да».
        if (Which("kdialog") is { } kdialog)
        {
            var r = Run(kdialog, "--title", "Relaya", "--radiolist", Escape(text),
                "no", Strings.L("Нет"), "on", "yes", Strings.L("Да"), "off");
            return r.Code == 0 && r.Output.Trim() == "yes";
        }
        return false;
    }

    // kdialog показывает текст как rich text: команда агента не должна стать разметкой.
    private static string Escape(string text) =>
        text.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;");

    private static (int Code, string Output) Run(string exe, params string[] args)
    {
        try
        {
            var info = new ProcessStartInfo(exe) { UseShellExecute = false, RedirectStandardOutput = true };
            foreach (var a in args) info.ArgumentList.Add(a);
            using var p = Process.Start(info)!;
            var output = p.StandardOutput.ReadToEnd();
            p.WaitForExit();
            return (p.ExitCode, output);
        }
        catch (Exception) { return (-1, ""); }
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
