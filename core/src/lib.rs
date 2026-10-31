//! Ядро Relaya: всё, что не зависит от платформы и общее для клиентов macOS и Windows.
//! Платформенные вещи (Keychain/Credential Manager, Touch ID/Windows Hello, запуск процессов с askpass,
//! интерфейс) — в клиентах. Swift получает API через UniFFI, Windows-клиент (Tauri) — напрямую.

uniffi::setup_scaffolding!();

pub mod diff;
pub mod docker;
pub mod error;
pub mod fuzzy;
pub mod host_panel;
pub mod host_stats;
pub mod local_ports;
pub mod mcp;
pub mod models;
pub mod server_os;
pub mod ssh_config;
pub mod sync;
pub mod terminal;
pub mod tile_layout;
pub mod tmux;
pub mod tmux_control;
pub mod webdav;

pub use error::CoreError;

/// Строка в одинарных кавычках для POSIX sh.
pub fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

#[uniffi::export]
pub fn core_shell_quote(s: String) -> String {
    shell_quote(&s)
}

#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}
