using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Relaya.Data;

/// Сохранённые раскладки плиток — layouts.json в папке данных, формат общий с Mac и Linux:
/// [{ "id": "<UUID>", "name": "…", "layout": <дерево ядра {"leaf"}/{"row"}/{"column"}, лист — алиас хоста> }].
internal static class SavedLayouts
{
    public sealed record Saved(string Id, string Name, string Layout);

    private static string File_ => Path.Combine(AppState.Support, "layouts.json");

    public static List<Saved> All()
    {
        try
        {
            if (!File.Exists(File_)) return new();
            var list = new List<Saved>();
            foreach (var n in JsonNode.Parse(File.ReadAllText(File_))!.AsArray())
                if (n?["id"]?.GetValue<string>() is { } id && n["name"]?.GetValue<string>() is { } name && n["layout"] is { } layout)
                    list.Add(new Saved(id, name, layout.ToJsonString()));
            return list;
        }
        catch (Exception) { return new(); }
    }

    public static void Save(List<Saved> list)
    {
        var array = new JsonArray();
        foreach (var s in list)
            array.Add(new JsonObject { ["id"] = s.Id, ["name"] = s.Name, ["layout"] = JsonNode.Parse(s.Layout) });
        Platform.AtomicFile.Write(File_, array.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
    }

    public static void Add(string name, string layout) =>
        Save(All().Append(new Saved(Guid.NewGuid().ToString().ToUpperInvariant(), name, layout)).ToList());

    public static void Rename(string id, string name) => Save(All().Select(s => s.Id == id ? s with { Name = name } : s).ToList());

    public static void Remove(string id) => Save(All().Where(s => s.Id != id).ToList());

    /// Замена листьев дерева: map(лист) → новый лист или null (лист выбрасывается, пустые ветви — тоже).
    public static JsonNode? MapLeaves(JsonNode? node, Func<string, string?> map)
    {
        if (node is not JsonObject o || o.Count != 1) return null;
        var (kind, value) = o.First();
        if (kind == "leaf") return value?.GetValue<string>() is { } leaf && map(leaf) is { } m ? new JsonObject { ["leaf"] = m } : null;
        var children = new JsonArray();
        foreach (var c in value!.AsArray()) if (MapLeaves(c, map) is { } mc) children.Add(mc);
        return children.Count switch { 0 => null, 1 => children[0]!.DeepClone(), _ => new JsonObject { [kind] = children } };
    }
}
