using Microsoft.UI.Xaml.Controls;
using uniffi.relaya_core;

namespace Relaya.Pages;

/// Иконка хоста по ОС: Segoe Fluent Icons (логотипов дистрибутивов в системе нет, на Mac — Simple Icons).
internal static class OsIcon
{
    public static IconElement For(ServerOs? os) => new FontIcon { Glyph = Glyph(os) };

    public static string Glyph(ServerOs? os) => os switch
    {
        null => "",
        ServerOs.Windows => "",
        ServerOs.Macos => "",
        ServerOs.Openwrt => "",
        _ => "",
    };
}
