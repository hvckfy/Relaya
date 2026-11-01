//! OpenH264 от Cisco для H.264 в RDP на macOS и Linux (на Windows — Media Foundation из ОС).
//! Бинарь Cisco не входит в пакет Relaya: пользователь включает кодек, клиент скачивает архив с ciscobinary.openh264.org,
//! проверяет sha256 и показывает `OPENH264_NOTICE`. Хеши закреплены здесь (получены workflow openh264-pin.yml,
//! MD5 сверен с подписанным списком Cisco) и обновляются вместе с core/native/freerdp.version.
//!
//! Требования к загрузке (TOCTOU между проверкой и dlopen):
//! - библиотека лежит в каталоге данных Relaya, куда пишет только Relaya (не во временной и не в общей папке);
//! - `openh264_verify_archive` — сразу после скачивания, `openh264_verify` — до любого использования;
//! - движок загружает только результат `checked_copy`: копия в приватном каталоге сессии, хеш считается по самой
//!   копии непосредственно перед dlopen, так что подменить файл между проверкой и загрузкой нельзя.

/// Надпись, которую лицензия Cisco требует показывать рядом с включением кодека.
pub const OPENH264_NOTICE: &str = "OpenH264 Video Codec provided by Cisco Systems, Inc.";
const VERSION: &str = "2.6.0";

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CodecPlatform {
    LinuxX64,
    LinuxArm64,
    MacArm64,
    MacX64,
    WindowsX64,
    WindowsArm64,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct OpenH264Info {
    pub version: String,
    /// Архив .bz2 на сервере Cisco.
    pub url: String,
    /// sha256 архива — проверить сразу после скачивания.
    pub archive_sha256: String,
    /// sha256 распакованной библиотеки — её проверяет `openh264_verify` перед каждым использованием.
    pub library_sha256: String,
    /// Имя файла для распакованной библиотеки в папке данных Relaya.
    pub file_name: String,
    pub notice: String,
}

/// Закреплённые (файл у Cisco, sha256 архива, sha256 библиотеки). match — компилятор проверит, что закреплена каждая
/// платформа.
fn pin(platform: CodecPlatform) -> (&'static str, &'static str, &'static str) {
    match platform {
        CodecPlatform::LinuxX64 => (
            "libopenh264-2.6.0-linux64.8.so",
            "27ab53323c110b76214c1c72222f459d17febbcd1e252136cadc292b0308d75b",
            "2f0cde7c6a6abcf5cae76942894ea42897fa677bce4ed6c91a24dd1b041d5f04",
        ),
        CodecPlatform::LinuxArm64 => (
            "libopenh264-2.6.0-linux-arm64.8.so",
            "a78aea7970150f46bcd3bb7994c9e6dd90bd7a9ea785920f5a73f6964e3fcda7",
            "12e7b33623667cdab0e575170c147b1b36eadb77d0d2aa7ceb5afd3e58902140",
        ),
        CodecPlatform::MacArm64 => (
            "libopenh264-2.6.0-mac-arm64.dylib",
            "6db362ee5abdab572311aeadb96d3f44b0617d9a4a4b9f4db4cb5ac4d968da71",
            "052e98bfcf7a9167d22f3bbb3f5988ef79065591f36af8b52924b22b13624551",
        ),
        CodecPlatform::MacX64 => (
            "libopenh264-2.6.0-mac-x64.dylib",
            "38b2ed6d1d45b6a3e408c734173f2d67ab44a10d0e154ff3489b89877cd60e7e",
            "e3dc8bc01fe69363f61fd3c02fd27798537a585eadd38cd808f303d1ee505a19",
        ),
        CodecPlatform::WindowsX64 => (
            "openh264-2.6.0-win64.dll",
            "dab5f2a872777f9a58b69bfa9fbcf20d9f82f2d6ec91383fd70bff49bd34ac9f",
            "2076cb5675ec6c1a4c70e7a2a322552f547b6eeed649d6dfcd9e02a543b24691",
        ),
        CodecPlatform::WindowsArm64 => (
            "openh264-2.6.0-win-arm64.dll",
            "6b57d3ecd06bd80b5f3ee1abbb31d48798ca6d89ef1bc98cf2e6d1ebddf5cf45",
            "fb75103938f4f47d119b983e06334df41a803bc72fb5c46e3623f6fea5782732",
        ),
    }
}

/// Платформа, на которой работает ядро; None — для неё у Cisco нет бинаря.
#[uniffi::export]
pub fn openh264_current_platform() -> Option<CodecPlatform> {
    match (std::env::consts::OS, std::env::consts::ARCH) {
        ("linux", "x86_64") => Some(CodecPlatform::LinuxX64),
        ("linux", "aarch64") => Some(CodecPlatform::LinuxArm64),
        ("macos", "aarch64") => Some(CodecPlatform::MacArm64),
        ("macos", "x86_64") => Some(CodecPlatform::MacX64),
        ("windows", "x86_64") => Some(CodecPlatform::WindowsX64),
        ("windows", "aarch64") => Some(CodecPlatform::WindowsArm64),
        _ => None,
    }
}

/// Что скачивать для платформы: закреплённые версия, адрес и хеши.
#[uniffi::export]
pub fn openh264_info(platform: CodecPlatform) -> OpenH264Info {
    let (file, archive, lib) = pin(platform);
    OpenH264Info {
        version: VERSION.into(),
        url: format!("https://ciscobinary.openh264.org/{file}.bz2"),
        archive_sha256: archive.into(),
        library_sha256: lib.into(),
        file_name: file.into(),
        notice: OPENH264_NOTICE.into(),
    }
}

fn sha256_file(path: &str) -> Option<String> {
    use sha2::Digest;
    use std::io::Read as _;
    let mut f = std::fs::File::open(path).ok()?;
    let mut h = sha2::Sha256::new();
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        let n = f.read(&mut buf).ok()?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
    }
    Some(h.finalize().iter().map(|b| format!("{b:02x}")).collect())
}

