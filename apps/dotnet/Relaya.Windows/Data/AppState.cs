using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using uniffi.relaya_core;

namespace Relaya.Data;

/// Данные приложения: ~/.ssh/config (источник правды), сниппеты, туннели и удалённые столы в %APPDATA%\Relaya —
/// в тех же файлах и форматах, что на Mac, поэтому синхронизация переносит их между системами.
internal static class AppState
{
    public static readonly string SshDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".ssh");
    public static readonly string ConfigPath = Path.Combine(SshDir, "config");
    public static readonly string Support = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Relaya");

    public static List<SshHost> Hosts { get; private set; } = new();
    public static event Action? HostsChanged;

    public static string ConfigText() => File.Exists(ConfigPath) ? File.ReadAllText(ConfigPath) : "";

    public static void LoadHosts()
    {
        Hosts = RelayaCoreMethods.ParseConfig(ConfigText())
            .Where(h => !RelayaCoreMethods.IsPattern(h.alias) && !RelayaCoreMethods.HostIsGitService(h))
            .ToList();
        HostsChanged?.Invoke();
    }

    public static SshHost? Host(string alias) => Hosts.FirstOrDefault(h => h.alias == alias);

    public static IEnumerable<string> Groups() => Hosts.Select(h => h.group).OfType<string>().Distinct().OrderBy(g => g);

    /// Новый или изменённый хост; originalAlias — при переименовании.
    public static void Upsert(SshHost host, string? originalAlias)
    {
        SaveConfig(RelayaCoreMethods.ConfigUpsert(ConfigText(), host, originalAlias));
        LoadHosts();
    }

    /// Группа, метки, цвет, ОС, tmux — меняется только строка `# relaya:` блока.
    public static void SetMeta(SshHost h)
    {
        SaveConfig(RelayaCoreMethods.ConfigSetMeta(ConfigText(), h.alias, h.group, h.tags, h.color, h.os, h.tmux));
        LoadHosts();
    }

    /// Готовый текст конфига (правка ключей) — с копией и перечитыванием хостов.
    public static void WriteConfig(string text)
    {
        SaveConfig(text);
        LoadHosts();
    }

    public static void Remove(string alias)
    {
        SaveConfig(RelayaCoreMethods.ConfigRemove(ConfigText(), alias));
        Platform.CredentialStore.Delete(alias);
        LoadHosts();
    }

    // Как на Mac: перед каждой записью — копия config.relaya.bak. Запись атомарна: временный файл и File.Replace,
    // чтобы сбой посреди записи не оставил обрезанный ~/.ssh/config.
    private static void SaveConfig(string text)
    {
        Directory.CreateDirectory(SshDir);
        var tmp = ConfigPath + ".relaya.tmp";
        File.WriteAllText(tmp, text);
        if (File.Exists(ConfigPath)) File.Replace(tmp, ConfigPath, ConfigPath + ".relaya.bak", ignoreMetadataErrors: true);
        else File.Move(tmp, ConfigPath);
    }

    // --- JSON-списки (общие с Mac) ---

    public static List<Snippet> Snippets
    {
        get => RelayaCoreMethods.SnippetsDecode(Read("snippets.json"));
        set => Write("snippets.json", RelayaCoreMethods.SnippetsEncode(value));
    }

    public static List<Tunnel> Tunnels
    {
        get => RelayaCoreMethods.TunnelsDecode(Read("tunnels.json"));
        set => Write("tunnels.json", RelayaCoreMethods.TunnelsEncode(value));
    }

    public static List<RemoteDesktop> Desktops
    {
        get => RelayaCoreMethods.DesktopsDecode(Read("desktops.json"));
        set => Write("desktops.json", RelayaCoreMethods.DesktopsEncode(value));
    }

    private static string Read(string name)
    {
        var p = Path.Combine(Support, name);
        return File.Exists(p) ? File.ReadAllText(p) : "[]";
    }

    private static void Write(string name, string json)
    {
        Directory.CreateDirectory(Support);
        File.WriteAllText(Path.Combine(Support, name), json);
    }

    // --- Запуск ssh без терминала (панели, SFTP, ключи) ---

    public static string SshExe => Tool("ssh.exe");
    public static string SftpExe => Tool("sftp.exe");
    public static string KeygenExe => Tool("ssh-keygen.exe");

    private static string Tool(string name)
    {
        var system = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "OpenSSH", name);
        return File.Exists(system) ? system : name;
    }

    public sealed record Result(int Status, string Stdout, string Stderr);

    /// Команда на хосте: `ssh alias -- command`. Пароль — через askpass из Credential Manager.
    public static Task<Result> RunOnHost(string alias, string command, int timeoutSeconds = 30) =>
        Run(SshExe, new[] { "-o", "ConnectTimeout=10", alias, "--", command }, alias, null, timeoutSeconds);

    public static async Task<Result> Run(string exe, IEnumerable<string> args, string? askpassAlias, string? stdin, int timeoutSeconds = 60)
    {
        var info = new ProcessStartInfo(exe)
        {
            RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true,
            UseShellExecute = false, CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var a in args) info.ArgumentList.Add(a);
        if (askpassAlias != null) Platform.Askpass.Configure(info, askpassAlias);
        try
        {
            // Таймер — от старта процесса; stdout/stderr читаются до записи stdin, иначе большой вывод
            // заполнит канал, пока мы пишем stdin, и процессы заблокируют друг друга.
            var deadline = Task.Delay(TimeSpan.FromSeconds(timeoutSeconds));
            using var p = Process.Start(info)!;
            var output = p.StandardOutput.ReadToEndAsync();
            var error = p.StandardError.ReadToEndAsync();
            var input = Task.Run(async () =>
            {
                try { if (stdin != null) await p.StandardInput.WriteAsync(stdin); }
                catch (IOException) { } // процесс закрыл stdin раньше — вывод и код выхода всё равно прочитаем
                finally { try { p.StandardInput.Close(); } catch (IOException) { } }
            });
            var exited = Task.WhenAll(p.WaitForExitAsync(), input);
            if (await Task.WhenAny(exited, deadline) != exited)
            {
                try { p.Kill(true); } catch (InvalidOperationException) { }
                return new Result(-1, "", Strings.L("Время ожидания истекло"));
            }
            return new Result(p.ExitCode, await output, await error);
        }
        catch (Exception e)
        {
            return new Result(-1, "", e.Message);
        }
    }

    public static string SshCommand(SshHost h) => $"ssh {h.alias}";
}
