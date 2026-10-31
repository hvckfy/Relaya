//! Встроенный RDP-клиент для Windows и Linux (feature `remote-desktop`; на Mac — RDPKit). Движок — IronRDP.
//! Поток на сессию: подключение, TLS с отпечатком для первого доверия, NLA/CredSSP, затем цикл «прочитать PDU →
//! отрисовать в буфер BGRA → отдать изменившиеся прямоугольники». Ввод и команды клиента копятся в очереди и
//! уходят в паузах между чтениями (короткий таймаут чтения), потоки FFI никогда не блокируются.

use std::io::Write as _;
use std::net::TcpStream;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use ironrdp::connector::connection_activation::ConnectionActivationState;
use ironrdp::connector::{self, ConnectorErrorKind, Credentials, Sequence as _};
use ironrdp::core::WriteBuf;
use ironrdp::graphics::image_processing::PixelFormat;
use ironrdp::input::{Database, MouseButton, MousePosition, Operation, Scancode, WheelRotations};
use ironrdp::pdu::gcc::KeyboardType;
use ironrdp::pdu::geometry::InclusiveRectangle;
use ironrdp::pdu::rdp::capability_sets::MajorPlatformType;
use ironrdp::pdu::rdp::client_info::{PerformanceFlags, TimezoneInfo};
use ironrdp::session::image::DecodedImage;
use ironrdp::session::{fast_path, ActiveStage, ActiveStageBuilder, ActiveStageOutput};

type Tls = rustls::StreamOwned<rustls::ClientConnection, TcpStream>;
type Framed = ironrdp_blocking::Framed<Tls>;

/// Сколько ждать решения пользователя об отпечатке сертификата.
const CERT_TIMEOUT: Duration = Duration::from_secs(120);
/// Пауза чтения в активной фазе: за это время уходят ввод и кадры.
const POLL: Duration = Duration::from_millis(8);
/// Не чаще ~60 кадров в секунду.
const FRAME_EVERY: Duration = Duration::from_millis(16);

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
    /// SHA-256 сертификата сервера (hex), которому пользователь уже доверился.
    pub trusted_cert_sha256: Option<String>,
}

/// Изменившийся прямоугольник экрана, пиксели BGRA построчно без отступов.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FrameRect { pub x: u16, pub y: u16, pub width: u16, pub height: u16, pub bgra: Vec<u8> }

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RemoteCloseKind { AuthFailed, Network, ServerClosed, CertRejected, Protocol, ClosedByUser }

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RemoteClose { pub kind: RemoteCloseKind, pub message: String }

/// События сессии — из потока сессии; клиент переносит их в UI-поток сам.
#[uniffi::export(with_foreign)]
pub trait RemoteListener: Send + Sync {
    /// Подключено, размер рабочего стола; следом придёт полный кадр.
    fn on_connected(&self, width: u16, height: u16);
    /// Изменившиеся прямоугольники.
    fn on_frame(&self, rects: Vec<FrameRect>);
    /// Сервер сменил размер рабочего стола (после resize или реактивации); следом — полный кадр.
    fn on_resize(&self, width: u16, height: u16);
    /// Сертификат не тот, которому доверились: ответ — `RemoteSession::accept_cert`. Без ответа — отказ.
    fn on_cert(&self, sha256: String, subject: String);
    fn on_closed(&self, close: RemoteClose);
}

enum Cmd {
    Input(Vec<Operation>),
    Resize(u16, u16),
    Disconnect,
}

#[derive(uniffi::Object)]
pub struct RemoteSession {
    config: RdpConfig,
    listener: Arc<dyn RemoteListener>,
    commands: Mutex<Option<Sender<Cmd>>>,
    cert_answer: Mutex<Option<Sender<bool>>>,
}

#[uniffi::export]
impl RemoteSession {
    #[uniffi::constructor]
    pub fn rdp(config: RdpConfig, listener: Arc<dyn RemoteListener>) -> Arc<Self> {
        Arc::new(RemoteSession { config, listener, commands: Mutex::new(None), cert_answer: Mutex::new(None) })
    }

