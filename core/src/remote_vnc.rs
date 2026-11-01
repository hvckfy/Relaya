//! Встроенный VNC на RoyalVNCKit (MIT) через её C API (feature `vnc-royal`). Колбэки — те же, что у RDP
//! (`RemoteListener`: on_connected, on_frame, on_resize, on_closed); учётные данные — событием с типом входа
//! (VNC, ARD — имя и пароль macOS, MS-Logon) и ответом `provide_credentials`, без блокировки потоков FFI.
//! RoyalVNCKit — отдельная библиотека рядом с ядром (Linux — .so с -static-stdlib, Windows — dll + рантайм Swift).

use std::collections::HashMap;
use std::ffi::{c_char, c_void, CStr, CString};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock, Weak};

use crate::remote::{FrameRect, RemoteClose, RemoteCloseKind, RemoteListener};
use crate::LockExt;

type Ptr = *mut c_void;

#[allow(non_camel_case_types)]
type delegate_state = extern "C" fn(Ptr, Ptr, Ptr);
#[allow(non_camel_case_types)]
type delegate_auth = extern "C" fn(Ptr, Ptr, Ptr);
#[allow(non_camel_case_types)]
type delegate_fb = extern "C" fn(Ptr, Ptr, Ptr);
#[allow(non_camel_case_types)]
type delegate_update = extern "C" fn(Ptr, Ptr, Ptr, u16, u16, u16, u16);

/// Временная блокировка VNC-сервера (то же правило, что «Сервер VNC временно блокирует вход» в ssh_errors).
fn vnc_temporarily_blocked(message: &str) -> bool {
    crate::ssh_errors::remote_explain(crate::ssh_errors::RemoteProtocol::Vnc, message.to_string())
        .is_some_and(|p| p.title == "Сервер VNC временно блокирует вход")
}

extern "C" {
    fn rvnc_settings_create(
        debug: bool,
        hostname: *const c_char,
        port: u16,
        shared: bool,
        scaling: bool,
        display_link: bool,
        input_mode: i32,
        clipboard: bool,
        color_depth: i32,
        encodings: Ptr,
    ) -> Ptr;
    fn rvnc_settings_destroy(settings: Ptr);
    fn rvnc_connection_create(settings: Ptr, logger: Ptr, allocator: Ptr, context: Ptr) -> Ptr;
    fn rvnc_connection_destroy(connection: Ptr);
    fn rvnc_connection_connect(connection: Ptr);
    fn rvnc_connection_disconnect(connection: Ptr);
    fn rvnc_connection_delegate_create(
        state: delegate_state,
        auth: delegate_auth,
        created: delegate_fb,
        resized: delegate_fb,
        updated: delegate_update,
        cursor: delegate_fb,
    ) -> Ptr;
    fn rvnc_connection_delegate_destroy(delegate: Ptr);
    fn rvnc_connection_delegate_set(connection: Ptr, delegate: Ptr);
    fn rvnc_connection_context_get(connection: Ptr) -> Ptr;
    fn rvnc_connection_state_status_get(state: Ptr) -> i32;
    fn rvnc_connection_state_error_description_get_copy(state: Ptr) -> *mut c_char;
    fn rvnc_connection_state_error_is_authentication_error_get(state: Ptr) -> bool;
    fn rvnc_authentication_request_authentication_type_get(request: Ptr) -> i32;
    fn rvnc_authentication_request_cancel(request: Ptr);
    fn rvnc_authentication_request_complete_with_username_password(
        request: Ptr,
        user: *const c_char,
        password: *const c_char,
    );
    fn rvnc_authentication_request_complete_with_password(request: Ptr, password: *const c_char);
    fn rvnc_authentication_type_requires_username(kind: i32) -> bool;
    fn rvnc_framebuffer_size_width_get(fb: Ptr) -> u16;
    fn rvnc_framebuffer_size_height_get(fb: Ptr) -> u16;
    fn rvnc_framebuffer_pixel_data_get(fb: Ptr) -> *const u8;
    fn rvnc_framebuffer_pixel_data_size_get(fb: Ptr) -> u64;
    fn rvnc_connection_mouse_move(connection: Ptr, x: u16, y: u16);
    fn rvnc_connection_mouse_down(connection: Ptr, button: i32, x: u16, y: u16);
    fn rvnc_connection_mouse_up(connection: Ptr, button: i32, x: u16, y: u16);
    fn rvnc_connection_mouse_wheel(connection: Ptr, wheel: i32, x: u16, y: u16, steps: u32);
    fn rvnc_connection_key_down(connection: Ptr, keysym: u32);
    fn rvnc_connection_key_up(connection: Ptr, keysym: u32);
}

