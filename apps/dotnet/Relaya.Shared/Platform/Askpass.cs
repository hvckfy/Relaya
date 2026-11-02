using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;

namespace Relaya.Platform;

/// Askpass: так фоновые ssh (туннели, SFTP, панели) входят по паролю. Хранилище паролей askpass сам не читает:
/// он шлёт одноразовый токен и текст запроса процессу Relaya, запустившему ssh (AskpassBroker: named pipe на Windows,
/// UNIX-сокет на Linux), и печатает ответ.
internal static class Askpass
{
    public static int Run(string pipe, string token, string prompt)
    {
        try
        {
            using var client = AskpassBroker.Connect(pipe);
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
        info.Environment["SSH_ASKPASS"] = Environment.ProcessPath ?? (OperatingSystem.IsWindows() ? "Relaya.exe" : "relaya");
        info.Environment["SSH_ASKPASS_REQUIRE"] = "force";
        info.Environment["RELAYA_ASKPASS_PIPE"] = AskpassBroker.PipeName;
        info.Environment["RELAYA_ASKPASS_TOKEN"] = AskpassBroker.Issue(alias);
        // Windows OpenSSH зовёт askpass только при заданном DISPLAY; на Linux DISPLAY настоящий (X11-проброс), не трогаем.
        if (OperatingSystem.IsWindows()) info.Environment["DISPLAY"] = "relaya";
    }

    /// После Process.Start: токен askpass работает только для этого процесса (ssh или sftp).
    public static void Started(ProcessStartInfo info, Process process)
    {
        if (info.Environment.TryGetValue("RELAYA_ASKPASS_TOKEN", out var token) && token != null)
            AskpassBroker.Bind(token, process.Id);
    }

    /// ssh этого хоста запускает программы из конфига (ProxyCommand, LocalCommand, KnownHostsCommand, Match exec):
    /// они — потомки ssh и унаследовали бы токен, поэтому сохранённый пароль сам не подставляется (M8-1).
    public static bool RunsCommands(string alias) =>
        uniffi.relaya_core.RelayaCoreMethods.ConfigRunsCommandsIn(Data.AppState.ConfigText(), alias, Data.AppState.SshDir);

    /// Пароль можно подставить автоматически: он сохранён, и конфиг хоста не запускает чужих программ.
    public static bool CanAutofill(string alias) => CredentialStore.Has(alias) && !RunsCommands(alias);

    public static void Configure(ProcessStartInfo info, string alias, bool interactive = false)
    {
        if (CanAutofill(alias))
        {
            // B-1: one password prompt per background process, so a wrong saved password costs one failed login,
            // not six (askpass would answer every prompt with the same password).
            var options = PasswordOnly(alias)
                ? uniffi.relaya_core.RelayaCoreMethods.AskpassSshOptions()
                : new List<string> { "-o", "NumberOfPasswordPrompts=1" };
            foreach (var o in options.Reverse<string>()) info.ArgumentList.Insert(0, o);
            SetEnvironment(info, alias);
        }
        else if (!interactive)
        {
            info.ArgumentList.Insert(0, "BatchMode=yes");
            info.ArgumentList.Insert(0, "-o");
        }
    }
}
