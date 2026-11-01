using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;
using static Relaya.Strings;

namespace Relaya.Terminal;

/// Правила подсветки вывода (4.8, как HighlightRule на Mac): текст или регулярка, регистр, цвет ANSI 0–15, жирный.
/// Хранятся в terminal.highlightRules (JSON); пусто — правила по умолчанию.
internal sealed record HighlightRule(string Name, string Pattern, bool IsRegex, bool CaseSensitive, int Color, bool Bold, bool Enabled);

internal static class HighlightRules
{
    public const string Key = "terminal.highlightRules";

    public static List<HighlightRule> Defaults() => new()
    {
        new(L("Ошибки"), @"\b(error|errors|failed|failure|fatal|panic|denied|refused|critical|exception)\b", true, false, 9, true, true),
        new(L("Предупреждения"), @"\b(warn|warning|warnings|deprecated)\b", true, false, 11, false, true),
        new(L("Успех"), @"\b(ok|success|successful|succeeded|done|passed|active \(running\))\b", true, false, 10, false, true),
        new(L("IP-адреса"), @"\b(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,2})?\b", true, false, 14, false, true),
        new("URL", @"\bhttps?://[^\s'""<>]+", true, false, 12, false, true),
        new(L("Даты и время"), @"\b\d{4}-\d{2}-\d{2}(?:[ T]\d{2}:\d{2}(?::\d{2})?)?\b", true, false, 13, false, false),
    };

    public static List<HighlightRule> Load()
    {
        var json = Platform.Settings.Get(Key, "");
        if (json.Length == 0) return Defaults();
        try { return JsonSerializer.Deserialize<List<HighlightRule>>(json) ?? Defaults(); }
        catch (JsonException) { return Defaults(); }
    }

    public static void Save(List<HighlightRule> rules) => Platform.Settings.Set(Key, JsonSerializer.Serialize(rules));

    public static void Reset() => Platform.Settings.Set(Key, "");

    /// Скомпилированные включённые правила; битая регулярка пропускается.
    public static List<(Regex Pattern, int Color, bool Bold)> Compile(IEnumerable<HighlightRule> rules)
    {
        var list = new List<(Regex, int, bool)>();
        foreach (var r in rules.Where(r => r.Enabled && r.Pattern.Length > 0))
        {
            var source = r.IsRegex ? r.Pattern : Regex.Escape(r.Pattern);
            try { list.Add((new Regex(source, r.CaseSensitive ? RegexOptions.None : RegexOptions.IgnoreCase, TimeSpan.FromMilliseconds(50)), r.Color, r.Bold)); }
            catch (ArgumentException) { }
        }
        return list;
    }

    public static readonly string[] ColorNames =
    {
        "Чёрный", "Красный", "Зелёный", "Жёлтый", "Синий", "Пурпурный", "Голубой", "Белый",
        "Ярко-чёрный", "Ярко-красный", "Ярко-зелёный", "Ярко-жёлтый", "Ярко-синий", "Ярко-пурпурный", "Ярко-голубой", "Ярко-белый",
    };
}
