import SwiftUI
import RelayaCore

/// Сессия: хлебные крошки · баннеры · терминал · статус-бар.
struct SessionView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    let session: Session

    private var c: SessionController { session.controller }

    var body: some View {
        VStack(spacing: 0) {
            breadcrumbs
            SessionBanners(controller: c, host: session.host)
            TerminalView(controller: c)
                .id("\(session.id)-\(c.generation)")
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(nsColor: settings.theme.backgroundColor))
                .overlay { if c.ended { EndedOverlay(controller: c) } }
            statusBar
        }
    }

    private var breadcrumbs: some View {
        let host = model.current(session.host)
        return HStack(spacing: 6) {
            OSIcon(os: host.os, size: 16)
            if let group = session.host.group {
                Text(group)
                Text("›").accessibilityHidden(true)
            }
            Text(session.host.alias).fontWeight(.semibold).foregroundStyle(Theme.tx)
            Spacer()
            OSActionsMenu(os: host.os, user: host.user) { c.insert($0) }
            Button(L("Сниппеты")) { model.snippetPalette = true }
                .buttonStyle(.relaya(.ghost, height: 24))
                .help(L("Вставить сохранённую команду (⇧⌘P)"))
            Button("SFTP") { model.sftpHost = host }
                .buttonStyle(.relaya(.ghost, height: 24))
                .help(L("Файлы на сервере"))
            Button(L("Найти")) { c.showFind() }
                .buttonStyle(.relaya(.ghost, height: 24))
                .help(L("Поиск в терминале (⌘F)"))
            Button(L("Изменить хост")) { model.editor = EditorRequest(original: session.host) }
                .buttonStyle(.relaya(.ghost, height: 24))
            if !session.host.usesKey {
                Button(L("Вход по ключу…")) { model.keyWizard = KeyWizardRequest(host: session.host) }
                    .buttonStyle(.relaya(.ghost, height: 24))
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.tx2)
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(height: 32)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line2).frame(height: 0.5) }
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            Text(session.host.subtitle)
            if session.host.usesKey {
                Text(L("ключ")).foregroundStyle(Theme.grn)
            } else if model.keychain.hasPassword(for: session.host.keychainAccount) {
                Text(L("пароль · Keychain")).foregroundStyle(Theme.org)
            } else {
                Text(L("пароль")).foregroundStyle(Theme.org)
            }
            Spacer()
            if c.ended { Text(L("отключён")).foregroundStyle(Theme.red) }
            Text("UTF-8")
            Text("xterm-256color")
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(Theme.tx2)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(Theme.bar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 0.5) }
    }
}

