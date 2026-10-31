using System;
using uniffi.relaya_core;

namespace Relaya.Platform;

/// Понятный текст ошибки ssh/sftp/git, как на Mac: ядро узнаёт ошибку, перевод — здесь.
internal static class SshErrors
{
    public static string Describe(string output, string? fallback = null)
    {
        if (RelayaCoreMethods.SshExplain(output) is { } p)
            return Strings.L(p.title) + ". " + Strings.L(p.hint) + "\n" + p.detail;
        var line = RelayaCoreMethods.SshErrorLine(output);
        return line.Length > 0 ? line : fallback ?? output;
    }
}
