namespace Relaya.Platform;

/// Подтверждение человеком перед выдачей пароля. На Linux нет общей системы вроде Windows Hello/Touch ID
/// (polkit — про права root, не про присутствие пользователя), поэтому системный вопрос с «Нет» по умолчанию.
internal static class Consent
{
    public static bool Ask(string text) => Dialogs.YesNo(text);
}
