//! Движок RDP на FreeRDP 3 (feature `rdp-freerdp`) под тем же API `RemoteSession`: прослойка C `native/relaya_rdp.c`
//! крутит сессию в своём потоке и зовёт колбэки, здесь они превращаются в события `RemoteListener` и слушателей
//! буфера обмена и звука. IronRDP при этой feature не используется.

use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::sync::{Arc, Mutex};

use crate::remote::{AudioFormat, FrameRect, RemoteClose, RemoteCloseKind, RemoteSession};
use crate::LockExt;

#[repr(C)]
struct Config {
    host: *const c_char,
    port: u16,
    user: *const c_char,
    password: *const c_char,
    domain: *const c_char,
    width: u32,
    height: u32,
    scale_percent: u32,
    gateway_host: *const c_char,
    gateway_user: *const c_char,
    gateway_password: *const c_char,
    gateway_domain: *const c_char,
    audio: c_int,
    h264: c_int,
    config_path: *const c_char,
}

#[repr(C)]
struct Callbacks {
    user: *mut c_void,
    on_connected: extern "C" fn(*mut c_void, u32, u32),
    on_rect: extern "C" fn(*mut c_void, *const u8, usize, u32, u32, u32, u32, u32),
    on_frame_end: extern "C" fn(*mut c_void),
    on_resize: extern "C" fn(*mut c_void, u32, u32),
    on_cert: extern "C" fn(*mut c_void, *const c_char, *const c_char) -> c_int,
    on_clipboard: Option<extern "C" fn(*mut c_void, *const c_char)>,
    on_audio: extern "C" fn(*mut c_void, u32, u16, u16, u32, *const u8, usize),
    on_audio_volume: extern "C" fn(*mut c_void, u16, u16),
    on_audio_closed: extern "C" fn(*mut c_void),
    on_closed: extern "C" fn(*mut c_void, c_int, *const c_char),
}

#[repr(C)]
struct RawRdp {
    _private: [u8; 0],
}

extern "C" {
    fn relaya_rdp_new(config: *const Config, callbacks: *const Callbacks) -> *mut RawRdp;
    fn relaya_rdp_run(rdp: *mut RawRdp);
    fn relaya_rdp_free(rdp: *mut RawRdp);
    fn relaya_rdp_key(rdp: *mut RawRdp, scancode: u16, down: c_int);
    fn relaya_rdp_unicode(rdp: *mut RawRdp, code: u16, down: c_int);
    fn relaya_rdp_pointer(rdp: *mut RawRdp, x: u16, y: u16);
    fn relaya_rdp_button(rdp: *mut RawRdp, button: u8, down: c_int);
    fn relaya_rdp_wheel(rdp: *mut RawRdp, units: i16, vertical: c_int);
    fn relaya_rdp_resize(rdp: *mut RawRdp, width: u32, height: u32);
    fn relaya_rdp_set_clipboard(rdp: *mut RawRdp, utf8: *const c_char);
    fn relaya_rdp_disconnect(rdp: *mut RawRdp);
}

/// Указатель на сессию C. Команды прослойки потокобезопасны (очередь под мьютексом).
pub(crate) struct Native(*mut RawRdp);
unsafe impl Send for Native {}
unsafe impl Sync for Native {}

impl Native {
    pub(crate) fn key(&self, scancode: u16, down: bool) {
        unsafe { relaya_rdp_key(self.0, scancode, down.into()) }
    }
    /// Символы вне BMP уходят суррогатной парой UTF-16.
    pub(crate) fn unicode(&self, codepoint: u32, down: bool) {
        let Some(c) = char::from_u32(codepoint) else { return };
        let mut buf = [0u16; 2];
        for unit in c.encode_utf16(&mut buf) {
            unsafe { relaya_rdp_unicode(self.0, *unit, down.into()) }
        }
    }
    pub(crate) fn pointer(&self, x: u16, y: u16) {
        unsafe { relaya_rdp_pointer(self.0, x, y) }
    }
    pub(crate) fn button(&self, button: u8, down: bool) {
        unsafe { relaya_rdp_button(self.0, button, down.into()) }
    }
    pub(crate) fn wheel(&self, units: i16, vertical: bool) {
        unsafe { relaya_rdp_wheel(self.0, units, vertical.into()) }
    }
    pub(crate) fn resize(&self, width: u16, height: u16) {
        unsafe { relaya_rdp_resize(self.0, width.into(), height.into()) }
    }
    pub(crate) fn set_clipboard(&self, text: &str) {
        let Ok(c) = CString::new(text.replace('\0', "")) else { return };
        unsafe { relaya_rdp_set_clipboard(self.0, c.as_ptr()) }
    }
    pub(crate) fn disconnect(&self) {
        unsafe { relaya_rdp_disconnect(self.0) }
    }
}