const STATUS_DISCONNECTED: i32 = 0;
const STATUS_CONNECTED: i32 = 2;
/// RVNC_INPUTMODE_*: 0 (NONE) выключает отправку мыши и клавиатуры — RoyalVNCKit молча отбрасывает ввод.
#[cfg(test)]
const INPUT_MODE_NONE: i32 = 0;
/// RVNC_INPUTMODE_FORWARDKEYBOARDSHORTCUTSIFNOTINUSELOCALLY: ввод идёт на сервер.
const INPUT_MODE_FORWARD: i32 = 1;
const COLOR_DEPTH_24: i32 = 24;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct VncConfig {
    pub host: String,
    pub port: u16,
    /// Имя для ARD (macOS) и MS-Logon; для обычного VNC не нужно.
    pub user: Option<String>,
    /// Пароль; пусто — спросить через `VncAuthListener`.
    pub password: Option<String>,
    /// Общий доступ: не отключать других зрителей.
    pub shared: bool,
}

/// Способ входа, который просит сервер.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum VncAuthKind {
    /// Пароль VNC (не длиннее 8 символов у классического VNC).
    Vnc,
    /// Apple Remote Desktop: имя и пароль пользователя macOS.
    AppleRemoteDesktop,
    /// UltraVNC MS-Logon II: имя и пароль Windows.
    MsLogon,
}

impl VncAuthKind {
    fn from_raw(raw: i32) -> Self {
        match raw {
            1 => VncAuthKind::AppleRemoteDesktop,
            2 => VncAuthKind::MsLogon,
            _ => VncAuthKind::Vnc,
        }
    }
}

/// Запрос учётных данных, если в `VncConfig` их нет. Ответ — `VncSession::provide_credentials` или
/// `cancel_credentials`; без слушателя вход отменяется.
#[uniffi::export(with_foreign)]
pub trait VncAuthListener: Send + Sync {
    fn on_credentials(&self, kind: VncAuthKind, needs_user: bool);
}

/// Состояние, к которому обращаются колбэки RoyalVNC (их потоки).
struct Shared {
    listener: Arc<dyn RemoteListener>,
    auth: Mutex<Option<Arc<dyn VncAuthListener>>>,
    config: VncConfig,
    /// Пароль из конфигурации: забирается при первом запросе и затирается после передачи в RoyalVNC.
    /// Известный остаток: RoyalVNC копирует его в свою Swift-строку, её обнулить нельзя (принятый низкий риск).
    password: Mutex<Option<String>>,
    /// Ожидающий запрос учётных данных и нужно ли ему имя (по типу запроса, не по ответу клиента).
    pending_auth: Mutex<Option<(usize, bool)>>,
    size: Mutex<(u16, u16)>,
    connected: Mutex<bool>,
    closed: Mutex<bool>,
}

struct Native {
    connection: Ptr,
    delegate: Ptr,
    settings: Ptr,
    /// Ключ сессии в `SESSIONS`, переданный RoyalVNC как контекст соединения.
    context: usize,
}
unsafe impl Send for Native {}

#[derive(uniffi::Object)]
pub struct VncSession {
    shared: Arc<Shared>,
    native: Mutex<Option<Native>>,
    pointer: Mutex<(u16, u16)>,
}

/// Сессии по ключу. RoyalVNC получает ключ, а не указатель: колбэк, пришедший из его потока после закрытия сессии,
/// не найдёт её (None), а не разыменует освобождённую память.
fn sessions() -> &'static Mutex<HashMap<usize, Weak<Shared>>> {
    static SESSIONS: OnceLock<Mutex<HashMap<usize, Weak<Shared>>>> = OnceLock::new();
    SESSIONS.get_or_init(Default::default)
}

fn session_register(shared: &Arc<Shared>) -> usize {
    static NEXT: AtomicUsize = AtomicUsize::new(1);
    let key = NEXT.fetch_add(1, Ordering::Relaxed);
    let mut map = sessions().locked();
    // Drop убирает свой ключ сам; здесь — страховка от записей сессий, освобождённых без Drop (утечка клиента).
    map.retain(|_, w| w.strong_count() > 0);
    map.insert(key, Arc::downgrade(shared));
    key
}

fn shared_of(connection: Ptr) -> Option<Arc<Shared>> {
    let key = unsafe { rvnc_connection_context_get(connection) } as usize;
    sessions().locked().get(&key)?.upgrade()
}

