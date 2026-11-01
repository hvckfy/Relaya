namespace Relaya.Platform;

/// Приглашение ssh ввести пароль сервера в конце вывода — как PasswordPrompt на Mac.
internal static class PasswordPrompt
{
    /// Любой запрос пароля (su, sudo, mysql -p…), а не только ssh: «Password:», «[sudo] password for x:», «Пароль:».
    public static bool IsAnyPasswordPrompt(string tail)
    {
        var t = tail.Split('\n')[^1].Trim().ToLowerInvariant();
        return t.EndsWith(':') && (t.Contains("password") || t.Contains("пароль")) && !t.Contains("passphrase") && !t.Contains("new");
    }

    /// Последняя непустая строка похожа на запрос секрета (пауза рассылки ввода, L-SEC-1). Правило и тесты — в ядре
    /// (terminal_secret_prompt), одно на Mac, Windows и Linux: пароль, passphrase, PIN, токен, коды, многие языки.
    public static bool IsSecretPrompt(string tail) => uniffi.relaya_core.RelayaCoreMethods.TerminalSecretPrompt(tail);

    public static bool Matches(string tail)
    {
        var lines = tail.Split('\n');
        var t = lines[^1].Trim().ToLowerInvariant();
        if (!t.EndsWith("password:")) return false;
        return !t.Contains("sudo") && !t.Contains("passphrase") && !t.Contains("new password") && !t.Contains("current password");
    }
}
