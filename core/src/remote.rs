//! Встроенный RDP для Windows, Linux и macOS на FreeRDP 3 (feature rdp-freerdp, прослойка `native/relaya_rdp.c`):
//! общие типы, сессия для клиентов и доверие к сертификатам по узлам. Движок IronRDP удалён (R-6): ни одна сборка
//! его не использовала, а политика входа расходилась с FreeRDP.

use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::LockExt;

/// Сколько ждать решения пользователя об отпечатке сертификата.
#[cfg_attr(not(feature = "rdp-freerdp"), allow(dead_code))] // нужно движку FreeRDP
const CERT_TIMEOUT: Duration = Duration::from_secs(120);

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RdpConfig {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub password: String,
    pub domain: Option<String>,
    pub width: u16,
    pub height: u16,
    /// Масштаб рабочего стола на сервере, 100 — без масштаба.
    pub scale_percent: u32,
    /// SHA-256 сертификата сервера (hex), которому пользователь уже доверился (только узел `host:port` подключения;
    /// прежний формат — один слот на стол).
    pub trusted_cert_sha256: Option<String>,
    /// Доверие по узлам (R-4): шлюз, сервер и сервер после перенаправления брокером — каждый со своим отпечатком.
    #[uniffi(default = [])]
    pub trusted_certs: Vec<TrustedCert>,
    /// RD Gateway (`host` или `host:port`); пусто — подключение напрямую. Используется движком FreeRDP.
    #[uniffi(default = None)]
    pub gateway_host: Option<String>,
    /// Учётные данные шлюза; пусто — те же, что для сервера.
    #[uniffi(default = None)]
    pub gateway_user: Option<String>,
    #[uniffi(default = None)]
    pub gateway_password: Option<String>,
    #[uniffi(default = None)]
    pub gateway_domain: Option<String>,
    /// Путь к библиотеке H.264 (OpenH264 от Cisco, скачанной пользователем). Только из каталога данных Relaya, куда
    /// пишет одна Relaya; клиент проверяет `openh264_verify` до передачи, а движок загружает не этот файл, а
    /// `openh264::checked_copy` (хеш копии сразу перед dlopen). Пусто — системный декодер (Windows) или без H.264.
    #[uniffi(default = None)]
    pub h264_library_path: Option<String>,
}

/// Роль узла, чей сертификат проверяется: для текста вопроса. Ключ доверия — `host:port`, не роль.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CertRole {
    /// Сервер, указанный в настройках стола.
    Target,
    /// RD Gateway.
    Gateway,
    /// Сервер, куда перенаправил брокер: адрес пришёл от сервера — отдельный первый вопрос, не наследует доверие цели.
    Redirect,
}

/// Узел, чей сертификат проверяется: `host` в нижнем регистре, явный порт.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CertNode {
    pub host: String,
    pub port: u16,
    pub role: CertRole,
}

/// Отпечаток, которому доверились, для узла `host:port`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TrustedCert {
    pub host: String,
    pub port: u16,
    pub sha256: String,
}

/// Изменившийся прямоугольник экрана, пиксели BGRA построчно без отступов.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FrameRect {
    pub x: u16,
    pub y: u16,
    pub width: u16,
    pub height: u16,
    pub bgra: Vec<u8>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RemoteCloseKind {
    AuthFailed,
    Network,
    ServerClosed,
    CertRejected,
    Protocol,
    ClosedByUser,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RemoteClose {
    pub kind: RemoteCloseKind,
    pub message: String,
}

/// События сессии — из потока сессии; клиент переносит их в UI-поток сам.
#[uniffi::export(with_foreign)]
pub trait RemoteListener: Send + Sync {
    /// Подключено, размер рабочего стола; следом придёт полный кадр.
    fn on_connected(&self, width: u16, height: u16);
    /// Изменившиеся прямоугольники.
    fn on_frame(&self, rects: Vec<FrameRect>);
    /// Сервер сменил размер рабочего стола (после resize или реактивации); следом — полный кадр.
    fn on_resize(&self, width: u16, height: u16);
    /// Сертификат узла `node` не тот, которому доверились: ответ — `RemoteSession::accept_cert`. Без ответа — отказ.
    fn on_cert(&self, sha256: String, subject: String, node: CertNode);
    fn on_closed(&self, close: RemoteClose);
}

/// Текст из буфера обмена удалённой машины. Необязательный слушатель: `RemoteSession::set_clipboard_listener`.
#[uniffi::export(with_foreign)]
pub trait RemoteClipboardListener: Send + Sync {
    fn on_remote_clipboard(&self, text: String);
}

/// PCM-формат звука: всегда несжатый little-endian, сервер получает в предложении только PCM.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct AudioFormat {
    pub sample_rate: u32,
    pub channels: u16,
    pub bits_per_sample: u16,
}