/// Прямоугольник кадра BGRA построчно; вне буфера — ничего (не читаем чужую память).
fn crop(fb: Ptr, x: u16, y: u16, w: u16, h: u16) -> Option<FrameRect> {
    let (fw, fh) = unsafe { (rvnc_framebuffer_size_width_get(fb), rvnc_framebuffer_size_height_get(fb)) };
    let len = unsafe { rvnc_framebuffer_pixel_data_size_get(fb) } as usize;
    let data = unsafe { rvnc_framebuffer_pixel_data_get(fb) };
    if data.is_null() || w == 0 || h == 0 || x as u32 + w as u32 > fw as u32 || y as u32 + h as u32 > fh as u32 {
        return None;
    }
    let stride = fw as usize * 4;
    if stride * fh as usize > len {
        return None;
    }
    let buf = unsafe { std::slice::from_raw_parts(data, len) };
    let mut bgra = Vec::with_capacity(w as usize * h as usize * 4);
    for row in y as usize..(y + h) as usize {
        let start = row * stride + x as usize * 4;
        bgra.extend_from_slice(&buf[start..start + w as usize * 4]);
    }
    Some(FrameRect { x, y, width: w, height: h, bgra })
}

extern "C" fn on_state(connection: Ptr, _ctx: Ptr, state: Ptr) {
    let Some(s) = shared_of(connection) else { return };
    let status = unsafe { rvnc_connection_state_status_get(state) };
    if status == STATUS_CONNECTED {
        *s.connected.locked() = true;
    }
    if status != STATUS_DISCONNECTED {
        return;
    }
    let mut closed = s.closed.locked();
    if *closed {
        return;
    }
    *closed = true;
    let raw = unsafe { rvnc_connection_state_error_description_get_copy(state) };
    let message = if raw.is_null() {
        String::new()
    } else {
        let m = unsafe { CStr::from_ptr(raw) }.to_string_lossy().into_owned();
        unsafe { libc_free(raw as *mut c_void) };
        m
    };
    let kind = if message.is_empty() {
        RemoteCloseKind::ClosedByUser
    } else if vnc_temporarily_blocked(&message) {
        // V-1: сервер временно блокирует вход после неудачных попыток — пароль может быть верным, не стирать.
        RemoteCloseKind::AccountProblem
    } else if unsafe { rvnc_connection_state_error_is_authentication_error_get(state) } {
        RemoteCloseKind::AuthFailed
    } else if *s.connected.locked() {
        RemoteCloseKind::ServerClosed
    } else {
        RemoteCloseKind::Network
    };
    s.listener.on_closed(RemoteClose { kind, message });
}

extern "C" {
    #[link_name = "free"]
    fn libc_free(p: *mut c_void);
}

extern "C" fn on_auth(connection: Ptr, _ctx: Ptr, request: Ptr) {
    let Some(s) = shared_of(connection) else { return };
    let raw = unsafe { rvnc_authentication_request_authentication_type_get(request) };
    let needs_user = unsafe { rvnc_authentication_type_requires_username(raw) };
    let stored = s.password.locked().take();
    if let Some(password) = stored.filter(|p| !p.is_empty()) {
        complete(request, needs_user, s.config.user.as_deref().unwrap_or(""), password);
        return;
    }
    let listener = s.auth.locked().clone();
    match listener {
        Some(l) => {
            *s.pending_auth.locked() = Some((request as usize, needs_user));
            l.on_credentials(VncAuthKind::from_raw(raw), needs_user);
        }
        None => unsafe { rvnc_authentication_request_cancel(request) },
    }
}

/// Затереть байты строки перед освобождением.
fn wipe(mut s: String) {
    // Нули — допустимый UTF-8, инвариант String сохраняется.
    unsafe { s.as_mut_vec() }.fill(0);
    std::hint::black_box(&s);
}

/// Передать учётные данные RoyalVNC; свои копии пароля (исходная строка и CString) затираются после вызова.
fn complete(request: Ptr, needs_user: bool, user: &str, password: String) {
    let cleaned: String = password.chars().filter(|&c| c != '\0').collect();
    wipe(password);
    let u = CString::new(user.replace('\0', "")).unwrap_or_default();
    let p = CString::new(cleaned).unwrap_or_default();
    unsafe {
        if needs_user {
            rvnc_authentication_request_complete_with_username_password(request, u.as_ptr(), p.as_ptr());
        } else {
            rvnc_authentication_request_complete_with_password(request, p.as_ptr());
        }
    }
    let mut bytes = p.into_bytes_with_nul();
    bytes.fill(0);
    std::hint::black_box(&bytes);
}

