using System;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using static Relaya.Strings;

namespace Relaya.Platform;

// Диск на Windows (6.7): редиректор WebClient подключает WebDAV-адрес моста через WNetAddConnection2 без буквы
// и без сохранения (CONNECT_TEMPORARY) — адрес не оседает в реестре и на диске.
//
// Модель безопасности (осознанный компромисс, решение Relaya-audit-security): на Windows аутентификация —
// loopback (127.0.0.1) + случайный порт + секретный путь из CSPRNG, без Basic, потому что WebClient не шлёт Basic
// по http, а системный BasicAuthLevel мы не меняем. Mac и Linux по-прежнему требуют Basic.
internal sealed partial class DavBridge
{
    private static partial bool RequiresBasic() => false;

    // До решения пользователя пункт скрыт (Relaya-macos, 2026-11-01).
    private static partial bool PlatformSupported() => false;

    // dav://relaya@127.0.0.1:PORT/a/b → \\127.0.0.1@PORT\a\b (UNC-путь WebClient).
    private static string Unc(string url)
    {
        var u = new Uri(url.Replace("dav://", "http://"));
        return $@"\\{u.Host}@{u.Port}" + Uri.UnescapeDataString(u.AbsolutePath).Replace('/', '\\');
    }

    private static partial Task MountVolumeAsync(string url, string user, string password) => Task.Run(() =>
    {
        var res = new NetResource { dwType = RESOURCETYPE_DISK, lpRemoteName = Unc(url) };
        var rc = WNetAddConnection2W(ref res, null, null, CONNECT_TEMPORARY);
        if (rc == 0) return;
        throw new System.IO.IOException(rc is ERROR_BAD_NET_NAME or ERROR_NO_NETWORK
            ? L("Не удалось подключить диск: служба WebClient не запущена или не установлена.")
            : L("Не удалось подключить диск: %@", new System.ComponentModel.Win32Exception(rc).Message));
    });

    private static partial Task UnmountVolumeAsync(string url) => Task.Run(() =>
    {
        var rc = WNetCancelConnection2W(Unc(url), 0, true);
        if (rc != 0 && rc != ERROR_NOT_CONNECTED)
            throw new System.IO.IOException(L("Не удалось отключить диск: %@", new System.ComponentModel.Win32Exception(rc).Message));
    });

    private static partial void OpenVolume(string url) => Shell.OpenFolder(Unc(url));

    private const int RESOURCETYPE_DISK = 1, CONNECT_TEMPORARY = 4;
    private const int ERROR_BAD_NET_NAME = 67, ERROR_NO_NETWORK = 1222, ERROR_NOT_CONNECTED = 2250;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NetResource
    {
        public int dwScope, dwType, dwDisplayType, dwUsage;
        public string? lpLocalName, lpRemoteName, lpComment, lpProvider;
    }

    [DllImport("mpr.dll", CharSet = CharSet.Unicode)]
    private static extern int WNetAddConnection2W(ref NetResource res, string? password, string? user, int flags);

    [DllImport("mpr.dll", CharSet = CharSet.Unicode)]
    private static extern int WNetCancelConnection2W(string name, int flags, bool force);
}
