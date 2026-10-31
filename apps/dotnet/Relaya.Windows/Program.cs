using System;
using System.Threading;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace Relaya;

public static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        // Askpass-режим: ssh.exe запускает этот же Relaya.exe с текстом запроса в аргументе (как на Mac).
        // Старый режим с учёткой в окружении отдавал пароль любому процессу — теперь только отказ.
        if (Environment.GetEnvironmentVariable("RELAYA_ASKPASS_ACCOUNT") != null) return 1;
        if (Environment.GetEnvironmentVariable("RELAYA_ASKPASS_TOKEN") is { } token)
            return Platform.Askpass.Run(Environment.GetEnvironmentVariable("RELAYA_ASKPASS_PIPE") ?? "", token, string.Join(' ', args));
        if (Array.IndexOf(args, "--mcp") >= 0)
            return Platform.McpHost.Run();

        // Самопроверка терминала в CI: настоящий TerminalView, Feed из фонового потока, отрисованный кадр.
        if (Array.IndexOf(args, "--selftest-terminal") is var i and >= 0)
            Terminal.TerminalSelfTest.LogPath = i + 1 < args.Length ? args[i + 1] : "selftest.log";

        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(p =>
        {
            SynchronizationContext.SetSynchronizationContext(
                new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            _ = new App();
        });
        return 0;
    }
}