extern "C" fn on_create(connection: Ptr, _ctx: Ptr, fb: Ptr) {
    let Some(s) = shared_of(connection) else { return };
    let (w, h) = unsafe { (rvnc_framebuffer_size_width_get(fb), rvnc_framebuffer_size_height_get(fb)) };
    *s.size.locked() = (w, h);
    s.listener.on_connected(w, h);
}

/// К25: при входе приходит «смена размера» с тем же размером — буфер не пересоздаётся; настоящая — пересоздаётся.
extern "C" fn on_resize(connection: Ptr, _ctx: Ptr, fb: Ptr) {
    let Some(s) = shared_of(connection) else { return };
    let (w, h) = unsafe { (rvnc_framebuffer_size_width_get(fb), rvnc_framebuffer_size_height_get(fb)) };
    let changed = {
        let mut size = s.size.locked();
        let changed = *size != (w, h);
        *size = (w, h);
        changed
    };
    if changed {
        s.listener.on_resize(w, h);
        if let Some(r) = crop(fb, 0, 0, w, h) {
            s.listener.on_frame(vec![r]);
        }
    }
}

extern "C" fn on_update(connection: Ptr, _ctx: Ptr, fb: Ptr, x: u16, y: u16, w: u16, h: u16) {
    let Some(s) = shared_of(connection) else { return };
    if let Some(r) = crop(fb, x, y, w, h) {
        s.listener.on_frame(vec![r]);
    }
}

extern "C" fn on_cursor(_connection: Ptr, _ctx: Ptr, _cursor: Ptr) {}

/// Keysym X11 для символа Unicode: Latin-1 — как есть, остальное — 0x0100_0000 + код (стандарт X11).
#[uniffi::export]
pub fn vnc_keysym_for_char(codepoint: u32) -> u32 {
    match codepoint {
        0x20..=0x7E | 0xA0..=0xFF => codepoint,
        _ => 0x0100_0000 | codepoint,
    }
}

#[uniffi::export]
impl VncSession {
    #[uniffi::constructor]
    pub fn vnc(mut config: VncConfig, listener: Arc<dyn RemoteListener>) -> Arc<Self> {
        let password = Mutex::new(config.password.take());
        let shared = Arc::new(Shared {
            listener,
            auth: Mutex::new(None),
            config,
            password,
            pending_auth: Mutex::new(None),
            size: Mutex::new((0, 0)),
            connected: Mutex::new(false),
            closed: Mutex::new(false),
        });
        Arc::new(VncSession { shared, native: Mutex::new(None), pointer: Mutex::new((0, 0)) })
    }

    /// Слушатель запроса учётных данных (до `connect`), если в конфигурации их нет.
    pub fn set_auth_listener(&self, listener: Arc<dyn VncAuthListener>) {
        *self.shared.auth.locked() = Some(listener);
    }

    /// Подключиться; RoyalVNC работает в своих потоках. Повторный вызов ничего не делает.
    pub fn connect(&self) {
        let mut slot = self.native.locked();
        if slot.is_some() {
            return;
        }
        let c = &self.shared.config;
        let host = CString::new(c.host.replace('\0', "")).unwrap_or_default();
        let port = if c.port == 0 { 5900 } else { c.port };
        // Буфер обмена в C API RoyalVNC — только флаг перенаправления, без текста: выключен.
        let settings = unsafe {
            rvnc_settings_create(
                false,
                host.as_ptr(),
                port,
                c.shared,
                false,
                false,
                INPUT_MODE_FORWARD,
                false,
                COLOR_DEPTH_24,
                std::ptr::null_mut(),
            )
        };
        let context = session_register(&self.shared);
        let connection =
            unsafe { rvnc_connection_create(settings, std::ptr::null_mut(), std::ptr::null_mut(), context as Ptr) };
        let delegate =
            unsafe { rvnc_connection_delegate_create(on_state, on_auth, on_create, on_resize, on_update, on_cursor) };
        unsafe {
            rvnc_connection_delegate_set(connection, delegate);
            rvnc_connection_connect(connection);
        }
        *slot = Some(Native { connection, delegate, settings, context });
    }

    /// Ответ на `on_credentials`. Для ARD и MS-Logon нужно имя: передаётся ли оно, решает тип запроса, без имени —
    /// пустое.
    pub fn provide_credentials(&self, user: Option<String>, password: String) {
        let Some((request, needs_user)) = self.shared.pending_auth.locked().take() else {
            return;
        };
        complete(request as Ptr, needs_user, user.as_deref().unwrap_or(""), password);
    }

    pub fn cancel_credentials(&self) {
        if let Some((request, _)) = self.shared.pending_auth.locked().take() {
            unsafe { rvnc_authentication_request_cancel(request as Ptr) };
        }
    }

