using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Relaya.Data;

namespace Relaya.Platform;

/// Одно соединение на хост для служебных операций (П-9): SFTP, диск WebDAV, статистика, команды карточки хоста.
/// Терминалы и tmux идут своими соединениями. Linux — ControlMaster в приватном каталоге (как Mac); Windows — один
/// долгоживущий `sftp -b -` на хост (OpenSSH для Windows не умеет ControlMaster). Хосты, чей конфиг запускает
/// программы (config_runs_commands), не мультиплексируются. Всё закрывается при выходе, блокировке сеанса и сне.
internal static partial class SshMux
{
    /// Аргументы sftp для пакетного режима: пароль — через askpass, обрыв замечается за минуту.
    public static readonly string[] SftpArgs =
        { "-o", "BatchMode=no", "-b", "-", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4" };

    static SshMux() => AppDomain.CurrentDomain.ProcessExit += (_, _) => CloseAll();

    /// Мультиплексировать можно: конфиг хоста не запускает программ (они унаследовали бы общее соединение).
    public static bool Allowed(string alias) => !Askpass.RunsCommands(alias);

    /// Параметры ssh для служебной команды на хосте; пусто — без общего соединения.
    public static IEnumerable<string> SshOptions(string alias) => Allowed(alias) ? PlatformSshOptions(alias) : Array.Empty<string>();

    /// Команды `sftp -b -` (пути — только через sftp_batch_path) с выводом как у отдельного запуска sftp.
    public static Task<AppState.Result> Sftp(string alias, string commands, int timeoutSeconds, CancellationToken cancel = default) =>
        Allowed(alias) ? PlatformSftp(alias, commands, timeoutSeconds, cancel) : RunSftp(alias, Array.Empty<string>(), commands, timeoutSeconds, cancel);

    /// Закрыть все общие соединения: выход, блокировка сеанса, сон.
    public static void CloseAll()
    {
        try { PlatformCloseAll(); }
        catch (Exception e) { Terminal.TerminalView.Trace("ssh mux close: " + e.Message); }
    }

    /// Отдельный запуск sftp (как до П-9) с дополнительными параметрами ssh.
    private static Task<AppState.Result> RunSftp(string alias, IEnumerable<string> options, string commands, int timeoutSeconds, CancellationToken cancel)
    {
        var args = new List<string>(options);
        args.AddRange(SftpArgs);
        args.Add(alias);
        return AppState.Run(AppState.SftpExe, args, alias, commands, timeoutSeconds, cancel);
    }

    private static partial IEnumerable<string> PlatformSshOptions(string alias);
    private static partial Task<AppState.Result> PlatformSftp(string alias, string commands, int timeoutSeconds, CancellationToken cancel);
    private static partial void PlatformCloseAll();
}