    /// Запустить сессию в своём потоке. Повторный вызов ничего не делает.
    pub fn connect(self: Arc<Self>) {
        let mut slot = self.commands.lock().unwrap();
        if slot.is_some() { return; }
        let (tx, rx) = mpsc::channel();
        *slot = Some(tx);
        drop(slot);
        let me = self.clone();
        std::thread::Builder::new().name("relaya-rdp".into()).spawn(move || {
            let close = me.run(rx).err().unwrap_or(RemoteClose { kind: RemoteCloseKind::ClosedByUser, message: String::new() });
            me.listener.on_closed(close);
        }).ok();
    }

    /// Ответ на `on_cert`.
    pub fn accept_cert(&self, accept: bool) {
        if let Some(tx) = self.cert_answer.lock().unwrap().take() { let _ = tx.send(accept); }
    }

    /// Клавиша по scancode набора 1; расширенные — с префиксом 0xE0 (например 0xE04B — стрелка влево).
    pub fn key(&self, scancode: u16, down: bool) {
        let s = Scancode::from_u16(scancode);
        self.send(Cmd::Input(vec![if down { Operation::KeyPressed(s) } else { Operation::KeyReleased(s) }]));
    }

    /// Символ, которого нет в раскладке сервера (IME, эмодзи).
    pub fn unicode(&self, codepoint: u32, down: bool) {
        let Some(c) = char::from_u32(codepoint) else { return };
        self.send(Cmd::Input(vec![if down { Operation::UnicodeKeyPressed(c) } else { Operation::UnicodeKeyReleased(c) }]));
    }

    pub fn pointer(&self, x: u16, y: u16) { self.send(Cmd::Input(vec![Operation::MouseMove(MousePosition { x, y })])); }

    /// Кнопка мыши: 0 — левая, 1 — средняя, 2 — правая, 3 и 4 — «назад» и «вперёд».
    pub fn button(&self, button: u8, down: bool) {
        let b = match button { 0 => MouseButton::Left, 1 => MouseButton::Middle, 2 => MouseButton::Right, 3 => MouseButton::X1, 4 => MouseButton::X2, _ => return };
        self.send(Cmd::Input(vec![if down { Operation::MouseButtonPressed(b) } else { Operation::MouseButtonReleased(b) }]));
    }

    /// Колесо: `units` — как WHEEL_DELTA (120 на щелчок), положительное — вверх/вправо.
    pub fn wheel(&self, units: i16, vertical: bool) {
        self.send(Cmd::Input(vec![Operation::WheelRotations(WheelRotations { is_vertical: vertical, rotation_units: units })]));
    }

    /// Новый размер окна: через Display Control, если сервер его поддерживает.
    pub fn resize(&self, width: u16, height: u16) { self.send(Cmd::Resize(width, height)); }

    pub fn disconnect(&self) {
        self.send(Cmd::Disconnect);
        self.accept_cert(false);
    }
}

fn close(kind: RemoteCloseKind, message: impl ToString) -> RemoteClose { RemoteClose { kind, message: message.to_string() } }

fn connector_close(e: connector::ConnectorError) -> RemoteClose {
    let kind = match e.kind() {
        ConnectorErrorKind::Credssp(_) | ConnectorErrorKind::AccessDenied => RemoteCloseKind::AuthFailed,
        _ => RemoteCloseKind::Protocol,
    };
    close(kind, e)
}

fn sha256_hex(data: &[u8]) -> String {
    use sha2::Digest;
    sha2::Sha256::digest(data).iter().map(|b| format!("{b:02x}")).collect()
}

/// Прямоугольник изображения как плотные строки BGRA.
fn crop(image: &DecodedImage, r: &InclusiveRectangle) -> FrameRect {
    let (w, h) = (image.width(), image.height());
    let (left, top) = (r.left.min(w.saturating_sub(1)), r.top.min(h.saturating_sub(1)));
    let (right, bottom) = (r.right.min(w.saturating_sub(1)), r.bottom.min(h.saturating_sub(1)));
    let (cw, ch) = (right.saturating_sub(left) + 1, bottom.saturating_sub(top) + 1);
    let (stride, bpp) = (image.stride(), image.bytes_per_pixel());
    let data = image.data();
    let mut bgra = Vec::with_capacity(usize::from(cw) * usize::from(ch) * bpp);
    for row in top..=top + ch - 1 {
        let start = usize::from(row) * stride + usize::from(left) * bpp;
        bgra.extend_from_slice(&data[start..start + usize::from(cw) * bpp]);
    }
    FrameRect { x: left, y: top, width: cw, height: ch, bgra }
}

