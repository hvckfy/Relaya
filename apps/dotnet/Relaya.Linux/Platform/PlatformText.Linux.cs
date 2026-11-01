using static Relaya.Strings;

namespace Relaya.Platform;

// Хранилище паролей на Linux — Secret Service (GNOME Keyring, KWallet), «связка ключей» в терминах GNOME HIG.
internal static partial class PlatformText
{
    public static partial string PasswordSaved() => L("Сохранён в связке ключей");
    public static partial string PasswordStored() => L("Хранится в связке ключей (GNOME Keyring или KWallet)");
    public static partial string PasswordStoredAndTyped() => L("Хранится в связке ключей и вводится сам, когда сервер спросит пароль.");
    public static partial string SyncProfileHint() => L("Профиль — ваш git-репозиторий или папка (Nextcloud, Syncthing, сетевой диск) и набор хостов. Пароли серверов не синхронизируются никогда.");
    public static partial string SyncPassphraseHint() => L("Нужен, чтобы передавать SSH-ключи. Одинаковый на всех устройствах. Хранится в связке ключей.");
    public static partial string SyncFolderOption() => L("Папка (Nextcloud, Syncthing, сетевой диск)");
    public static partial string SyncFolderPath() => L("Путь к папке, например ~/Nextcloud/Relaya");
    public static partial string ExternalRdp() => L("Открыть во внешнем RDP-клиенте (FreeRDP или Remmina)");
}