    /// Клавиша как X11 keysym (`vnc_keysym_for_char` — для символов).
    pub fn key(&self, keysym: u32, down: bool) {
        self.with(|c| unsafe {
            if down {
                rvnc_connection_key_down(c, keysym)
            } else {
                rvnc_connection_key_up(c, keysym)
            }
        });
    }

    /// Символ Unicode (IME, символы вне раскладки).
    pub fn unicode(&self, codepoint: u32, down: bool) {
        self.key(vnc_keysym_for_char(codepoint), down);
    }

    pub fn pointer(&self, x: u16, y: u16) {
        *self.pointer.locked() = (x, y);
        self.with(|c| unsafe { rvnc_connection_mouse_move(c, x, y) });
    }

    /// Кнопка мыши: 0 — левая, 1 — средняя, 2 — правая.
    pub fn button(&self, button: u8, down: bool) {
        if button > 2 {
            return;
        }
        let (x, y) = *self.pointer.locked();
        self.with(|c| unsafe {
            if down {
                rvnc_connection_mouse_down(c, button as i32, x, y)
            } else {
                rvnc_connection_mouse_up(c, button as i32, x, y)
            }
        });
    }

    /// Колесо: `units` как WHEEL_DELTA (120 на щелчок), положительное — вверх/вправо.
    pub fn wheel(&self, units: i16, vertical: bool) {
        if units == 0 {
            return;
        }
        let wheel = match (vertical, units > 0) {
            (true, true) => 2,
            (true, false) => 3,
            (false, true) => 1,
            (false, false) => 0,
        };
        let steps = (units.unsigned_abs() as u32 / 120).max(1);
        let (x, y) = *self.pointer.locked();
        self.with(|c| unsafe { rvnc_connection_mouse_wheel(c, wheel, x, y, steps) });
    }

    pub fn disconnect(&self) {
        self.cancel_credentials();
        self.with(|c| unsafe { rvnc_connection_disconnect(c) });
    }
}

impl VncSession {
    fn with(&self, f: impl FnOnce(Ptr)) {
        if let Some(n) = self.native.locked().as_ref() {
            f(n.connection);
        }
    }
}

impl Drop for VncSession {
    fn drop(&mut self) {
        self.cancel_credentials();
        let native = self.native.get_mut().unwrap_or_else(|e| e.into_inner()).take();
        if let Some(n) = native {
            // Сначала убрать ключ: поздние колбэки RoyalVNC больше не найдут сессию.
            sessions().locked().remove(&n.context);
            unsafe {
                rvnc_connection_disconnect(n.connection);
                rvnc_connection_destroy(n.connection);
                rvnc_connection_delegate_destroy(n.delegate);
                rvnc_settings_destroy(n.settings);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    #[test]
    fn settings_forward_input() {
        // С NONE в v0.17.0 кадры шли, а мышь и клавиатура — нет (Mac и Windows).
        assert_ne!(INPUT_MODE_FORWARD, INPUT_MODE_NONE);
        assert_eq!(INPUT_MODE_FORWARD, 1);
    }

    #[test]
    fn keysyms_for_characters() {
        assert_eq!(vnc_keysym_for_char('a' as u32), 0x61);
        assert_eq!(vnc_keysym_for_char('é' as u32), 0xE9);
        assert_eq!(vnc_keysym_for_char('ж' as u32), 0x0100_0436);
    }

    #[test]
    fn closed_port_reports_network_error() {
        struct L(Mutex<Option<RemoteClose>>);
        impl RemoteListener for L {
            fn on_connected(&self, _: u16, _: u16) {}
            fn on_frame(&self, _: Vec<FrameRect>) {}
            fn on_resize(&self, _: u16, _: u16) {}
            fn on_cert(&self, _: String, _: String) {}
            fn on_closed(&self, c: RemoteClose) {
                *self.0.locked() = Some(c);
            }
        }
        let l = Arc::new(L(Mutex::new(None)));
        let s = VncSession::vnc(
            VncConfig { host: "127.0.0.1".into(), port: 1, user: None, password: None, shared: true },
            l.clone(),
        );
        s.connect();
        let start = Instant::now();
        while l.0.locked().is_none() && start.elapsed() < Duration::from_secs(20) {
            std::thread::sleep(Duration::from_millis(50));
        }
        let kind = l.0.locked().as_ref().map(|c| c.kind);
        assert!(matches!(kind, Some(RemoteCloseKind::Network) | Some(RemoteCloseKind::ServerClosed)), "{kind:?}");
    }
}
