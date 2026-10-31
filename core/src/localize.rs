//! Тексты ядра, которые клиенты показывают пользователю, как ключи локализации: русская строка с `%@` и аргументы.
//! `CoreError` плоский — клиенты видят только сообщение, поэтому оно разбирается обратно по известным шаблонам.

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LocalizedText {
    /// Ключ локализации (русская строка с `%@`); без совпадения — само сообщение.
    pub key: String,
    /// Аргументы по порядку `%@`.
    pub args: Vec<String>,
}

/// Шаблоны сообщений ядра; порядок важен — более длинные и частные раньше.
const TEMPLATES: &[&str] = &[
    "Хост «%@» уже есть в ~/.ssh/config",
    "«%@» объявлен вместе с другими алиасами — отредактируйте ~/.ssh/config вручную",
    "Хост «%@» не найден в ~/.ssh/config",
    "Не удалось расшифровать ключ: неверный пароль синхронизации или файл повреждён.",
    "Недопустимое значение «%@»: перевод строки в ~/.ssh/config запрещён",
    "%@ в папке синхронизации повреждён, синхронизация остановлена: %@",
    "%@ повреждён, синхронизация остановлена: %@",
];

/// Имя клиента MCP, если агент не представился (поле `client` журнала): ключ локализации.
pub const MCP_UNKNOWN_CLIENT: &str = "агент";

fn regex_for(template: &str) -> regex::Regex {
    let parts: Vec<String> = template.split("%@").map(regex::escape).collect();
    regex::Regex::new(&format!("(?s)^{}$", parts.join("(.*?)"))).expect("template regex")
}

/// Сообщение ядра (`CoreError.message` и др.) → ключ и аргументы для `L(key, args)`.
/// Вложенное сообщение-аргумент (причина ошибки) тоже можно разобрать этой функцией.
#[uniffi::export]
pub fn core_error_localized(message: String) -> LocalizedText {
    for t in TEMPLATES {
        if let Some(c) = regex_for(t).captures(&message) {
            let args = c.iter().skip(1).flatten().map(|m| m.as_str().to_string()).collect();
            return LocalizedText { key: (*t).to_string(), args };
        }
    }
    LocalizedText { key: message, args: vec![] }
}

/// Ключ имени клиента MCP по умолчанию — чтобы клиенты сравнивали и переводили его, а не держали литерал.
#[uniffi::export]
pub fn mcp_unknown_client_key() -> String { MCP_UNKNOWN_CLIENT.into() }

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::CoreError;

    #[test]
    fn errors_become_keys_with_args() {
        let l = core_error_localized(CoreError::AliasTaken("web".into()).to_string());
        assert_eq!(l, LocalizedText { key: "Хост «%@» уже есть в ~/.ssh/config".into(), args: vec!["web".into()] });
        assert_eq!(core_error_localized(CoreError::Decrypt.to_string()).args, Vec::<String>::new());
        let shared = core_error_localized("tunnels.json в папке синхронизации повреждён, синхронизация остановлена: EOF at 1".into());
        assert_eq!(shared.key, "%@ в папке синхронизации повреждён, синхронизация остановлена: %@");
        assert_eq!(shared.args, vec!["tunnels.json", "EOF at 1"]);
        let local = core_error_localized("snippets.json повреждён, синхронизация остановлена: x".into());
        assert_eq!(local.args, vec!["snippets.json", "x"]);
        let other = core_error_localized("fatal: something".into());
        assert_eq!((other.key.as_str(), other.args.len()), ("fatal: something", 0));
        for t in TEMPLATES { assert!(regex_for(t).is_match(&t.replace("%@", "x")), "{t}"); }
    }
}
