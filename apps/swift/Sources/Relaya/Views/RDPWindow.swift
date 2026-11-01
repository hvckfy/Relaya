import SwiftUI
import RelayaCore

/// Окно встроенного RDP: экран Windows, статус, ввод учётных данных.
struct RDPWindow: View {
    @Environment(AppModel.self) private var model
    let desktopID: RemoteDesktop.ID?
    @State private var session: RDPSession?

    var body: some View {
        Group {
            if let session {
                RDPContent(session: session)
            } else {
                Text(L("Подключение не найдено")).foregroundStyle(Theme.tx2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .background(Color.black)
        .task {
            guard session == nil, let d = model.desktops.first(where: { $0.id == desktopID }) else { return }
            let s = RDPSession(desktop: d, model: model)
            session = s
            // Даём окну разложиться: размер рабочего стола берётся из размера холста.
            try? await Task.sleep(for: .milliseconds(200))
            await s.start()
        }
        .onDisappear { session?.disconnect() }
        .navigationTitle(session.map { $0.desktop.name.isEmpty ? $0.desktop.address : $0.desktop.name } ?? "RDP")
    }
}

struct RDPContent: View {
    @Bindable var session: RDPSession
    @State private var user = ""
    @State private var password = ""
    @State private var save = true

    var body: some View {
        ZStack {
            CanvasHost(view: session.canvas)
            switch session.phase {
            case _ where session.trustPrompt != nil:
                trustCard
            case .idle, .tunneling, .connecting:
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large)
                    Text(session.phase == .tunneling ? L("Поднимаю SSH-туннель…") : L("Подключаюсь к %@…", "\(session.desktop.summary)"))
                        .foregroundStyle(.white.opacity(0.8))
                }
            case .connected:
                EmptyView()
            case .needsCredentials:
                credentialsForm
            case .disconnected(let error):
                VStack(spacing: 12) {
                    Image(systemName: "pc").font(.system(size: 36)).foregroundStyle(.white.opacity(0.7))
                    Text(L("Отключено")).font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                    if let error {
                        Text(error).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 460)
                    }
                    HStack {
                        Button(L("Подключить снова")) { Task { await session.start() } }.buttonStyle(.relayaPrimary)
                        if session.certificateMismatch {
                            Button(L("Сбросить доверие")) { session.forgetCertificate(); Task { await session.start() } }
                                .buttonStyle(.relaya)
                        }
                    }
                }
                .padding(24)
                // Непрозрачная карточка: материал (NSVisualEffectView) поверх холста гасил боковую панель и вкладки окна.
                // Текст на ней белый, как на чёрном экране стола, поэтому фон — тёмный в любой теме.
                .background(Color(white: 0.12), in: .rect(cornerRadius: 16, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem {
                if let cert = session.certificate {
                    Image(systemName: "lock.shield").help(L("Сертификат сервера SHA-256: %@", "\(cert)"))
                }
            }
            ToolbarItem {
                ResolutionMenu(session: session)
            }
            ToolbarItem {
                RDPSoundButton(session: session)
            }
            ToolbarItem {
                Toggle(isOn: $session.clipboardEnabled) {
                    Label(L("Общий буфер обмена"), systemImage: "doc.on.clipboard")
                }
                .toggleStyle(.button)
                .help(L("Общий буфер обмена с удалённым столом"))
            }
            ToolbarItem {
                Button { session.toggleFullScreen() } label: {
                    Label(L("Во весь экран"), systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .help(L("Во весь экран (⌃⌘F)"))
            }
            ToolbarItem {
                Menu {
                    Button(L("Ctrl+Alt+Del")) { session.sendCtrlAltDel() }
                    Button(L("Клавиша Windows")) { session.sendWindowsKey() }
                    Button(L("Alt+Tab")) { session.sendAltTab() }
                } label: { Label(L("Отправить сочетание"), systemImage: "keyboard") }
                .disabled(session.phase != .connected)
            }
            ToolbarItem {
                Button { session.disconnect() } label: { Label(L("Отключить"), systemImage: "xmark.circle") }
                    .disabled(session.phase != .connected && session.phase != .connecting)
            }
        }
        .onAppear { user = session.desktop.user }
    }

    /// Вопрос о сертификате — карточкой в окне стола, а не системным alert: alert на холсте в главном окне не
    /// появлялся на экране, но блокировал окно (пропадали боковая панель и вкладки), а без ответа подключение падало.
    private var trustCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Сертификат сервера")).font(.system(size: 15, weight: .bold))
            Text(session.trustPromptChanged
                 ? L("Сертификат %@ изменился с прошлого подключения. Доверяйте, только если сервер переустанавливали. Новый отпечаток (SHA-256):", session.desktop.summary)
                 : L("Первое подключение к %@. Сверьте отпечаток сертификата (SHA-256) с сервером:", session.desktop.summary))
                .fixedSize(horizontal: false, vertical: true)
            Text(session.trustPrompt ?? "").font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L("Доверять")) { session.answerTrust(true) }.buttonStyle(.relaya)
                // Return — «Отмена»: доверие сертификату не должно быть действием по умолчанию (HIG, чек-лист безопасности).
                Button(L("Отмена")) { session.answerTrust(false) }
                    .buttonStyle(.relayaPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(Theme.bg, in: .rect(cornerRadius: 16, style: .continuous))
    }

    private var credentialsForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Вход на %@", "\(session.desktop.name.isEmpty ? session.desktop.address : session.desktop.name)"))
                .font(.system(size: 15, weight: .bold))
            Text(session.desktop.summary).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.tx2)
            TextField(L("Пользователь (или DOMAIN\\user)"), text: $user).textFieldStyle(.roundedBorder)
            SecureField(L("Пароль (если есть)"), text: $password).textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            Toggle(L("Сохранить пароль в Keychain"), isOn: $save)
            HStack {
                Spacer()
                Button(L("Войти"), action: submit).buttonStyle(.relayaPrimary).keyboardShortcut(.defaultAction)
                    .disabled(user.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(Theme.bg, in: .rect(cornerRadius: 16, style: .continuous))
    }

    private func submit() {
        guard !user.isEmpty else { return }
        session.provide(user: user, password: password, save: save)
        password = ""
    }
}

/// Громкость звука стола (Е.18) — ползунок во всплывающей панели, как Sound flyout на Windows.
private struct RDPSoundButton: View {
    @Bindable var session: RDPSession
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Label(L("Звук"), systemImage: session.volume == 0 ? "speaker.slash" : "speaker.wave.2")
        }
        .help(L("Громкость звука удалённого стола"))
        .popover(isPresented: $shown) {
            HStack {
                Image(systemName: "speaker")
                Slider(value: $session.volume, in: 0...100)
                Image(systemName: "speaker.wave.3")
            }
            .padding()
            .frame(width: 240)
        }
    }
}

/// Встраивает холст RDP в SwiftUI.
private struct CanvasHost: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        view.autoresizingMask = [.width, .height]
        view.frame = container.bounds
        container.addSubview(view)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {}
}

/// Меню «Разрешение» в окне RDP: меняет рабочий стол Windows на лету, без переподключения.
private struct ResolutionMenu: View {
    let session: RDPSession

    var body: some View {
        Menu {
            Button {
                session.setResolution(nil)
            } label: {
                check(session.fixedSize == nil, L("По размеру окна"))
            }
            Divider()
            ForEach(RemoteDesktop.rdpResolutionPresets, id: \.0) { w, h in
                Button {
                    session.setResolution((w, h))
                } label: {
                    check(session.fixedSize.map { $0.width == w && $0.height == h } ?? false, "\(w) × \(h)")
                }
            }
            Divider()
            Button { session.setRetina(true) } label: { check(session.retina, L("Масштаб Retina — крупный интерфейс")) }
            Button { session.setRetina(false) } label: { check(!session.retina, L("Масштаб 100% — больше места")) }
        } label: {
            Label(L("Разрешение"), systemImage: "rectangle.dashed")
        }
        .help(session.canResize ? L("Разрешение и масштаб рабочего стола — меняются без переподключения")
                                : L("Сервер не поддерживает смену разрешения на лету — изменения применятся при следующем подключении"))
    }

    private func check(_ on: Bool, _ title: String) -> Text {
        Text((on ? "✓ " : "    ") + title)
    }
}
