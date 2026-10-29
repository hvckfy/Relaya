import SwiftUI
import RelayaCore

/// Редактор хоста (docs/design/HostEditor, UI_SPEC 3.4). Пишет прямо в ~/.ssh/config.
struct HostEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let original: SSHHost?
    @State private var host: SSHHost
    @State private var portText: String
    @State private var keepAliveText: String
    @State private var error: String?
    @State private var showPreview = true

    init(original: SSHHost?, draft: SSHHost) {
        self.original = original
        _host = State(initialValue: draft)
        _portText = State(initialValue: draft.port.map(String.init) ?? "22")
        _keepAliveText = State(initialValue: draft.serverAliveInterval.map(String.init) ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let block = existingBlock, block.isShared {
                        Banner(text: "Хост объявлен вместе с другими алиасами (Host a b). Чтобы не разорвать блок, отредактируйте ~/.ssh/config вручную.",
                               color: Theme.org, tint: Theme.orgTint)
                    }
                    basics
                    auth
                    network
                    preview
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 14)
            }
            footer
        }
        .frame(width: 640, height: 760)
        .background(Theme.bg)
    }

    // MARK: - Разделы

    private var header: some View {
        HStack(spacing: 12) {
            Text(original == nil ? "Новый хост" : "Изменить хост")
                .font(.system(size: 17, weight: .bold))
            Spacer()
            Picker("Протокол", selection: .constant("SSH")) {
                Text("SSH").tag("SSH")
                Text("VNC").tag("VNC")
                Text("RDP").tag("RDP")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 170)
            .disabled(true)
            .help("VNC и RDP появятся в v0.3–v0.4")
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var basics: some View {
        FormGroup(title: "Основное") {
            FieldRow("Алиас (Host)") {
                MonoField(text: $host.alias, placeholder: "staging-web", width: 300)
            }
            FieldRow("Адрес (HostName)") {
                MonoField(text: optional(\.hostName), placeholder: "staging.example.com", width: 300)
            }
            FieldRow("Порт") {
                MonoField(text: $portText, placeholder: "22", width: 80)
            }
            FieldRow("Пользователь") {
                MonoField(text: optional(\.user), placeholder: "ubuntu", width: 300)
            }
            FieldRow("Группа") {
                HStack(spacing: 4) {
                    MonoField(text: optional(\.group), placeholder: "без группы", width: 270)
                    Menu {
                        ForEach(model.groups, id: \.self) { g in
                            Button(g) { host.group = g }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 26)
                    .disabled(model.groups.isEmpty)
                }
            }
            FieldRow("Окружение") {
                HStack(spacing: 6) {
                    EnvChip(label: "нет", color: Theme.tx2, tint: Theme.sel, selected: host.environment == nil) {
                        host.environment = nil
                    }
                    ForEach(HostEnvironment.allCases, id: \.self) { env in
                        EnvChip(label: env.rawValue, color: env.color, tint: env.tint, selected: host.environment == env) {
                            host.environment = env
                        }
                    }
                }
            }
            FieldRow("Цвет", last: true) {
                HStack(spacing: 8) {
                    ColorDot(color: nil, label: "Без цвета", selected: host.color == nil) { host.color = nil }
                    ForEach(Theme.hostColors, id: \.name) { c in
                        ColorDot(color: c.color, label: c.label, selected: host.color == c.name) { host.color = c.name }
                    }
                }
            }
        }
    }

    private var auth: some View {
        FormGroup(title: "Аутентификация") {
            FieldRow("Ключ") {
                Picker("Ключ", selection: optional(\.identityFile)) {
                    Text("по умолчанию / пароль").tag("")
                    ForEach(keyFiles, id: \.self) { Text($0).tag($0) }
                    if let f = host.identityFile, !f.isEmpty, !keyFiles.contains(f) { Text(f).tag(f) }
                }
                .labelsHidden()
                .frame(width: 300)
            }
            FieldRow("Пароль") {
                Text("ssh спросит его в терминале · Keychain — в v0.1")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tx2)
            }
            FieldRow("Агент-форвардинг", last: true) {
                Toggle("", isOn: flag(\.forwardAgent)).labelsHidden().toggleStyle(.checkbox)
            }
        }
    }

    private var network: some View {
        FormGroup(title: "Сеть") {
            FieldRow("ProxyJump") {
                Picker("ProxyJump", selection: optional(\.proxyJump)) {
                    Text("нет").tag("")
                    ForEach(model.hosts.filter { $0.alias != original?.alias }) { h in
                        Text("\(h.alias) (\(h.subtitle))").tag(h.alias)
                    }
                    if let j = host.proxyJump, !j.isEmpty, !model.hosts.contains(where: { $0.alias == j }) {
                        Text(j).tag(j)
                    }
                }
                .labelsHidden()
                .frame(width: 300)
            }
            FieldRow("Keepalive") {
                HStack(spacing: 6) {
                    MonoField(text: $keepAliveText, placeholder: "—", width: 60)
                    Text("сек").font(.system(size: 12)).foregroundStyle(Theme.tx2)
                }
            }
            FieldRow("Сжатие", last: true) {
                Toggle("", isOn: flag(\.compression)).labelsHidden().toggleStyle(.checkbox)
            }
        }
    }

    private var preview: some View {
        let lines = diffLines
        let added = lines.filter { $0.kind == .added }.count
        let removed = lines.filter { $0.kind == .removed }.count
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                showPreview.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: showPreview ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Превью ~/.ssh/config").fontWeight(.bold)
                    Spacer()
                    if added > 0 { Text("+\(added)").foregroundStyle(Theme.grn) }
                    if removed > 0 { Text("−\(removed)").foregroundStyle(Theme.red) }
                    if added + removed == 0 { Text("без изменений").foregroundStyle(Theme.tx2) }
                }
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.tx)

            if showPreview {
                Divider().overlay(Theme.line2)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        DiffRow(line: line)
                    }
                }
                .padding(.vertical, 6)
                .textSelection(.enabled)
            }
        }
        .background(Theme.bg2, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, lineWidth: 0.5))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.red)
                    .lineLimit(2)
            } else {
                Text(locationText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.tx2)
            }
            Spacer()
            Button("Отмена") { dismiss() }
                .buttonStyle(.relaya)
                .keyboardShortcut(.cancelAction)
            Button("Сохранить") { save() }
                .buttonStyle(.relayaPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(validationError != nil || existingBlock?.isShared == true)
                .help(validationError ?? "")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .overlay(alignment: .top) { Divider().overlay(Theme.line) }
    }

    // MARK: - Данные

    private var document: SSHConfigDocument? { try? model.store.loadDocument() }

    private var existingBlock: SSHConfigDocument.Block? {
        guard let original else { return nil }
        return document?.block(for: original.alias)
    }

    private var locationText: String {
        if let block = existingBlock { return "~/.ssh/config : строка \(block.hostLine + 1)" }
        return "~/.ssh/config : в конец файла"
    }

    /// Хост из полей формы в том виде, в каком он попадёт в конфиг.
    private var normalized: SSHHost {
        var h = host
        func clean(_ s: String?) -> String? {
            let t = s?.trimmingCharacters(in: .whitespaces) ?? ""
            return t.isEmpty ? nil : t
        }
        h.alias = h.alias.trimmingCharacters(in: .whitespaces)
        h.hostName = clean(h.hostName)
        h.user = clean(h.user)
        h.group = clean(h.group)
        h.identityFile = clean(h.identityFile)
        h.proxyJump = clean(h.proxyJump)
        let port = Int(portText.trimmingCharacters(in: .whitespaces))
        h.port = port == 22 ? nil : port
        h.serverAliveInterval = Int(keepAliveText.trimmingCharacters(in: .whitespaces))
        if h.forwardAgent == false { h.forwardAgent = nil }
        if h.compression == false { h.compression = nil }
        return h
    }

    private var validationError: String? {
        let h = normalized
        if h.alias.isEmpty { return "Укажите алиас" }
        if h.alias.contains(where: \.isWhitespace) || SSHConfigParser.isPattern(h.alias) {
            return "Алиас без пробелов и символов * ? !"
        }
        if h.alias != original?.alias, model.hosts.contains(where: { $0.alias == h.alias }) {
            return "Хост «\(h.alias)» уже есть"
        }
        let p = portText.trimmingCharacters(in: .whitespaces)
        if !p.isEmpty, !(1...65535).contains(Int(p) ?? 0) { return "Порт — число от 1 до 65535" }
        let k = keepAliveText.trimmingCharacters(in: .whitespaces)
        if !k.isEmpty, (Int(k) ?? -1) < 0 { return "Keepalive — число секунд" }
        return nil
    }

    private var diffLines: [LineDiff.Line] {
        guard let doc = document else { return [] }
        let old = original.map { doc.currentLines(for: $0.alias) } ?? []
        let new = doc.renderedLines(for: normalized, replacing: original?.alias)
        return LineDiff.diff(old, new)
    }

    /// Файлы приватных ключей в ~/.ssh — те, у которых рядом лежит `.pub`.
    private var keyFiles: [String] {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names
            .filter { names.contains($0 + ".pub") }
            .sorted()
            .map { "~/.ssh/\($0)" }
    }

    private func save() {
        do {
            try model.save(normalized, originalAlias: original?.alias)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Привязки к опциональным полям

    private func optional(_ keyPath: WritableKeyPath<SSHHost, String?>) -> Binding<String> {
        Binding(get: { host[keyPath: keyPath] ?? "" }, set: { host[keyPath: keyPath] = $0 })
    }

    private func flag(_ keyPath: WritableKeyPath<SSHHost, Bool?>) -> Binding<Bool> {
        Binding(get: { host[keyPath: keyPath] ?? false }, set: { host[keyPath: keyPath] = $0 })
    }
}

// MARK: - Элементы формы из макета

private struct FormGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.tx2)
                .padding(.leading, 4)
            VStack(spacing: 0) { content }
                .background(Theme.bg2, in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, lineWidth: 0.5))
        }
    }
}