/// Тот ли это файл, что закреплён (распакованная библиотека Cisco для этой платформы)? Загружать только при true.
#[uniffi::export]
pub fn openh264_verify(path: String) -> bool {
    let Some(platform) = openh264_current_platform() else { return false };
    sha256_file(&path).map(|h| h == openh264_info(platform).library_sha256).unwrap_or(false)
}

/// Умеет ли эта сборка ядра H.264 в RDP: true, если собрано с rdp-freerdp. На Mac и Linux нужен OpenH264 от Cisco
/// (загрузка по переключателю), на Windows FreeRDP декодирует через Media Foundation. Клиенты показывают переключатель по ней.
#[uniffi::export]
pub fn remote_supports_h264() -> bool {
    cfg!(feature = "rdp-freerdp")
}

/// Где лежат проверенные копии: на Linux — XDG_RUNTIME_DIR (только пользователь, чистится при выходе из сеанса),
/// как сокет askpass; без него и на других ОС — temp_dir (на macOS он и так пользовательский).
pub(crate) fn copies_root() -> std::path::PathBuf {
    if cfg!(target_os = "linux") {
        if let Some(dir) = std::env::var_os("XDG_RUNTIME_DIR").map(std::path::PathBuf::from) {
            if dir.is_absolute() && dir.is_dir() {
                return dir;
            }
        }
    }
    std::env::temp_dir()
}

