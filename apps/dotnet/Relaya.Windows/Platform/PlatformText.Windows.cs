using static Relaya.Strings;

namespace Relaya.Platform;

internal static partial class PlatformText
{
    public static partial string PasswordSaved() => L("Сохранён в диспетчере учётных данных");
    public static partial string PasswordStored() => L("Хранится в диспетчере учётных данных Windows");
    public static partial string PasswordStoredAndTyped() => L("Хранится в диспетчере учётных данных Windows и вводится сам, когда сервер спросит пароль.");
    public static partial string SyncProfileHint() => L("Профиль — ваш git-репозиторий или папка (OneDrive, сетевой диск) и набор хостов. Пароли серверов не синхронизируются никогда.");
    public static partial string SyncPassphraseHint() => L("Нужен, чтобы передавать SSH-ключи. Одинаковый на всех устройствах. Хранится в диспетчере учётных данных Windows.");
    public static partial string SyncFolderOption() => L("Папка (OneDrive, сетевой диск)");
    public static partial string SyncFolderPath() => L("Путь к папке, например C:\\Users\\you\\OneDrive\\Relaya");
    public static partial string ExternalRdp() => L("Открыть в Подключении к удалённому рабочему столу");
    public static partial string RevealInFileManager() => L("Показать в Проводнике");
    public static partial string ExternalVnc() => L("Открыть во внешнем VNC-клиенте (TightVNC, RealVNC, UltraVNC или TigerVNC)");
}
