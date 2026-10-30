import SwiftUI
import RelayaCore

/// Окно встроенного VNC: экран удалённой машины, статус, ввод пароля.
struct VNCWindow: View {
    @Environment(AppModel.self) private var model
    let desktopID: RemoteDesktop.ID?
    @State private var session: VNCSession?

    var body: some View {
        Group {
            if let session {
                VNCContent(session: session)
            } else {
                Text("Подключение не найдено").foregroundStyle(Theme.tx2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .background(Color.black)
        .task {
            guard session == nil, let d = model.desktops.first(where: { $0.id == desktopID }) else { return }
            let s = VNCSession(desktop: d, model: model)
            session = s
            await s.connect()
        }
        .onDisappear { session?.disconnect() }
        .navigationTitle(session.map { $0.desktop.name.isEmpty ? $0.desktop.address : $0.desktop.name } ?? "VNC")
    }
}

private struct VNCContent: View {
    @Bindable var session: VNCSession
    @State private var username = ""
    @State private var password = ""
    @State private var save = true

    var body: some View {
        ZStack {
            if let view = session.framebufferView {
                HostedView(view: view)
            }
            switch session.phase {
            case .idle, .tunneling, .connecting:
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large)
                    Text(session.phase == .tunneling ? "Поднимаю SSH-туннель…" : "Подключаюсь к \(session.desktop.summary)…")
                        .foregroundStyle(.white.opacity(0.8))
                }
            case .connected:
                EmptyView()
            case .disconnected(let error):
                VStack(spacing: 12) {
                    Image(systemName: "display.trianglebadge.exclamationmark").font(.system(size: 36)).foregroundStyle(.white.opacity(0.7))
                    Text("Отключено").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                    if let error { Text(error).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center) }
                    Button("Подключить снова") { Task { await session.connect() } }.buttonStyle(.relayaPrimary)
                }
                .padding(24)
                .background(.ultraThinMaterial, in: .rect(cornerRadius: 16, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: Binding(get: { session.credentialRequest != nil }, set: { if !$0 { session.cancelCredentials() } })) {
            VStack(alignment: .leading, spacing: 12) {
                Text(session.credentialRequest?.isAppleRemoteDesktop == true
                     ? "Вход на Mac (Apple Remote Desktop)" : "Пароль VNC")
                    .font(.system(size: 15, weight: .bold))
                Text(session.desktop.summary).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.tx2)
                if session.credentialRequest?.needsUsername == true {
                    TextField("Пользователь", text: $username).textFieldStyle(.roundedBorder)
                }
                SecureField("Пароль", text: $password).textFieldStyle(.roundedBorder)
                    .onSubmit { session.provide(username: username, password: password, save: save) }
                if session.credentialRequest?.needsUsername == false {
                    Text("VNC учитывает только первые 8 символов пароля.")
                        .font(.system(size: 11)).foregroundStyle(Theme.tx2)
                }
                if let error = session.credentialError {
                    Text(error).font(.system(size: 12)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Сохранить в Keychain", isOn: $save)
                HStack {
                    Spacer()
                    Button("Отмена") { session.cancelCredentials() }.buttonStyle(.relaya).keyboardShortcut(.cancelAction)
                    Button("Войти") { session.provide(username: username, password: password, save: save) }
                        .buttonStyle(.relayaPrimary).keyboardShortcut(.defaultAction)
                        .disabled(password.isEmpty)
                }
            }
            .padding(20)
            .frame(width: 380)
            .onAppear { username = session.desktop.user }
        }
        .toolbar {
            ToolbarItem {
                Button { session.disconnect() } label: { Label("Отключить", systemImage: "xmark.circle") }
                    .disabled(session.phase != .connected)
            }
        }
    }
}

/// Встраивает готовый NSView (экран VNC) в SwiftUI.
private struct HostedView: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = [.width, .height]
        view.frame = container.bounds
        container.addSubview(view)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if view.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            view.frame = container.bounds
            container.addSubview(view)
        }
    }
}