fn full(image: &DecodedImage) -> InclusiveRectangle {
    InclusiveRectangle { left: 0, top: 0, right: image.width().saturating_sub(1), bottom: image.height().saturating_sub(1) }
}

/// Объединить пересекающиеся и соседние прямоугольники, чтобы не гонять через FFI сотни мелких.
fn coalesce(mut rects: Vec<InclusiveRectangle>) -> Vec<InclusiveRectangle> {
    let touches = |a: &InclusiveRectangle, b: &InclusiveRectangle| {
        a.left <= b.right.saturating_add(1) && b.left <= a.right.saturating_add(1)
            && a.top <= b.bottom.saturating_add(1) && b.top <= a.bottom.saturating_add(1)
    };
    let mut out: Vec<InclusiveRectangle> = Vec::new();
    while let Some(mut r) = rects.pop() {
        let mut merged = true;
        while merged {
            merged = false;
            if let Some(i) = out.iter().position(|o| touches(o, &r)) {
                let o = out.swap_remove(i);
                r = InclusiveRectangle { left: r.left.min(o.left), top: r.top.min(o.top), right: r.right.max(o.right), bottom: r.bottom.max(o.bottom) };
                merged = true;
            }
        }
        out.push(r);
    }
    out
}

/// CredSSP без Kerberos: NTLM не ходит в сеть, а KDC мы не настраиваем.
struct NoNetwork;
impl ironrdp::connector::sspi::network_client::NetworkClient for NoNetwork {
    fn send(&self, _: &ironrdp::connector::sspi::generator::NetworkRequest) -> ironrdp::connector::sspi::Result<Vec<u8>> {
        Err(ironrdp::connector::sspi::Error::new(ironrdp::connector::sspi::ErrorKind::NoAuthenticatingAuthority, "Kerberos KDC is not configured"))
    }
}

impl RemoteSession {
    fn send(&self, cmd: Cmd) {
        if let Some(tx) = self.commands.lock().unwrap().as_ref() { let _ = tx.send(cmd); }
    }

    fn connector_config(&self) -> connector::Config {
        let c = &self.config;
        connector::Config {
            credentials: Credentials::UsernamePassword { username: c.user.clone(), password: c.password.clone() },
            domain: c.domain.clone().filter(|d| !d.is_empty()),
            enable_tls: true,
            enable_credssp: true,
            keyboard_type: KeyboardType::IbmEnhanced,
            keyboard_subtype: 0,
            keyboard_layout: 0,
            keyboard_functional_keys_count: 12,
            ime_file_name: String::new(),
            dig_product_id: String::new(),
            desktop_size: connector::DesktopSize { width: c.width.max(200), height: c.height.max(200) },
            bitmap: None,
            client_build: 0,
            client_name: "Relaya".to_owned(),
            client_dir: "C:\\Windows\\System32\\mstscax.dll".to_owned(),
            #[cfg(windows)]
            platform: MajorPlatformType::WINDOWS,
            #[cfg(target_os = "macos")]
            platform: MajorPlatformType::MACINTOSH,
            #[cfg(not(any(windows, target_os = "macos")))]
            platform: MajorPlatformType::UNIX,
            enable_server_pointer: true,
            request_data: None,
            autologon: false,
            enable_audio_playback: false,
            compression_type: None,
            pointer_software_rendering: true,
            multitransport_flags: None,
            performance_flags: PerformanceFlags::default(),
            desktop_scale_factor: if c.scale_percent > 100 { c.scale_percent } else { 0 },
            hardware_id: None,
            license_cache: None,
            timezone_info: TimezoneInfo::default(),
            alternate_shell: String::new(),
            work_dir: String::new(),
        }
    }

