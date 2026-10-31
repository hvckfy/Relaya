using System;
using Uno.UI.Hosting;

namespace Relaya;

public static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        // Askpass-режим: ssh запускает этот же relaya с текстом запроса в аргументе (как на Mac и Windows).
        // Старый режим с учёткой в окружении отдавал пароль любому процессу — только отказ.
        if (Environment.GetEnvironmentVariable("RELAYA_ASKPASS_ACCOUNT") != null) return 1;
        if (Environment.GetEnvironmentVariable("RELAYA_ASKPASS_TOKEN") is { } token)
            return Platform.Askpass.Run(Environment.GetEnvironmentVariable("RELAYA_ASKPASS_PIPE") ?? "", token, string.Join(' ', args));
        if (Array.IndexOf(args, "--mcp") >= 0)
            return Platform.McpHost.Run();

        // X11 (на Wayland — через XWayland); без дисплея — фреймбуфер.
        UnoPlatformHostBuilder.Create()
            .App(() => new App())
            .UseX11()
            .UseLinuxFrameBuffer()
            .Build()
            .Run();
        return 0;
    }
}
