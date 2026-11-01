namespace Relaya.Platform;

/// Подписи, в которых названо хранилище или программа платформы: «диспетчер учётных данных Windows» и «OneDrive»
/// на Linux звучат неверно (чек-лист функций 2.5, 9.16, 11.1, 11.3). Тексты — через L() в
/// Relaya.Windows/Platform/PlatformText.Windows.cs и Relaya.Linux/Platform/PlatformText.Linux.cs.
internal static partial class PlatformText
{
    /// Карточка хоста: пароль сохранён.
    public static partial string PasswordSaved();
    /// Редактор хоста: где хранится пароль.
    public static partial string PasswordStored();
    /// Окно ввода пароля: где хранится и что вводится сам.
    public static partial string PasswordStoredAndTyped();
    /// Синхронизация: что такое профиль.
    public static partial string SyncProfileHint();
    /// Синхронизация: пароль шифрования ключей.
    public static partial string SyncPassphraseHint();
    /// Синхронизация: вариант «папка» в списке.
    public static partial string SyncFolderOption();
    /// Синхронизация: подсказка пути к папке.
    public static partial string SyncFolderPath();
    /// Удалённые столы: открыть во внешнем RDP-клиенте.
    public static partial string ExternalRdp();
}
