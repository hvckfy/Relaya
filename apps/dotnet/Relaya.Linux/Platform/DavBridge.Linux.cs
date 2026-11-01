using System.Threading.Tasks;
using Relaya.Data;
using static Relaya.Strings;

namespace Relaya.Platform;

// gvfs: `gio mount dav://…` — диск появляется в Nautilus, Nemo, Thunar и других на GIO. Пароль gio спрашивает
// сам и читает его из stdin — в аргументы и окружение он не попадает.
internal sealed partial class DavBridge
{
    private static partial async Task MountVolumeAsync(string url, string user, string password)
    {
        if (Dialogs.Which("gio") == null) throw new System.IO.IOException(L("Нет gio — установите его в «Компонентах»."));
        var r = await AppState.Run("gio", new[] { "mount", url }, null, password + "\n", 30);
        if (r.Status != 0) throw new System.IO.IOException(L("Не удалось подключить диск: %@", r.Stderr.Trim()));
    }

    private static partial async Task UnmountVolumeAsync(string url)
    {
        var r = await AppState.Run("gio", new[] { "mount", "-u", url }, null, null, 30);
        if (r.Status != 0) throw new System.IO.IOException(L("Не удалось отключить диск: %@", r.Stderr.Trim()));
    }

    private static partial void OpenVolume(string url) => _ = AppState.Run("gio", new[] { "open", url }, null, null, 30);

    private static partial bool PlatformSupported() => true;
}
