using System.Collections.Generic;

namespace Relaya.Platform;

/// Внешние программы и службы, от которых зависят функции Relaya (Л5): найдено или нет, зачем нужна, чем поставить.
/// Список — у приложения: Relaya.Linux/Platform/Components.Linux.cs; на Windows всё входит в установщик, список пуст.
internal static partial class Components
{
    /// Required — без компонента не работает главное (ssh, хранение паролей); остальное — отдельные функции.
    public sealed record Item(string Name, string Purpose, bool Found, bool Required, string? Install);

    public static partial List<Item> List();
}