/// Звук удалённой машины (RDPSND). Необязательный слушатель: `RemoteSession::set_audio_listener` до `connect`;
/// без него звук сервер не присылает. Воспроизведение, громкость и отключение — на стороне клиента.
#[uniffi::export(with_foreign)]
pub trait RemoteAudioListener: Send + Sync {
    /// Кусок PCM; `timestamp` — метка сервера (мс), по ней можно выравнивать задержку.
    fn on_audio(&self, format: AudioFormat, timestamp: u32, pcm: Vec<u8>);
    /// Громкость, которую выставил сервер, 0..=65535 на канал.
    fn on_audio_volume(&self, left: u16, right: u16);
    /// Сервер закрыл звуковой поток.
    fn on_audio_closed(&self);
}

#[derive(uniffi::Object)]
pub struct RemoteSession {
    config: RdpConfig,
    listener: Arc<dyn RemoteListener>,
    cert_answer: Mutex<Option<Sender<bool>>>,
    clipboard: Mutex<Option<Arc<dyn RemoteClipboardListener>>>,
    audio: Mutex<Option<Arc<dyn RemoteAudioListener>>>,
    /// Сессия FreeRDP (feature rdp-freerdp): команды идут прямо в прослойку C.
    #[cfg(feature = "rdp-freerdp")]
    pub(crate) native: Mutex<Option<crate::remote_freerdp::Native>>,
}

#[uniffi::export]
impl RemoteSession {
    #[uniffi::constructor]
    pub fn rdp(config: RdpConfig, listener: Arc<dyn RemoteListener>) -> Arc<Self> {
        Arc::new(RemoteSession {
            config,
            listener,
            cert_answer: Mutex::new(None),
            clipboard: Mutex::new(None),
            audio: Mutex::new(None),
            #[cfg(feature = "rdp-freerdp")]
            native: Mutex::new(None),
        })
    }

    /// Запустить сессию в своём потоке. Повторный вызов ничего не делает.
    pub fn connect(self: Arc<Self>) {
        #[cfg(feature = "rdp-freerdp")]
        crate::remote_freerdp::connect(self);
        // Ядро без FreeRDP (локальная сборка без зависимостей): RDP нет — сказать об этом, а не молчать.
        #[cfg(not(feature = "rdp-freerdp"))]
        self.listener.on_closed(RemoteClose {
            kind: RemoteCloseKind::Protocol,
            message: "RDP engine is not built (rdp-freerdp feature is off)".into(),
        });
    }

    /// Ответ на `on_cert`.
    pub fn accept_cert(&self, accept: bool) {
        if let Some(tx) = self.cert_answer.locked().take() {
            let _ = tx.send(accept);
        }
    }

    /// Клавиша по scancode набора 1; расширенные — с префиксом 0xE0 (например 0xE04B — стрелка влево).
    pub fn key(&self, scancode: u16, down: bool) {
        #[cfg(feature = "rdp-freerdp")]
        if let Some(n) = self.native.locked().as_ref() {
            n.key(scancode, down);
        }
        #[cfg(not(feature = "rdp-freerdp"))]
        let _ = scancode;
        #[cfg(not(feature = "rdp-freerdp"))]
        let _ = down;
    }

    /// Символ, которого нет в раскладке сервера (IME, эмодзи).
    pub fn unicode(&self, codepoint: u32, down: bool) {
        #[cfg(feature = "rdp-freerdp")]
        if let Some(n) = self.native.locked().as_ref() {
            n.unicode(codepoint, down);
        }
        #[cfg(not(feature = "rdp-freerdp"))]
        let _ = codepoint;
        #[cfg(not(feature = "rdp-freerdp"))]
        let _ = down;
    }

