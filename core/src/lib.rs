//! Ядро Relaya: всё, что не зависит от платформы и общее для клиентов macOS и Windows.
//! Платформенные вещи (Keychain/Credential Manager, Touch ID/Windows Hello, запуск процессов с askpass,
//! интерфейс) — в клиентах. Клиенты получают API через UniFFI: Swift (apps/swift) и C# (apps/dotnet).

uniffi::setup_scaffolding!();

pub mod diff;
pub mod docker;
pub mod error;
pub mod fuzzy;
pub mod host_panel;
pub mod host_stats;
pub mod key_hosts;
pub mod local_ports;
pub mod mcp;
pub mod models;
#[cfg(feature = "remote-desktop")]
pub mod remote;
pub mod server_os;
pub mod ssh_commands;
pub mod ssh_config;
pub mod ssh_errors;
pub mod sync;
pub mod terminal;
pub mod tile_layout;
pub mod tmux;
pub mod tmux_control;
pub mod webdav;

pub use error::CoreError;

/// Все процессы ядра создаются здесь: на Windows без консольного окна (CREATE_NO_WINDOW), иначе GUI-приложение
/// показывает вспыхивающую консоль на каждый вызов git. Дочерние процессы (ssh из GIT_SSH_COMMAND) консоль не получают.
pub(crate) fn command(program: &str) -> std::process::Command {
    #[allow(unused_mut)]
    let mut c = std::process::Command::new(program);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        c.creation_flags(CREATE_NO_WINDOW);
    }
    c
}

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
