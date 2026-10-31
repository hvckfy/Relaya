import SwiftUI
import RelayaCore

/// Экран «Агенты (MCP)» (UI_SPEC 3.12): подключение к AI-клиентам, права по хостам, журнал.
struct AgentsView: View {
    @Environment(AppModel.self) private var model
    @State private var policy = MCPPolicyStore().load()
    @State private var log: [MCPLogEntry] = []
    @State private var copied = false
    @State private var rulesHost: String?
    @State private var logHost = ""

    private var command: String { model.askpassExecutable }

    private var configJSON: String {
        """
        {
          "mcpServers": {
            "relaya": {
              "command": "\(command)",
              "args": ["--mcp"]
            }
          }
        }
        """
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("Агенты (MCP)")).font(.system(size: 20, weight: .bold))
                        Text(L("AI-агенты (Claude, Cursor и другие) работают с вашими серверами через Relaya. Ключи им не передаются — команды выполняет ваш ssh, с вашими правами доступа."))
                            .foregroundStyle(Theme.tx2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle(L("Доступ включён"), isOn: $policy.enabled).toggleStyle(.switch)
                }

                card(title: L("Подключить к клиенту")) {
                    Text(L("Добавьте в настройки MCP-клиента (например, ~/Library/Application Support/Claude/claude_desktop_config.json) и перезапустите его:"))
                        .font(.system(size: 12)).foregroundStyle(Theme.tx2).fixedSize(horizontal: false, vertical: true)
                    Text(configJSON)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.bg, in: .rect(cornerRadius: 8, style: .continuous))
                    HStack {
                        Button(copied ? L("Скопировано") : L("Скопировать конфиг")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(configJSON, forType: .string)
                            copied = true
                        }
                        .buttonStyle(.relayaPrimary)
                        Text(L("Путь указывает на это приложение — держите Relaya в «Программах»."))
                            .font(.system(size: 11)).foregroundStyle(Theme.tx2)
                    }
                }

                card(title: L("Права по хостам")) {
                    HStack {
                        Text(L("Для новых хостов"))
                        Spacer()
                        modePicker($policy.defaultMode)
                    }
                    Divider().overlay(Theme.line2)
                    ForEach(model.hosts) { h in
                        HStack(spacing: 8) {
                            OSIcon(os: h.os, size: 16)
                            Text(h.alias).fontWeight(.medium)
                            ForEach(h.tags.prefix(2), id: \.self) { TagChip(tag: $0) }
                            if let g = policy.grant(for: h.alias) {
                                Text(L("%@ до %@", g.mode.title, g.until.formatted(date: .omitted, time: .shortened)))
                                    .font(.caption).foregroundStyle(Theme.org)
                                Button(L("Отозвать")) { policy.grants?[h.alias] = nil }
                                    .buttonStyle(.relaya(.ghost, height: 20))
                            }
                            let rules = policy.allowPatterns(for: h.alias).count + policy.denyPatterns(for: h.alias).count
                            Button(rules > 0 ? L("Правила (%@)", "\(rules)") : L("Правила")) { rulesHost = h.alias }
                                .buttonStyle(.relaya(.ghost, height: 22))
                            Menu {
                                ForEach([(30, L("на 30 минут")), (120, L("на 2 часа")), (480, L("на 8 часов"))], id: \.0) { minutes, title in
                                    Button(L("Доверенный %@", title)) {
                                        var g = policy.grants ?? [:]
                                        g[h.alias] = .init(mode: .trusted, until: Date().addingTimeInterval(Double(minutes) * 60))
                                        policy.grants = g
                                    }
                                }
                            } label: { Image(systemName: "clock.badge") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .help(L("Временный доступ: потом вернётся обычный режим"))
                            modePicker(Binding(get: { policy.hosts[h.alias] ?? policy.defaultMode },
                                               set: { policy.hosts[h.alias] = $0 }))
                        }
                    }
                    HStack {
                        Text(L("Правила для всех хостов"))
                        Spacer()
                        Button(L("Правила (%@)", "\((policy.allow?["*"]?.count ?? 0) + (policy.deny?["*"]?.count ?? 0))")) { rulesHost = "*" }
                            .buttonStyle(.relaya(.ghost, height: 22))
                    }
                    Text(L("«Только чтение» — безопасные команды (ls, cat, df, journalctl, docker ps…) без перенаправлений и sudo. «С подтверждением» — каждую команду вы одобряете в системном окне; без ответа за 2 минуты — отказ."))
                        .font(.system(size: 11)).foregroundStyle(Theme.tx2).fixedSize(horizontal: false, vertical: true)
                }
                .disabled(!policy.enabled)

                let summaries = MCPLog.summaries(log)
                if !summaries.isEmpty {
                    card(title: L("Что изменили агенты")) {
                        ForEach(summaries.prefix(10)) { s in
                            DisclosureGroup {
                                ForEach(s.changes) { e in
                                    HStack(alignment: .top, spacing: 6) {
                                        Image(systemName: e.exitCode == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                                            .foregroundStyle(e.exitCode == 0 ? Theme.grn : Theme.red)
                                        Text(e.host).fontWeight(.medium)
                                        Text(e.detail).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                                    }
                                    .font(.system(size: 12))
                                }
                            } label: {
                                HStack {
                                    Text(s.client).fontWeight(.medium)
                                    Text(s.started.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(Theme.tx2)
                                    Text(L("%@ изменений на %@", "\(s.changes.count)", s.hosts.joined(separator: ", ")))
                                        .foregroundStyle(Theme.tx2)
                                }
                            }
                        }
                    }
                }

                card(title: L("Журнал")) {
                    HStack {
                        Picker(L("Хост"), selection: $logHost) {
                            Text(L("Все хосты")).tag("")
                            ForEach(Array(Set(log.map(\.host))).sorted(), id: \.self) { Text($0).tag($0) }
                        }
                        .frame(width: 220)
                        Spacer()
                        Button(L("Обновить")) { log = MCPLog().recent() }.buttonStyle(.relaya(.normal, height: 24))
                        Button(L("Очистить")) { MCPLog().clear(); log = [] }.buttonStyle(.relaya(.ghost, height: 24))
                    }
                    if log.isEmpty {
                        Text(L("Пока пусто.")).foregroundStyle(Theme.tx2)
                    } else {
                        ForEach(log.filter { logHost.isEmpty || $0.host == logHost }) { e in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(e.date.formatted(date: .abbreviated, time: .standard)).foregroundStyle(Theme.tx2)
                                    Text(e.client).fontWeight(.medium)
                                    Text("→ \(e.host)")
                                    Spacer()
                                    Text(L(e.decision))
                                        .foregroundStyle(e.decision.hasPrefix("запрещено") || e.decision.hasPrefix("отклонено") ? Theme.red : Theme.grn)
                                    if let code = e.exitCode { Text(L("код %@", "\(code)")).foregroundStyle(Theme.tx2) }
                                }
                                .font(.system(size: 11.5))
                                Text(e.detail).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).lineLimit(3)
                                if let out = e.output, !out.isEmpty {
                                    DisclosureGroup(L("Вывод")) {
                                        Text(out).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .font(.system(size: 11))
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.tx)
        .background(Theme.content)
        .onAppear { log = MCPLog().recent() }
        .onChange(of: policy) { _, p in try? MCPPolicyStore().save(p) }
        .sheet(item: Binding(get: { rulesHost.map { RulesTarget(id: $0) } }, set: { rulesHost = $0?.id })) { t in
            RulesEditor(alias: t.id, policy: $policy)
        }
    }

    private struct RulesTarget: Identifiable { let id: String }

    private func modePicker(_ binding: Binding<MCPPolicy.Mode>) -> some View {
        Picker("", selection: binding) {
            ForEach(MCPPolicy.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .frame(width: 180)
    }

    private func card<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tx2)
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.bg2, in: .rect(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))
        }
    }
}

/// Правила для хоста: шаблоны команд «без подтверждения» и «запрещено всегда».
private struct RulesEditor: View {
    @Environment(\.dismiss) private var dismiss
    let alias: String
    @Binding var policy: MCPPolicy
    @State private var allow = ""
    @State private var deny = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(alias == "*" ? L("Правила для всех хостов") : L("Правила для %@", alias)).font(.title3.bold())
            Text(L("По одному шаблону на строку, как в shell: * — любые символы. Пример: systemctl restart *"))
                .font(.caption).foregroundStyle(.secondary)
            Form {
                Section(L("Без подтверждения")) {
                    TextEditor(text: $allow).font(.system(.body, design: .monospaced)).frame(height: 90)
                }
                Section(L("Запрещено всегда")) {
                    TextEditor(text: $deny).font(.system(.body, design: .monospaced)).frame(height: 90)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Text(L("Запрет сильнее всего, даже доверенного режима. Цепочки (;, &&, |, подстановки) правилом «без подтверждения» не разрешаются."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L("Отмена")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Сохранить")) { save(); dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            allow = (policy.allow?[alias] ?? []).joined(separator: "\n")
            deny = (policy.deny?[alias] ?? []).joined(separator: "\n")
        }
    }

    private func save() {
        func lines(_ s: String) -> [String] {
            s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        var a = policy.allow ?? [:]
        var d = policy.deny ?? [:]
        a[alias] = lines(allow).isEmpty ? nil : lines(allow)
        d[alias] = lines(deny).isEmpty ? nil : lines(deny)
        policy.allow = a
        policy.deny = d
    }
}