    /// TLS без проверки цепочки: доверие — по отпечатку, как в mstsc. Отпечаток не совпал — спросить пользователя.
    fn tls(&self, stream: TcpStream) -> Result<(Tls, Vec<u8>), RemoteClose> {
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let mut config = rustls::ClientConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions().map_err(|e| close(RemoteCloseKind::Protocol, e))?
            .dangerous().with_custom_certificate_verifier(Arc::new(danger::AcceptAny))
            .with_no_client_auth();
        // CredSSP не поддерживает возобновление TLS-сессии.
        config.resumption = rustls::client::Resumption::disabled();
        let name = rustls::pki_types::ServerName::try_from(self.config.host.clone())
            .map_err(|e| close(RemoteCloseKind::Network, e))?;
        let conn = rustls::ClientConnection::new(Arc::new(config), name).map_err(|e| close(RemoteCloseKind::Protocol, e))?;
        let mut tls = rustls::StreamOwned::new(conn, stream);
        tls.flush().map_err(|e| close(RemoteCloseKind::Network, e))?;
        let cert = tls.conn.peer_certificates().and_then(|c| c.first()).map(|c| c.as_ref().to_vec())
            .ok_or_else(|| close(RemoteCloseKind::Protocol, "server sent no certificate"))?;

        use x509_cert::der::Decode as _;
        let parsed = x509_cert::Certificate::from_der(&cert).map_err(|e| close(RemoteCloseKind::Protocol, e))?;
        let public_key = parsed.tbs_certificate.subject_public_key_info.subject_public_key.as_bytes()
            .ok_or_else(|| close(RemoteCloseKind::Protocol, "bad server public key"))?.to_vec();

        let sha = sha256_hex(&cert);
        if self.config.trusted_cert_sha256.as_deref().map(|t| t.eq_ignore_ascii_case(&sha)) != Some(true) {
            let (tx, rx) = mpsc::channel();
            *self.cert_answer.lock().unwrap() = Some(tx);
            self.listener.on_cert(sha, parsed.tbs_certificate.subject.to_string());
            match rx.recv_timeout(CERT_TIMEOUT) {
                Ok(true) => {}
                Ok(false) | Err(RecvTimeoutError::Timeout) | Err(RecvTimeoutError::Disconnected) => {
                    return Err(close(RemoteCloseKind::CertRejected, "certificate not accepted"));
                }
            }
        }
        Ok((tls, public_key))
    }