/// Состояние колбэков одной сессии: копит прямоугольники кадра до `on_frame_end`.
struct Ctx {
    session: Arc<RemoteSession>,
    rects: Mutex<Vec<FrameRect>>,
    closed: Mutex<Option<RemoteClose>>,
}

fn ctx<'a>(user: *mut c_void) -> &'a Ctx {
    unsafe { &*(user as *const Ctx) }
}
fn text(p: *const c_char) -> String {
    if p.is_null() {
        String::new()
    } else {
        unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
    }
}

extern "C" fn on_connected(user: *mut c_void, w: u32, h: u32) {
    ctx(user).session.listener().on_connected(w.min(u16::MAX as u32) as u16, h.min(u16::MAX as u32) as u16);
}

extern "C" fn on_rect(user: *mut c_void, buffer: *const u8, len: usize, stride: u32, x: u32, y: u32, w: u32, h: u32) {
    if buffer.is_null() || w == 0 || h == 0 {
        return;
    }
    let (stride, row) = (stride as usize, w as usize * 4);
    // W-RDP-5: прямоугольник целиком внутри буфера, иначе не копируем (не читаем чужую память).
    let end =
        (y as usize + h as usize - 1).checked_mul(stride).and_then(|v| v.checked_add((x as usize + w as usize) * 4));
    if end.map(|e| e > len).unwrap_or(true) || row > stride {
        return;
    }
    let mut bgra = Vec::with_capacity(row * h as usize);
    for line in y..y + h {
        let start = line as usize * stride + x as usize * 4;
        bgra.extend_from_slice(unsafe { std::slice::from_raw_parts(buffer.add(start), row) });
    }
    ctx(user).rects.locked().push(FrameRect { x: x as u16, y: y as u16, width: w as u16, height: h as u16, bgra });
}

extern "C" fn on_frame_end(user: *mut c_void) {
    let rects = std::mem::take(&mut *ctx(user).rects.locked());
    if !rects.is_empty() {
        ctx(user).session.listener().on_frame(rects);
    }
}

extern "C" fn on_resize(user: *mut c_void, w: u32, h: u32) {
    ctx(user).session.listener().on_resize(w.min(u16::MAX as u32) as u16, h.min(u16::MAX as u32) as u16);
}

extern "C" fn on_cert(user: *mut c_void, sha256: *const c_char, subject: *const c_char) -> c_int {
    ctx(user).session.ask_cert(text(sha256), text(subject)).into()
}

extern "C" fn on_clipboard(user: *mut c_void, utf8: *const c_char) {
    if let Some(l) = ctx(user).session.clipboard_listener() {
        l.on_remote_clipboard(text(utf8).trim_end_matches('\0').to_string());
    }
}

extern "C" fn on_audio(user: *mut c_void, rate: u32, channels: u16, bits: u16, ts: u32, pcm: *const u8, size: usize) {
    if pcm.is_null() {
        return;
    }
    if let Some(l) = ctx(user).session.audio_listener() {
        let data = unsafe { std::slice::from_raw_parts(pcm, size) }.to_vec();
        l.on_audio(AudioFormat { sample_rate: rate, channels, bits_per_sample: bits }, ts, data);
    }
}

extern "C" fn on_audio_volume(user: *mut c_void, left: u16, right: u16) {
    if let Some(l) = ctx(user).session.audio_listener() {
        l.on_audio_volume(left, right);
    }
}

extern "C" fn on_audio_closed(user: *mut c_void) {
    if let Some(l) = ctx(user).session.audio_listener() {
        l.on_audio_closed();
    }
}

