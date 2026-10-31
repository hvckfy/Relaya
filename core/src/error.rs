/// Ошибки ядра. Тексты — русские ключи локализации: клиенты разбирают сообщение `core_error_localized` и
/// переводят `L(key, args)`. Новый текст ошибки — добавить шаблон в localize.rs и строку в en.lproj.
#[derive(Debug, thiserror::Error, uniffi::Error, PartialEq)]
#[uniffi(flat_error)]
pub enum CoreError {
    #[error("Хост «{0}» уже есть в ~/.ssh/config")]
    AliasTaken(String),
    #[error("«{0}» объявлен вместе с другими алиасами — отредактируйте ~/.ssh/config вручную")]
    SharedBlock(String),
    #[error("Хост «{0}» не найден в ~/.ssh/config")]
    NotFound(String),
    #[error("Не удалось расшифровать ключ: неверный пароль синхронизации или файл повреждён.")]
    Decrypt,
    #[error("Недопустимое значение «{0}»: перевод строки в ~/.ssh/config запрещён")]
    InvalidValue(String),
    #[error("{0}")]
    Io(String),
    #[error("{0}")]
    Git(String),
    #[error("{0}")]
    Json(String),
}

impl From<std::io::Error> for CoreError {
    fn from(e: std::io::Error) -> Self {
        CoreError::Io(e.to_string())
    }
}

impl From<serde_json::Error> for CoreError {
    fn from(e: serde_json::Error) -> Self {
        CoreError::Json(e.to_string())
    }
}
