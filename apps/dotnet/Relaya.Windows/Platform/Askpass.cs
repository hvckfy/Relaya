using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;

namespace Relaya.Platform;

/// Askpass: секрет из Credential Manager печатается только в ответ на ожидаемый запрос
/// (пароль сервера или passphrase ключа), иначе — отказ. Так фоновые ssh (туннели, SFTP, панели) входят по паролю.
internal static class Askpass
{
    public static int Run(string account, string prompt)
    {
        var passphrase = Environment.GetEnvironmentVariable("RELAYA_ASKPASS_KIND") == "passphrase";
        var expected = passphrase ? prompt.Contains("passphrase", StringComparison.OrdinalIgnoreCase) : PasswordPrompt.Matches(prompt);
        if (!expected || CredentialStore.Read(account) is not { } secret) return 1;
        Console.Out.Write(secret + "\n");
        Console.Out.Flush();
        return 0;
    }

    /// Окружение для ssh/sftp: askpass, если пароль хоста сохранён; иначе BatchMode, чтобы фоновый процесс не завис на запросе.
    /// Только пароль: пароль сохранён, а ключа у хоста нет — иначе ssh-agent переберёт ключи и сервер оборвёт вход.
    public static bool PasswordOnly(string alias) =>
        CredentialStore.Has(alias) && Data.AppState.Host(alias)?.identityFile == null;

    public static void SetEnvironment(ProcessStartInfo info, string alias)
    {
        info.Environment["SSH_ASKPASS"] = Environment.ProcessPath ?? "Relaya.exe";
        info.Environment["SSH_ASKPASS_REQUIRE"] = "force";
        info.Environment["RELAYA_ASKPASS_ACCOUNT"] = alias;
        info.Environment["DISPLAY"] = "relaya";
    }

    public static void Configure(ProcessStartInfo info, string alias, bool interactive = false)
    {
        if (CredentialStore.Has(alias))
        {
            if (PasswordOnly(alias))
                foreach (var o in uniffi.relaya_core.RelayaCoreMethods.PasswordOnlyOptions().Reverse<string>()) info.ArgumentList.Insert(0, o);
            SetEnvironment(info, alias);
        }
        else if (!interactive)
        {
            info.ArgumentList.Insert(0, "BatchMode=yes");
            info.ArgumentList.Insert(0, "-o");
        }
    }
}