/// Скопировать библиотеку в приватный каталог (0700, только этот процесс) и проверить хеш копии. Вернуть путь копии
/// для dlopen; None — файл не тот или копия не удалась. Вызывать непосредственно перед загрузкой кодека.
#[cfg_attr(not(feature = "rdp-freerdp"), allow(dead_code))]
pub(crate) fn checked_copy(path: &str) -> Option<std::path::PathBuf> {
    let platform = openh264_current_platform()?;
    #[cfg(unix)]
    remove_stale_copies();
    let dir = copies_root().join(format!("relaya-openh264-{}-{}", std::process::id(), crate::models::new_id()));
    std::fs::create_dir(&dir).ok()?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).ok()?;
    }
    let copy = dir.join(openh264_info(platform).file_name);
    std::fs::copy(path, &copy).ok()?;
    if sha256_file(&copy.to_string_lossy())? != openh264_info(platform).library_sha256 {
        let _ = std::fs::remove_dir_all(&dir);
        return None;
    }
    Some(copy)
}

/// Удалить копии из `checked_copy` от завершившихся процессов: копия живёт, пока жив процесс, и при выходе не
/// удаляется. Каталог чужого живого процесса (или чужого пользователя — kill даёт EPERM) не трогается.
#[cfg(unix)]
#[cfg_attr(not(feature = "rdp-freerdp"), allow(dead_code))]
fn remove_stale_copies() {
    extern "C" {
        fn kill(pid: i32, sig: i32) -> i32;
    }
    const ESRCH: i32 = 3; // одинаково в Linux и macOS
    let Ok(entries) = std::fs::read_dir(copies_root()) else { return };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(rest) = name.to_str().and_then(|n| n.strip_prefix("relaya-openh264-")) else { continue };
        let Some(pid) = rest.split('-').next().and_then(|p| p.parse::<i32>().ok()).filter(|&p| p > 0) else { continue };
        if pid as u32 == std::process::id() {
            continue;
        }
        let dead = unsafe { kill(pid, 0) } != 0 && std::io::Error::last_os_error().raw_os_error() == Some(ESRCH);
        if dead {
            let _ = std::fs::remove_dir_all(entry.path());
        }
    }
}

/// Проверка скачанного архива .bz2 до распаковки.
#[uniffi::export]
pub fn openh264_verify_archive(path: String, platform: CodecPlatform) -> bool {
    sha256_file(&path).map(|h| h == openh264_info(platform).archive_sha256).unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_platform_is_pinned_and_verify_rejects_other_files() {
        for p in [
            CodecPlatform::LinuxX64,
            CodecPlatform::LinuxArm64,
            CodecPlatform::MacArm64,
            CodecPlatform::MacX64,
            CodecPlatform::WindowsX64,
            CodecPlatform::WindowsArm64,
        ] {
            let i = openh264_info(p);
            assert!(i.url.starts_with("https://ciscobinary.openh264.org/") && i.url.ends_with(".bz2"));
            assert_eq!((i.archive_sha256.len(), i.library_sha256.len()), (64, 64));
            assert_eq!(i.notice, "OpenH264 Video Codec provided by Cisco Systems, Inc.");
        }
        assert!(openh264_current_platform().is_some());
        assert_eq!(remote_supports_h264(), cfg!(feature = "rdp-freerdp"));
        let dir = tempfile::tempdir().unwrap();
        let f = dir.path().join("libopenh264.so");
        std::fs::write(&f, b"not cisco").unwrap();
        assert!(!openh264_verify(f.to_string_lossy().into()));
        assert!(!openh264_verify("/nonexistent".into()));
        assert!(checked_copy(&f.to_string_lossy()).is_none(), "чужой файл не копируется для загрузки");
        #[cfg(unix)]
        {
            // pid, которого нет (больше pid_max), — каталог удаляется; свой — остаётся.
            let tmp = copies_root();
            let stale = tmp.join(format!("relaya-openh264-{}-test", i32::MAX - 1));
            let mine = tmp.join(format!("relaya-openh264-{}-test", std::process::id()));
            std::fs::create_dir_all(&stale).unwrap();
            std::fs::create_dir_all(&mine).unwrap();
            remove_stale_copies();
            assert!(!stale.exists() && mine.exists());
            std::fs::remove_dir_all(&mine).unwrap();
        }
    }
}