    fn run(&self, commands: Receiver<Cmd>) -> Result<(), RemoteClose> {
        use std::net::ToSocketAddrs as _;
        let c = &self.config;
        let addr = (c.host.as_str(), c.port).to_socket_addrs().map_err(|e| close(RemoteCloseKind::Network, e))?
            .next().ok_or_else(|| close(RemoteCloseKind::Network, "address not found"))?;
        let tcp = TcpStream::connect_timeout(&addr, Duration::from_secs(15)).map_err(|e| close(RemoteCloseKind::Network, e))?;
        tcp.set_read_timeout(Some(Duration::from_secs(30))).ok();
        let client_addr = tcp.local_addr().map_err(|e| close(RemoteCloseKind::Network, e))?;

        let drdynvc = ironrdp::dvc::DrdynvcClient::new()
            .with_dynamic_channel(ironrdp::displaycontrol::client::DisplayControlClient::new(|_| Ok(Vec::new())));
        let mut connector = connector::ClientConnector::new(self.connector_config(), client_addr).with_static_channel(drdynvc);

        let mut framed = ironrdp_blocking::Framed::new(tcp);
        let should_upgrade = ironrdp_blocking::connect_begin(&mut framed, &mut connector).map_err(connector_close)?;
        let (tls, public_key) = self.tls(framed.into_inner_no_leftover())?;
        let upgraded = ironrdp_blocking::mark_as_upgraded(should_upgrade, &mut connector);
        let mut framed = ironrdp_blocking::Framed::new(tls);
        let result = ironrdp_blocking::connect_finalize(upgraded, connector, &mut framed, &mut NoNetwork,
                                                        c.host.clone().into(), public_key, None).map_err(connector_close)?;

        let mut image = DecodedImage::new(PixelFormat::BgrA32, result.desktop_size.width, result.desktop_size.height);
        let activation = result.activation_factory;
        let mut stage = ActiveStageBuilder {
            static_channels: result.static_channels,
            user_channel_id: result.user_channel_id,
            io_channel_id: result.io_channel_id,
            message_channel_id: result.message_channel_id,
            share_id: result.share_id,
            compression_type: result.compression_type,
            enable_server_pointer: result.enable_server_pointer,
            pointer_software_rendering: result.pointer_software_rendering,
        }.build();
        self.listener.on_connected(image.width(), image.height());
        self.listener.on_frame(vec![crop(&image, &full(&image))]);

        framed.get_inner_mut().0.get_mut().set_read_timeout(Some(POLL)).ok();
        let mut input = Database::new();
        let mut dirty: Vec<InclusiveRectangle> = Vec::new();
        let mut last_frame = Instant::now();
        let net = |e: std::io::Error| close(RemoteCloseKind::Network, e);
        let proto = |e: ironrdp::session::SessionError| close(RemoteCloseKind::Protocol, e);

        loop {
            let mut outputs = Vec::new();
            while let Ok(cmd) = commands.try_recv() {
                match cmd {
                    Cmd::Input(ops) => {
                        let events = input.apply(ops);
                        outputs.extend(stage.process_fastpath_input(&mut image, &events).map_err(proto)?);
                    }
                    Cmd::Resize(w, h) => {
                        let (w, h) = ironrdp::displaycontrol::pdu::MonitorLayoutEntry::adjust_display_size(u32::from(w), u32::from(h));
                        let scale = (c.scale_percent > 100).then_some(c.scale_percent);
                        if let Some(frame) = stage.encode_resize(w, h, scale, None) { framed.write_all(&frame.map_err(proto)?).map_err(net)?; }
                    }
                    Cmd::Disconnect => {
                        for out in stage.graceful_shutdown().map_err(proto)? {
                            if let ActiveStageOutput::ResponseFrame(f) = out { let _ = framed.write_all(&f); }
                        }
                        return Ok(());
                    }
                }
            }
            match framed.read_pdu() {
                Ok((action, payload)) => outputs.extend(stage.process(&mut image, action, &payload).map_err(proto)?),
                Err(e) if matches!(e.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut) => {}
                Err(e) => return Err(net(e)),
            }
            for out in outputs {
                match out {
                    ActiveStageOutput::ResponseFrame(f) => framed.write_all(&f).map_err(net)?,
                    ActiveStageOutput::GraphicsUpdate(r) => dirty.push(r),
                    ActiveStageOutput::Terminate(reason) => return Err(close(RemoteCloseKind::ServerClosed, reason.description())),
                    ActiveStageOutput::DeactivateAll => {
                        self.reactivate(&mut framed, &activation, &mut stage, &mut image)?;
                        dirty.clear();
                        dirty.push(full(&image));
                    }
                    _ => {}
                }
            }
            if !dirty.is_empty() && last_frame.elapsed() >= FRAME_EVERY {
                let rects = coalesce(std::mem::take(&mut dirty)).iter().map(|r| crop(&image, r)).collect();
                self.listener.on_frame(rects);
                last_frame = Instant::now();
            }
        }
    }

    /// Server Deactivate All: заново пройти активацию и пересоздать буфер под новый размер.
    fn reactivate(&self, framed: &mut Framed, factory: &connector::connection_activation::ConnectionActivationFactory, stage: &mut ActiveStage,
                  image: &mut DecodedImage) -> Result<(), RemoteClose> {
        let mut seq = factory.create();
        let mut buf = WriteBuf::new();
        let net = |e: std::io::Error| close(RemoteCloseKind::Network, e);
        loop {
            if let ConnectionActivationState::Finalized { desktop_size, share_id, enable_server_pointer, pointer_software_rendering } =
                seq.connection_activation_state()
            {
                *image = DecodedImage::new(PixelFormat::BgrA32, desktop_size.width, desktop_size.height);
                stage.set_fastpath_processor(fast_path::ProcessorBuilder {
                    io_channel_id: seq.io_channel_id(),
                    user_channel_id: seq.user_channel_id(),
                    share_id,
                    enable_server_pointer,
                    pointer_software_rendering,
                    bulk_decompressor: None,
                }.build());
                stage.set_share_id(share_id);
                stage.set_enable_server_pointer(enable_server_pointer);
                self.listener.on_resize(image.width(), image.height());
                return Ok(());
            }
            buf.clear();
            let written = match seq.next_pdu_hint() {
                Some(hint) => {
                    let pdu = loop {
                        match framed.read_by_hint(hint) {
                            Ok(p) => break p,
                            Err(e) if matches!(e.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut) => continue,
                            Err(e) => return Err(net(e)),
                        }
                    };
                    seq.step(&pdu, &mut buf).map_err(connector_close)?
                }
                None => seq.step_no_input(&mut buf).map_err(connector_close)?,
            };
            if let Some(n) = written.size() { framed.write_all(&buf[..n]).map_err(net)?; }
        }
    }
}