private struct FieldRow<Content: View>: View {
    let label: String
    var last = false
    @ViewBuilder let content: Content

    init(_ label: String, last: Bool = false, @ViewBuilder content: () -> Content) {
        self.label = label
        self.last = last
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Theme.tx)
            Spacer(minLength: 12)
            content
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
        .overlay(alignment: .bottom) {
            if !last { Divider().overlay(Theme.line2).padding(.leading, 12) }
        }
    }
}

private struct MonoField: View {
    @Binding var text: String
    let placeholder: String
    let width: CGFloat

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12.5, design: .monospaced))
            .frame(width: width)
            .autocorrectionDisabled()
    }
}

private struct EnvChip: View {
    let label: String
    let color: Color
    let tint: Color
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(label)
            }
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? Theme.tx : Theme.tx2)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(selected ? tint : .clear, in: .capsule)
            .overlay(Capsule().strokeBorder(selected ? color : Theme.line, lineWidth: selected ? 1 : 0.5))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ColorDot: View {
    let color: Color?
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if let color {
                    Circle().fill(color)
                } else {
                    Circle().strokeBorder(Theme.line, lineWidth: 1)
                }
            }
            .frame(width: 18, height: 18)
            .padding(2.5)
            .overlay {
                if selected { Circle().strokeBorder(color ?? Theme.tx2, lineWidth: 1.5) }
            }
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct DiffRow: View {
    let line: LineDiff.Line

    var body: some View {
        HStack(spacing: 0) {
            Text(sign)
                .frame(width: 22)
                .foregroundStyle(color)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .same ? Theme.tx2 : Theme.tx)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 1)
        .background(background)
    }

    private var sign: String {
        switch line.kind {
        case .same: " "
        case .added: "+"
        case .removed: "−"
        }
    }

    private var color: Color {
        switch line.kind {
        case .same: Theme.tx2
        case .added: Theme.grn
        case .removed: Theme.red
        }
    }

    private var background: Color {
        switch line.kind {
        case .same: .clear
        case .added: Theme.grnTint
        case .removed: Theme.redTint
        }
    }
}

struct Banner: View {
    let text: String
    let color: Color
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(color)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint, in: .rect(cornerRadius: 8))
    }
}
