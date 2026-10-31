using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text.RegularExpressions;

namespace Relaya;

/// Перевод интерфейса: ключи — русские строки (как на Mac), английский — из общего en.lproj/Localizable.strings.
/// Язык — по языку Windows: русский для ru, иначе английский. `%@` — подстановки по порядку.
internal static class Strings
{
    private static readonly Dictionary<string, string>? English = Load();

    private static Dictionary<string, string>? Load()
    {
        if (CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "ru") return null;
        var file = Path.Combine(AppContext.BaseDirectory, "Localization", "en.strings");
        if (!File.Exists(file)) return null;
        var map = new Dictionary<string, string>();
        var re = new Regex(@"^""((?:[^""\\]|\\.)*)""\s*=\s*""((?:[^""\\]|\\.)*)"";");
        foreach (var line in File.ReadAllLines(file))
        {
            var m = re.Match(line);
            if (m.Success) map[Unescape(m.Groups[1].Value)] = Unescape(m.Groups[2].Value);
        }
        return map;
    }

    private static string Unescape(string s) => s.Replace("\\\"", "\"").Replace("\\n", "\n").Replace("\\\\", "\\");

    public static string L(string key, params object[] args)
    {
        var text = English != null && English.TryGetValue(key, out var t) ? t : key;
        foreach (var a in args)
        {
            var i = text.IndexOf("%@", StringComparison.Ordinal);
            if (i < 0) break;
            text = text[..i] + a + text[(i + 2)..];
        }
        return text;
    }
}
