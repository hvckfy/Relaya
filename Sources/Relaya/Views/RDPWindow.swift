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

private struct RDPContent: View {
    @Bindable var session: RDPSession
    @State private var user = ""
    @State private var password = ""
    @State private var save = true

    var body: some View {
        ZStack {
            CanvasHost(view: session.canvas)
            switch session.phase {
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
                .background(.ultraThinMaterial, in: .rect(cornerRadius: 16, style: .continuous))
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
                Button { session.disconnect() } label: { Label(L("Отключить"), systemImage: "xmark.circle") }
                    .disabled(session.phase != .connected && session.phase != .connecting)
            }
        }
        .onAppear { user = session.desktop.user }
    }

    private var credentialsForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Вход на %@", "\(session.desktop.name.isEmpty ? session.desktop.address : session.desktop.name)"))
                .font(.system(size: 15, weight: .bold))
            Text(session.desktop.summary).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.tx2)
            TextField(L("Пользователь (или DOMAIN\\user)"), text: $user).textFieldStyle(.roundedBorder)
            SecureField(L("Пароль"), text: $password).textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            Toggle(L("Сохранить пароль в Keychain"), isOn: $save)
            HStack {
                Spacer()
                Button(L("Войти"), action: submit).buttonStyle(.relayaPrimary).keyboardShortcut(.defaultAction)
                    .disabled(user.isEmpty || password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(Theme.bg, in: .rect(cornerRadius: 16, style: .continuous))
    }

    private func submit() {
        guard !user.isEmpty, !password.isEmpty else { return }
        session.provide(user: user, password: password, save: save)
        password = ""
    }
}

/// Встраивает холст RDPeek в SwiftUI.
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
