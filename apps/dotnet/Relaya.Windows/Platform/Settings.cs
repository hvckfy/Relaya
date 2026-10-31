using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;

namespace Relaya.Platform;

/// Мелкие настройки приложения (тема терминала, шрифт, свёрнутые группы): %APPDATA%\Relaya\settings.json.
internal static class Settings
{
    private static readonly string File_ = Path.Combine(Data.AppState.Support, "settings.json");
    private static readonly Dictionary<string, string> Values = Load();

    public static event Action? Changed;

    private static Dictionary<string, string> Load()
    {
        try { return JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(File_)) ?? new(); }
        catch (Exception) { return new(); }
    }

    public static string Get(string key, string fallback) => Values.TryGetValue(key, out var v) ? v : fallback;

    public static void Set(string key, string value)
    {
        if (Values.TryGetValue(key, out var old) && old == value) return;
        Values[key] = value;
        Directory.CreateDirectory(Data.AppState.Support);
        File.WriteAllText(File_, JsonSerializer.Serialize(Values));
        Changed?.Invoke();
    }
}
