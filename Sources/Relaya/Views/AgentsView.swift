import SwiftUI
import RelayaCore

/// Экран «Агенты (MCP)» (UI_SPEC 3.12): подключение к AI-клиентам, права по хостам, журнал.
struct AgentsView: View {
    @Environment(AppModel.self) private var model
    @State private var policy = MCPPolicyStore().load()
    @State private var log: [MCPLogEntry] = []
    @State private var copied = false

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
                            Spacer()
                            modePicker(Binding(get: { policy.hosts[h.alias] ?? policy.defaultMode },
                                               set: { policy.hosts[h.alias] = $0 }))
                        }
                    }
                    Text(L("«Только чтение» — безопасные команды (ls, cat, df, journalctl, docker ps…) без перенаправлений и sudo. «С подтверждением» — каждую команду вы одобряете в системном окне; без ответа за 2 минуты — отказ."))
                        .font(.system(size: 11)).foregroundStyle(Theme.tx2).fixedSize(horizontal: false, vertical: true)
                }
                .disabled(!policy.enabled)

                card(title: L("Журнал")) {
                    HStack {
                        Spacer()
                        Button(L("Обновить")) { log = MCPLog().recent() }.buttonStyle(.relaya(.normal, height: 24))
                        Button(L("Очистить")) { MCPLog().clear(); log = [] }.buttonStyle(.relaya(.ghost, height: 24))
                    }
                    if log.isEmpty {
                        Text(L("Пока пусто.")).foregroundStyle(Theme.tx2)
                    } else {
                        ForEach(log) { e in
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
    }

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
