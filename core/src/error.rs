/// Ошибки ядра. Тексты — по-русски, как во всём приложении; клиенты показывают их как есть.
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
