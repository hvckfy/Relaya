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

    public static bool Matches(string tail)
    {
        var lines = tail.Split('\n');
        var t = lines[^1].Trim().ToLowerInvariant();
        if (!t.EndsWith("password:")) return false;
        return !t.Contains("sudo") && !t.Contains("passphrase") && !t.Contains("new password") && !t.Contains("current password");
    }
}