mod danger {
    use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
    use rustls::{pki_types, DigitallySignedStruct, Error, SignatureScheme};

    /// Сертификат проверяется отпечатком после рукопожатия (первое доверие), а не цепочкой.
    #[derive(Debug)]
    pub(super) struct AcceptAny;

    impl ServerCertVerifier for AcceptAny {
        fn verify_server_cert(&self, _: &pki_types::CertificateDer<'_>, _: &[pki_types::CertificateDer<'_>],
                              _: &pki_types::ServerName<'_>, _: &[u8], _: pki_types::UnixTime) -> Result<ServerCertVerified, Error> {
            Ok(ServerCertVerified::assertion())
        }
        fn verify_tls12_signature(&self, _: &[u8], _: &pki_types::CertificateDer<'_>, _: &DigitallySignedStruct)
            -> Result<HandshakeSignatureValid, Error> { Ok(HandshakeSignatureValid::assertion()) }
        fn verify_tls13_signature(&self, _: &[u8], _: &pki_types::CertificateDer<'_>, _: &DigitallySignedStruct)
            -> Result<HandshakeSignatureValid, Error> { Ok(HandshakeSignatureValid::assertion()) }
        fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
            rustls::crypto::ring::default_provider().signature_verification_algorithms.supported_schemes()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn r(l: u16, t: u16, rt: u16, b: u16) -> InclusiveRectangle { InclusiveRectangle { left: l, top: t, right: rt, bottom: b } }

    #[test]
    fn coalesces_touching_rects_only() {
        let mut out = coalesce(vec![r(0, 0, 9, 9), r(10, 0, 19, 9), r(100, 100, 109, 109)]);
        out.sort_by_key(|x| x.left);
        assert_eq!(out.len(), 2);
        assert_eq!((out[0].left, out[0].right), (0, 19));
    }

    #[test]
    fn crops_bgra_rows() {
        let image = DecodedImage::new(PixelFormat::BgrA32, 4, 3);
        let f = crop(&image, &r(1, 1, 2, 2));
        assert_eq!((f.x, f.y, f.width, f.height, f.bgra.len()), (1, 1, 2, 2, 16));
        // За пределами изображения — обрезается, а не падает.
        let edge = crop(&image, &r(3, 2, 50, 50));
        assert_eq!((edge.width, edge.height), (1, 1));
    }

    #[test]
    fn session_without_server_reports_network_error() {
        struct L(Mutex<Option<RemoteClose>>);
        impl RemoteListener for L {
            fn on_connected(&self, _: u16, _: u16) {}
            fn on_frame(&self, _: Vec<FrameRect>) {}
            fn on_resize(&self, _: u16, _: u16) {}
            fn on_cert(&self, _: String, _: String) {}
            fn on_closed(&self, c: RemoteClose) { *self.0.lock().unwrap() = Some(c); }
        }
        let l = Arc::new(L(Mutex::new(None)));
        let cfg = RdpConfig { host: "127.0.0.1".into(), port: 1, user: "u".into(), password: "p".into(), domain: None,
                              width: 800, height: 600, scale_percent: 100, trusted_cert_sha256: None };
        RemoteSession::rdp(cfg, l.clone()).connect();
        let start = Instant::now();
        while l.0.lock().unwrap().is_none() && start.elapsed() < Duration::from_secs(20) { std::thread::sleep(Duration::from_millis(50)); }
        assert_eq!(l.0.lock().unwrap().as_ref().map(|c| c.kind), Some(RemoteCloseKind::Network));
    }
}