extern "C" fn on_closed(user: *mut c_void, kind: c_int, message: *const c_char) {
    let kind = match kind {
        0 => RemoteCloseKind::ClosedByUser,
        1 => RemoteCloseKind::AuthFailed,
        2 => RemoteCloseKind::Network,
        3 => RemoteCloseKind::ServerClosed,
        4 => RemoteCloseKind::CertRejected,
        _ => RemoteCloseKind::Protocol,
    };
    *ctx(user).closed.locked() = Some(RemoteClose { kind, message: text(message) });
}

fn cstr(s: &str) -> CString {
    CString::new(s.replace('\0', "")).unwrap_or_default()
}
/// Каталог хранилища сертификатов FreeRDP на одну сессию (0700, удаляется после неё). Не создался — None:
/// FreeRDP возьмёт свой путь по умолчанию, подключение всё равно пойдёт через on_cert.
fn session_store() -> Option<std::path::PathBuf> {
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let n = NEXT.fetch_add(1, Ordering::Relaxed);
    let dir = crate::openh264::copies_root().join(format!("relaya-rdp-{}-{n}", std::process::id()));
    crate::webdav_policy::create_private_dir(&dir).ok().map(|_| dir)
}

/// Удалить каталог хранилища сессии; ошибку дописать к тексту закрытия, а не потерять.
fn with_cleanup_error(message: &mut String, store: &Option<std::path::PathBuf>) {
    let Some(dir) = store else { return };
    match std::fs::remove_dir_all(dir) {
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => {
            let line = format!("{}: {e}", dir.display());
            if message.is_empty() {
                *message = line;
            } else {
                message.push('\n');
                message.push_str(&line);
            }
        }
        _ => {}
    }
}

fn opt(s: &Option<String>) -> Option<CString> {
    s.as_deref().filter(|v| !v.is_empty()).map(cstr)
}
fn ptr(s: &Option<CString>) -> *const c_char {
    s.as_ref().map(|c| c.as_ptr()).unwrap_or(std::ptr::null())
}

/// Включать ли H.264 в этом подключении. Windows — Media Foundation, всегда. macOS и Linux — OpenH264 от Cisco (9.12):
/// только проверенная копия в приватном каталоге; FreeRDP берёт её путь из RELAYA_OPENH264_LIBRARY (патч overlay-порта).
/// Копия и переменная — одна на процесс: выставляется при первом подключении с H.264 и больше не меняется, так что
/// параллельные подключения не затирают её друг другу. Подключение без H.264 выключает кодек настройкой FreeRDP
/// (GfxH264), не окружением. Остаток: первая установка переменной может совпасть с чтением окружения в другом потоке
/// FreeRDP — однократно за процесс, принято.
fn h264_enabled(library: Option<&str>) -> bool {
    if cfg!(windows) {
        return true;
    }
    static COPY: Mutex<Option<std::path::PathBuf>> = Mutex::new(None);
    let Some(library) = library.filter(|p| !p.is_empty()) else { return false };
    let mut copy = COPY.locked();
    if copy.is_none() {
        // Не прошла проверку — без H.264, не ошибка.
        let Some(path) = crate::openh264::checked_copy(library) else { return false };
        std::env::set_var("RELAYA_OPENH264_LIBRARY", &path);
        *copy = Some(path);
    }
    true
}

