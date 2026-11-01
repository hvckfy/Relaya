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

/// (платформа, файл у Cisco, sha256 архива, sha256 библиотеки).
const PINS: &[(CodecPlatform, &str, &str, &str)] = &[
    (
        CodecPlatform::LinuxX64,
        "libopenh264-2.6.0-linux64.8.so",
        "27ab53323c110b76214c1c72222f459d17febbcd1e252136cadc292b0308d75b",
        "2f0cde7c6a6abcf5cae76942894ea42897fa677bce4ed6c91a24dd1b041d5f04",
    ),
    (
        CodecPlatform::LinuxArm64,
        "libopenh264-2.6.0-linux-arm64.8.so",
        "a78aea7970150f46bcd3bb7994c9e6dd90bd7a9ea785920f5a73f6964e3fcda7",
        "12e7b33623667cdab0e575170c147b1b36eadb77d0d2aa7ceb5afd3e58902140",
    ),
    (
        CodecPlatform::MacArm64,
        "libopenh264-2.6.0-mac-arm64.dylib",
        "6db362ee5abdab572311aeadb96d3f44b0617d9a4a4b9f4db4cb5ac4d968da71",
        "052e98bfcf7a9167d22f3bbb3f5988ef79065591f36af8b52924b22b13624551",
    ),
    (
        CodecPlatform::MacX64,
        "libopenh264-2.6.0-mac-x64.dylib",
        "38b2ed6d1d45b6a3e408c734173f2d67ab44a10d0e154ff3489b89877cd60e7e",
        "e3dc8bc01fe69363f61fd3c02fd27798537a585eadd38cd808f303d1ee505a19",
    ),
    (
        CodecPlatform::WindowsX64,
        "openh264-2.6.0-win64.dll",
        "dab5f2a872777f9a58b69bfa9fbcf20d9f82f2d6ec91383fd70bff49bd34ac9f",
        "2076cb5675ec6c1a4c70e7a2a322552f547b6eeed649d6dfcd9e02a543b24691",
    ),
    (
        CodecPlatform::WindowsArm64,
        "openh264-2.6.0-win-arm64.dll",
        "6b57d3ecd06bd80b5f3ee1abbb31d48798ca6d89ef1bc98cf2e6d1ebddf5cf45",
        "fb75103938f4f47d119b983e06334df41a803bc72fb5c46e3623f6fea5782732",
    ),
];

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
    let (_, file, archive, lib) = PINS.iter().find(|p| p.0 == platform).copied().expect("every platform is pinned");
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

/// Нужен ли этой сборке ядра OpenH264 от Cisco для H.264 (true — собрано с rdp-freerdp и не на Windows).
/// Клиент показывает переключатель загрузки OpenH264 только при true. Windows декодирует H.264 средствами системы.
#[uniffi::export]
pub fn openh264_supported() -> bool {
    cfg!(all(feature = "rdp-freerdp", not(windows)))
}

/// Скопировать библиотеку в приватный каталог (0700, только этот процесс) и проверить хеш копии. Вернуть путь копии
/// для dlopen; None — файл не тот или копия не удалась. Вызывать непосредственно перед загрузкой кодека.
#[cfg_attr(not(feature = "rdp-freerdp"), allow(dead_code))]
pub(crate) fn checked_copy(path: &str) -> Option<std::path::PathBuf> {
    let platform = openh264_current_platform()?;
    let dir = std::env::temp_dir().join(format!("relaya-openh264-{}-{}", std::process::id(), crate::models::new_id()));
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
        assert_eq!(openh264_supported(), cfg!(all(feature = "rdp-freerdp", not(windows))));
        let dir = tempfile::tempdir().unwrap();
        let f = dir.path().join("libopenh264.so");
        std::fs::write(&f, b"not cisco").unwrap();
        assert!(!openh264_verify(f.to_string_lossy().into()));
        assert!(!openh264_verify("/nonexistent".into()));
        assert!(checked_copy(&f.to_string_lossy()).is_none(), "чужой файл не копируется для загрузки");
    }
}
