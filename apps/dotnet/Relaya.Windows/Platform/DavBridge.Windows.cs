using System;
using System.Threading.Tasks;

namespace Relaya.Platform;

// Диск на Windows (WebClient, `net use`) — задача Relaya-windows; до неё пункт меню скрыт (DavBridge.Supported).
internal sealed partial class DavBridge
{
    private static partial Task MountVolumeAsync(string url, string user, string password) => throw new NotSupportedException();
    private static partial Task UnmountVolumeAsync(string url) => Task.CompletedTask;
    private static partial void OpenVolume(string url) { }
}
