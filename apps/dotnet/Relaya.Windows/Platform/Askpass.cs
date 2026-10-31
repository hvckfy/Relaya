using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;

namespace Relaya.Platform;

/// Askpass: так фоновые ssh (туннели, SFTP, панели) входят по паролю. Сам Credential Manager askpass не читает:
/// он шлёт одноразовый токен и текст запроса в pipe процесса Relaya, запустившего ssh (AskpassBroker), и печатает ответ.
internal static class Askpass
{
    public static int Run(string pipe, string token, string prompt)
    {
        try
        {
            using var client = new System.IO.Pipes.NamedPipeClientStream(".", pipe, System.IO.Pipes.PipeDirection.InOut,
                System.IO.Pipes.PipeOptions.CurrentUserOnly); // сервер pipe — процесс того же пользователя
            client.Connect(5000);
            var request = System.Text.Encoding.UTF8.GetBytes(token + "\n" + prompt.Replace("\n", " ") + "\n");
            client.Write(request);
            client.Flush();
            using var reader = new System.IO.StreamReader(client, new System.Text.UTF8Encoding(false));
            if (reader.ReadLine() != "OK" || reader.ReadLine() is not { } secret) return 1;
            Console.Out.Write(secret + "\n");
            Console.Out.Flush();
            return 0;
        }
        catch (Exception) { return 1; }
    }

    /// Окружение для ssh/sftp: askpass, если пароль хоста сохранён; иначе BatchMode, чтобы фоновый процесс не завис на запросе.
    /// Только пароль: пароль сохранён, а ключа у хоста нет — иначе ssh-agent переберёт ключи и сервер оборвёт вход.
    public static bool PasswordOnly(string alias) =>
        CredentialStore.Has(alias) && Data.AppState.Host(alias)?.identityFile == null;

    public static void SetEnvironment(ProcessStartInfo info, string alias)
    {
        info.Environment["SSH_ASKPASS"] = Environment.ProcessPath ?? "Relaya.exe";
        info.Environment["SSH_ASKPASS_REQUIRE"] = "force";
        info.Environment["RELAYA_ASKPASS_PIPE"] = AskpassBroker.PipeName;
        info.Environment["RELAYA_ASKPASS_TOKEN"] = AskpassBroker.Issue(alias);
        info.Environment["DISPLAY"] = "relaya";
    }

    /// После Process.Start: токен askpass работает только для этого процесса (ssh или sftp).
    public static void Started(ProcessStartInfo info, Process process)
    {
        if (info.Environment.TryGetValue("RELAYA_ASKPASS_TOKEN", out var token) && token != null)
            AskpassBroker.Bind(token, process.Id);
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