/// Баннеры над терминалом: отпечаток сервера, пароль, предложение ключа.
private struct SessionBanners: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Bindable var controller: SessionController
    let host: SSHHost
    @State private var askPassword = false

    var body: some View {
        VStack(spacing: 6) {
            if controller.hostKeyChanged {
                BannerRow(tint: Theme.redTint, border: Theme.red) {
                    Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(Theme.red)
                    Text(L("Ключ сервера изменился! Это может быть атака «человек посередине». ssh не подключится, пока вы не проверите сервер и не удалите старую запись из ~/.ssh/known_hosts."))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if controller.passwordOnly {
                BannerRow(tint: Theme.accTint, border: Theme.line) {
                    Image(systemName: "key.slash").foregroundStyle(Theme.acc)
                    Text(L("Сервер оборвал вход после перебора ключей из ssh-agent — переподключились сразу по паролю. Настройте вход по ключу, чтобы так не было."))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let fp = controller.hostKeyPrompt {
                BannerRow(tint: Theme.orgTint, border: Theme.org) {
                    Image(systemName: "checkmark.shield").foregroundStyle(Theme.org)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Первое подключение к %@. Сверьте отпечаток с сервером:", "\(host.hostName ?? host.alias)"))
                        Text(fp).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    }
                    Spacer()
                    Button(L("Доверять")) { controller.answerHostKey(trust: true) }
                        .buttonStyle(.relaya(.primary, height: 24))
                    Button(L("Отмена")) { controller.answerHostKey(trust: false) }
                        .buttonStyle(.relaya(.normal, height: 24))
                }
            }
            if controller.savedPasswordRejected {
                BannerRow(tint: Theme.redTint, border: Theme.line) {
                    Text(L("Сохранённый в Keychain пароль не подошёл."))
                    Spacer()
                    Button(L("Ввести новый…")) { askPassword = true }.buttonStyle(.relaya(.primary, height: 24))
                }
            } else if controller.passwordPromptWithoutSaved {
                BannerRow(tint: Theme.accTint, border: Theme.line) {
                    Text(L("Сервер спрашивает пароль. Введите его здесь — Relaya сохранит его в Keychain и будет подставлять сама."))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(L("Ввести и сохранить…")) { askPassword = true }.buttonStyle(.relaya(.primary, height: 24))
                    Button(L("Не сейчас")) { controller.passwordPromptWithoutSaved = false }
                        .buttonStyle(.relaya(.normal, height: 24))
                }
            }
            if controller.offerKeySetup, settings.offerKeySetup {
                BannerRow(tint: Theme.accTint, border: Theme.line) {
                    Text(L("Вы вошли по паролю. Настроить вход по ключу?"))
                    Spacer()
                    Button(L("Настроить")) {
                        controller.offerKeySetup = false
                        model.keyWizard = KeyWizardRequest(host: host)
                    }
                    .buttonStyle(.relaya(.primary, height: 24))
                    Button(L("Не сейчас")) { controller.offerKeySetup = false }
                        .buttonStyle(.relaya(.normal, height: 24))
                    Button(L("Больше не предлагать")) {
                        controller.offerKeySetup = false
                        settings.offerKeySetup = false
                    }
                    .buttonStyle(.relaya(.ghost, height: 24))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, anyVisible ? 10 : 0)
        .padding(.bottom, anyVisible ? 4 : 0)
        .sheet(isPresented: $askPassword) {
            PasswordSheet(title: L("Пароль для %@", "\(host.subtitle)")) { password, save in
                try controller.submitPassword(password, save: save)
            }
        }
    }

    private var anyVisible: Bool {
        controller.passwordOnly || controller.hostKeyChanged || controller.hostKeyPrompt != nil || controller.savedPasswordRejected
            || controller.passwordPromptWithoutSaved || (controller.offerKeySetup && settings.offerKeySetup)
    }
}

struct BannerRow<Content: View>: View {
    let tint: Color
    let border: Color
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 10) { content }
            .font(.system(size: 13))
            .foregroundStyle(Theme.tx)
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
            .background(tint, in: .rect(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(border, lineWidth: 0.5))
    }
}

/// Ввод секрета в защищённое поле вместо терминала.
struct PasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    var saveLabel = L("Сохранить в Keychain")
    let submit: (String, Bool) throws -> Void
    @State private var password = ""
    @State private var save = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 15, weight: .bold))
            SecureField(L("Пароль"), text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(send)
            Toggle(saveLabel, isOn: $save)
            if let error { Text(error).foregroundStyle(Theme.red).font(.system(size: 12)) }
            HStack {
                Spacer()
                Button(L("Отмена")) { dismiss() }.buttonStyle(.relaya).keyboardShortcut(.cancelAction)
                Button(L("Готово")) { send() }.buttonStyle(.relayaPrimary).keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .background(Theme.bg)
    }

    private func send() {
        guard !password.isEmpty else { return }
        do {
            try submit(password, save)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Поверх терминала после разрыва: код выхода, обратный отсчёт, «Переподключить».
private struct EndedOverlay: View {
    @Environment(AppModel.self) private var model
    let controller: SessionController

    var body: some View {
        VStack(spacing: 10) {
            Text(title).font(.system(size: 15, weight: .bold))
            if let left = controller.reconnectIn {
                Text(L("Переподключение через %@ с…", "\(left)")).foregroundStyle(Theme.tx2)
            }
            HStack(spacing: 8) {
                Button(L("Переподключить")) { controller.reconnect() }
                    .buttonStyle(.relayaPrimary)
                if controller.reconnectIn != nil {
                    Button(L("Отменить")) { controller.cancelReconnect() }.buttonStyle(.relaya)
                } else {
                    Button(L("Изменить хост")) { model.editor = EditorRequest(original: controller.host) }
                        .buttonStyle(.relaya)
                }
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.tx)
        .padding(20)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 12, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.15))
    }

    private var title: String {
        switch controller.exitCode {
        case 0: L("Сессия завершена")
        case 255: L("Соединение потеряно")
        case let code?: L("ssh завершился с кодом %@", "\(code)")
        case nil: L("Сессия завершена")
        }
    }
}
