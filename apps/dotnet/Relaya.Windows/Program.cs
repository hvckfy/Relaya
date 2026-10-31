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
        if (Environment.GetEnvironmentVariable("RELAYA_ASKPASS_ACCOUNT") is { } account)
            return Platform.Askpass.Run(account, string.Join(' ', args));
        if (Array.IndexOf(args, "--mcp") >= 0)
            return Platform.McpHost.Run();

        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(_ =>
        {
            SynchronizationContext.SetSynchronizationContext(
                new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            _ = new App();
        });
        return 0;
    }
}