    pub fn pointer(&self, x: u16, y: u16) {
        #[cfg(feature = "rdp-freerdp")]
        if let Some(n) = self.native.locked().as_ref() {
            n.pointer(x, y);
        }
        #[cfg(not(feature = "rdp-freerdp"))]
        let _ = x;
        #[cfg(not(feature = "rdp-freerdp"))]
        let _ = y;
    }

    /// Кнопка мыши: 0 — левая, 1 — средняя, 2 — правая, 3 и 4 — «назад» и «вперёд».
    pub fn button(&self, button: u8, down: bool) {
        #[cfg(feature = "rdp-freerdp")]
        if let Some(n) = self.native.locked().as_ref() {
            n.button(button, down);
        }
        #[cfg(not(feature = "rdp-freerdp"))]
        let _ = button;
        #[cfg(not(feature = "rdp-freerdp"))]
        let _ = down;
    }

    /// Колесо: `units` — как WHEEL_DELTA (120 на щелчок), положительное — вверх/вправо.
    pub fn wheel(&self, units: i16, vertical: bool) {
        #[cfg(feature = "rdp-freerdp")]
        if let Some(n) = self.native.locked().as_ref() {
            n.wheel(units, vertical);
        }
        #[cfg(not(feature = "rdp-freerdp"))]
        let _ = units;
        #[cfg(not(feature = "rdp-freerdp"))]
        let _ = vertical;
    }

    /// Получать текст, скопированный на удалённой машине. Без слушателя буфер обмена только отдаётся серверу.
    pub fn set_clipboard_listener(&self, listener: Arc<dyn RemoteClipboardListener>) {
        *self.clipboard.locked() = Some(listener);
    }

    /// Получать звук удалённой машины. Вызывать до `connect`: от этого зависит, попросим ли мы звук у сервера.
    pub fn set_audio_listener(&self, listener: Arc<dyn RemoteAudioListener>) {
        *self.audio.locked() = Some(listener);
    }

    /// Текст из локального буфера обмена: станет доступен для вставки на удалённой машине.
    pub fn set_clipboard(&self, text: String) {
        #[cfg(feature = "rdp-freerdp")]
        if let Some(n) = self.native.locked().as_ref() {
            n.set_clipboard(&text);
        }
        #[cfg(not(feature = "rdp-freerdp"))]
        let _ = text;
    }

    /// Новый размер окна: через Display Control, если сервер его поддерживает.
    pub fn resize(&self, width: u16, height: u16) {
        #[cfg(feature = "rdp-freerdp")]
        if let Some(n) = self.native.locked().as_ref() {
            n.resize(width, height);
        }
        #[cfg(not(feature = "rdp-freerdp"))]
        let _ = width;
        #[cfg(not(feature = "rdp-freerdp"))]
        let _ = height;
    }

    pub fn disconnect(&self) {
        #[cfg(feature = "rdp-freerdp")]
        if let Some(n) = self.native.locked().as_ref() {
            n.disconnect();
        }
        self.accept_cert(false);
    }
}

/// Узел с нормализованным адресом (нижний регистр, без точки в конце) и ролью.
fn cert_node(config: &RdpConfig, host: &str, port: u16, gateway: bool) -> CertNode {
    let host = host.trim().trim_end_matches('.').to_lowercase();
    let role = if gateway {
        CertRole::Gateway
    } else if host == config.host.trim().trim_end_matches('.').to_lowercase() && port == config.port {
        CertRole::Target
    } else {
        CertRole::Redirect
    };
    CertNode { host, port, role }
}

/// Тихое доверие — только точное совпадение отпечатка для этого `host:port`. Старый слот `trusted_cert_sha256`
/// относится к цели из настроек и не распространяется на шлюз и перенаправление.
#[cfg_attr(not(feature = "rdp-freerdp"), allow(dead_code))] // нужно движку FreeRDP
fn cert_trusted(config: &RdpConfig, node: &CertNode, sha256: &str) -> bool {
    let by_node = config.trusted_certs.iter().any(|t| {
        t.host.trim().trim_end_matches('.').to_lowercase() == node.host
            && t.port == node.port
            && t.sha256.eq_ignore_ascii_case(sha256)
    });
    let legacy = node.role == CertRole::Target
        && config.trusted_cert_sha256.as_deref().is_some_and(|t| t.eq_ignore_ascii_case(sha256));
    by_node || legacy
}

