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

    // Слова секретных запросов на разных языках и для 2FA: пароль, passphrase, PIN, токен, одноразовый код.
    private static readonly string[] SecretWords =
    {
        "password", "passphrase", "passcode", "pin", "token", "secret", "otp", "one-time", "verification code", "authenticator",
        "пароль", "парольн", "пин-код", "код подтверждения", "одноразов", "токен",
        "passwort", "kennwort", "contraseña", "mot de passe", "senha", "parola", "hasło", "heslo", "wachtwoord", "lösenord",
        "密码", "口令", "パスワード", "암호", "비밀번호",
    };

    /// Последняя строка похожа на запрос секрета (для паузы рассылки ввода, L-SEC-1): широкое правило, лучше лишняя пауза,
    /// чем пароль во всех терминалах. Не требует «:» в конце — бывают «Password for x?», «Enter PIN >».
    public static bool IsSecretPrompt(string tail)
    {
        var t = tail.Split('\n')[^1].Trim().ToLowerInvariant();
        if (t.Length == 0 || t.Length > 200) return false;
        foreach (var w in SecretWords)
        {
            var i = t.IndexOf(w, System.StringComparison.Ordinal);
            // «pin»/«otp» — только отдельным словом, иначе «spinning», «shopping» ставили бы паузу.
            if (i >= 0 && (w.Length > 3 || ((i == 0 || !char.IsLetter(t[i - 1])) && (i + w.Length == t.Length || !char.IsLetter(t[i + w.Length])))))
                return true;
        }
        return false;
    }

    public static bool Matches(string tail)
    {
        var lines = tail.Split('\n');
        var t = lines[^1].Trim().ToLowerInvariant();
        if (!t.EndsWith("password:")) return false;
        return !t.Contains("sudo") && !t.Contains("passphrase") && !t.Contains("new password") && !t.Contains("current password");
    }
}