/// Запустить сессию FreeRDP в своём потоке. Повторный вызов ничего не делает.
pub(crate) fn connect(session: Arc<RemoteSession>) {
    if session.native.locked().is_some() {
        return;
    }
    let c = session.config().clone();
    // Пустой приватный каталог на сессию: сертификат каждый раз решает on_cert (TOFU ядра), а не файлы FreeRDP.
    let store = session_store();
    let store_c = store.as_ref().map(|p| p.to_string_lossy().into_owned()).and_then(|p| CString::new(p).ok());
    let h264 = h264_enabled(c.h264_library_path.as_deref());
    let (host, user, password) = (cstr(&c.host), cstr(&c.user), cstr(&c.password));
    let (domain, gw_host, gw_user, gw_password, gw_domain) =
        (opt(&c.domain), opt(&c.gateway_host), opt(&c.gateway_user), opt(&c.gateway_password), opt(&c.gateway_domain));
    let config = Config {
        host: host.as_ptr(),
        port: c.port,
        user: user.as_ptr(),
        password: password.as_ptr(),
        domain: ptr(&domain),
        width: c.width.into(),
        height: c.height.into(),
        scale_percent: c.scale_percent,
        gateway_host: ptr(&gw_host),
        gateway_user: ptr(&gw_user),
        gateway_password: ptr(&gw_password),
        gateway_domain: ptr(&gw_domain),
        audio: session.audio_listener().is_some().into(),
        h264: h264.into(),
        config_path: ptr(&store_c),
    };
    let ctx = Box::into_raw(Box::new(Ctx {
        session: session.clone(),
        rects: Mutex::new(Vec::new()),
        closed: Mutex::new(None),
    }));
    let callbacks = Callbacks {
        user: ctx as *mut c_void,
        on_connected,
        on_rect,
        on_frame_end,
        on_resize,
        on_cert,
        // W-RDP-2: без слушателя буфера обмена к моменту connect текст с сервера не запрашивается.
        on_clipboard: session
            .clipboard_listener()
            .is_some()
            .then_some(on_clipboard as extern "C" fn(*mut c_void, *const c_char)),
        on_audio,
        on_audio_volume,
        on_audio_closed,
        on_closed,
    };
    // Прослойка копирует строки конфигурации сама.
    let raw = unsafe { relaya_rdp_new(&config, &callbacks) };
    if raw.is_null() {
        drop(unsafe { Box::from_raw(ctx) });
        session
            .listener()
            .on_closed(RemoteClose { kind: RemoteCloseKind::Protocol, message: "relaya_rdp_new failed".into() });
        return;
    }
    *session.native.locked() = Some(Native(raw));
    let (ctx_addr, raw_addr) = (ctx as usize, raw as usize);
    let store_left = store.clone();
    let spawned = std::thread::Builder::new().name("relaya-freerdp".into()).spawn(move || {
        unsafe { relaya_rdp_run(raw_addr as *mut RawRdp) };
        let ctx = unsafe { Box::from_raw(ctx_addr as *mut Ctx) };
        let mut close = ctx
            .closed
            .locked()
            .take()
            .unwrap_or(RemoteClose { kind: RemoteCloseKind::ClosedByUser, message: String::new() });
        // Сначала убрать указатель, чтобы команды после закрытия не ушли в освобождённую сессию.
        let native = ctx.session.native.locked().take();
        if let Some(Native(p)) = native {
            unsafe { relaya_rdp_free(p) }
        }
        with_cleanup_error(&mut close.message, &store);
        ctx.session.listener().on_closed(close);
    });
    if let Err(e) = spawned {
        // Поток не создан: освободить сессию и контекст, иначе клиент навсегда останется в «Подключение…».
        let native = session.native.locked().take();
        if let Some(Native(p)) = native {
            unsafe { relaya_rdp_free(p) }
        }
        drop(unsafe { Box::from_raw(ctx_addr as *mut Ctx) });
        let mut message = e.to_string();
        with_cleanup_error(&mut message, &store_left);
        session.listener().on_closed(RemoteClose { kind: RemoteCloseKind::Protocol, message });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn store_cleanup_reports_errors() {
        let dir = tempfile::tempdir().unwrap();
        let store = dir.path().join("s");
        std::fs::create_dir(&store).unwrap();
        let mut message = String::new();
        with_cleanup_error(&mut message, &Some(store.clone()));
        assert!(message.is_empty() && !store.exists());
        with_cleanup_error(&mut message, &Some(store.clone()));
        assert!(message.is_empty(), "уже удалённый каталог — не ошибка");
        // Файл вместо каталога: remove_dir_all падает, текст дописывается к сообщению.
        std::fs::write(&store, b"x").unwrap();
        let mut message = "closed".to_string();
        with_cleanup_error(&mut message, &Some(store.clone()));
        assert!(message.starts_with("closed\n") && message.contains(&store.display().to_string()), "{message}");
    }
}