impl RemoteSession {
    /// Доверять ли сертификату: совпал с сохранённым отпечатком — да; иначе спросить клиента и ждать `accept_cert`.
    /// Ждёт поток сессии, а не поток FFI.
    #[cfg_attr(not(feature = "rdp-freerdp"), allow(dead_code))] // нужно движку FreeRDP
    pub(crate) fn ask_cert(&self, sha256: String, subject: String, node: CertNode) -> bool {
        if cert_trusted(&self.config, &node, &sha256) {
            return true;
        }
        let (tx, rx) = mpsc::channel();
        *self.cert_answer.locked() = Some(tx);
        self.listener.on_cert(sha256, subject, node);
        matches!(rx.recv_timeout(CERT_TIMEOUT), Ok(true))
    }

    /// Узел по адресу из FreeRDP: шлюз — по флагу, совпадение с настройками — цель, иначе — перенаправление.
    #[cfg_attr(not(feature = "rdp-freerdp"), allow(dead_code))]
    pub(crate) fn cert_node(&self, host: &str, port: u16, gateway: bool) -> CertNode {
        cert_node(&self.config, host, port, gateway)
    }

    #[cfg_attr(not(feature = "rdp-freerdp"), allow(dead_code))] // нужны движку FreeRDP
    pub(crate) fn config(&self) -> &RdpConfig {
        &self.config
    }
    #[cfg_attr(not(feature = "rdp-freerdp"), allow(dead_code))] // нужны движку FreeRDP
    pub(crate) fn listener(&self) -> &Arc<dyn RemoteListener> {
        &self.listener
    }
    #[cfg_attr(not(feature = "rdp-freerdp"), allow(dead_code))] // нужны движку FreeRDP
    pub(crate) fn clipboard_listener(&self) -> Option<Arc<dyn RemoteClipboardListener>> {
        self.clipboard.locked().clone()
    }
    #[cfg_attr(not(feature = "rdp-freerdp"), allow(dead_code))] // нужны движку FreeRDP
    pub(crate) fn audio_listener(&self) -> Option<Arc<dyn RemoteAudioListener>> {
        self.audio.locked().clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cert_trust_is_per_node() {
        let mut c = RdpConfig {
            host: String::new(),
            port: 0,
            user: "u".into(),
            password: String::new(),
            domain: None,
            width: 800,
            height: 600,
            scale_percent: 100,
            trusted_cert_sha256: None,
            trusted_certs: vec![],
            gateway_host: None,
            gateway_user: None,
            gateway_password: None,
            gateway_domain: None,
            h264_library_path: None,
        };
        c.host = "Win.Example.".into();
        c.port = 3389;
        c.trusted_cert_sha256 = Some("AA".into());
        c.trusted_certs = vec![TrustedCert { host: "gw.example".into(), port: 443, sha256: "bb".into() }];
        let target = cert_node(&c, "win.example", 3389, false);
        assert_eq!(target.role, CertRole::Target);
        assert!(cert_trusted(&c, &target, "aa"));
        // Старый слот цели не распространяется на шлюз и перенаправление.
        let gw = cert_node(&c, "GW.example", 443, true);
        assert_eq!((gw.role, gw.host.as_str()), (CertRole::Gateway, "gw.example"));
        assert!(cert_trusted(&c, &gw, "BB"));
        assert!(!cert_trusted(&c, &gw, "aa"));
        let redirect = cert_node(&c, "other.example", 3389, false);
        assert_eq!(redirect.role, CertRole::Redirect);
        assert!(!cert_trusted(&c, &redirect, "aa"));
        // Тот же хост, другой порт — другой узел.
        assert!(!cert_trusted(&c, &cert_node(&c, "gw.example", 3389, false), "bb"));
    }
}
