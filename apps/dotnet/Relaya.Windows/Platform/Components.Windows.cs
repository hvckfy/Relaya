using System.Collections.Generic;

namespace Relaya.Platform;

// На Windows OpenSSH, Git и всё остальное ставит установщик (Relaya.iss) — страницы «Компоненты» нет.
internal static partial class Components
{
    public static partial List<Item> List() => new();
}
