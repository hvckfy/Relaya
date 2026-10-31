import SwiftUI
import RelayaCore

/// Лёгкая мини-панель хоста в карточке: сервисы systemd, слушающие порты, ошибки журнала, обновления.
/// Всё — одной командой по ssh, без агента. Действия — только с подтверждением.
struct HostPanelView: View {
    @Environment(AppModel.self) private var model
    let host: SSHHost
    @State private var showAllServices = false
    @State private var serviceFilter = ""
    @State private var scope: Scope = .active

    enum Scope: String, CaseIterable, Identifiable {
        case active, failed, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .active: L("Активные")
            case .failed: L("С ошибкой")
            case .all: L("Все")
            }
        }
    }
    @State private var confirm: (action: String, unit: ServiceUnit)?

    var body: some View {
        Group {
            if let panel = model.hostPanel[host.alias] {
                if panel.hasSystemd { services(panel) }
                if !panel.ports.isEmpty { ports(panel) }
                if !panel.errors.isEmpty { errors(panel) }
                if let updates = panel.updates { updatesSection(updates) }
            }
        }
        .confirmationDialog(confirm.map { L("%@ сервис «%@»?", actionTitle($0.action), $0.unit.shortName) } ?? "",
                            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            presenting: confirm) { c in
            Button(actionTitle(c.action), role: c.action == "stop" ? .destructive : nil) {
                Task { await model.serviceAction(c.action, c.unit, on: host) }
            }
        } message: { c in
            Text(HostPanel.serviceCommand(c.action, c.unit, root: model.current(host).user == "root"))
        }
    }

    // MARK: - Сервисы

    @ViewBuilder private func services(_ panel: HostPanel) -> some View {
        let failed = panel.services.filter(\.isFailed)
        let query = serviceFilter.trimmingCharacters(in: .whitespaces).lowercased()
        let inScope = panel.services.filter { u in
            switch scope {
            case .active: u.isFailed || u.isActive
            case .failed: u.isFailed
            case .all: true
            }
        }
        let filtered = query.isEmpty ? inScope
            : inScope.filter { $0.name.lowercased().contains(query) || $0.description.lowercased().contains(query) }
        let shown = showAllServices || !query.isEmpty ? filtered : Array(filtered.prefix(max(8, failed.count)))
        Section {
            HStack {
                Picker("", selection: $scope) {
                    ForEach(Scope.allCases) { s in
                        Text(s == .failed && !failed.isEmpty ? "\(s.title) (\(failed.count))" : s.title).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                TextField(L("Найти сервис"), text: $serviceFilter, prompt: Text(L("Найти сервис")))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
            if filtered.isEmpty {
                Text(scope == .failed ? L("Упавших сервисов нет.") : L("Ничего не найдено"))
                    .foregroundStyle(.secondary)
            }
            ForEach(shown) { serviceRow($0) }
            if query.isEmpty, filtered.count > shown.count || showAllServices {
                Button(showAllServices ? L("Свернуть") : L("Показать все (%@)", "\(filtered.count)")) {
                    withAnimation { showAllServices.toggle() }
                }
                .buttonStyle(.link)
            }
        } header: {
            header(L("Сервисы"), badge: failed.isEmpty ? nil : L("%@ с ошибкой", "\(failed.count)"), refresh: true)
        }
    }

    private func serviceRow(_ u: ServiceUnit) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(u.isFailed ? Theme.red : u.isRunning ? Theme.grn : u.isActive ? Theme.acc : Theme.tx2.opacity(0.4))
                .frame(width: 8, height: 8)
                .help(u.isFailed ? L("ошибка") : u.isRunning ? L("работает") : u.isActive ? "\(u.active) · \(u.sub)" : L("остановлен"))
            VStack(alignment: .leading, spacing: 1) {
                Text(u.shortName).font(.system(.callout, design: .monospaced))
                if !u.description.isEmpty {
                    Text(u.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if model.hostPanelBusy.contains(u.id) {
                ProgressView().controlSize(.small)
            } else {
                Button(L("Логи")) { model.run(HostPanel.serviceLogsCommand(u, root: model.current(host).user == "root"), on: host) }
                    .buttonStyle(.relaya(.ghost, height: 22))
                Menu {
                    Button(L("Перезапустить…")) { confirm = ("restart", u) }
                    if u.active == "active" {
                        Button(L("Остановить…"), role: .destructive) { confirm = ("stop", u) }
                    } else {
                        Button(L("Запустить…")) { confirm = ("start", u) }
                    }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
    }

    private func actionTitle(_ action: String) -> String {
        switch action {
        case "restart": L("Перезапустить")
        case "stop": L("Остановить")
        default: L("Запустить")
        }
    }

    // MARK: - Порты, ошибки, обновления

    private func ports(_ panel: HostPanel) -> some View {
        Section {
            ForEach(panel.ports) { p in
                LabeledContent {
                    Text(p.process ?? "—").foregroundStyle(.secondary)
                } label: {
                    HStack(spacing: 6) {
                        Text(p.port.map(String.init) ?? p.address).font(.system(.callout, design: .monospaced))
                        Text(p.proto).font(.caption).foregroundStyle(.secondary)
                        Text(p.address).font(.caption.monospaced()).foregroundStyle(.tertiary)
                    }
                }
            }
        } header: {
            header(L("Слушающие порты"), badge: nil)
        }
    }

    private func errors(_ panel: HostPanel) -> some View {
        Section {
            DisclosureGroup(L("Последние ошибки: %@", "\(panel.errors.count)")) {
                Text(panel.errors.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(L("Открыть журнал")) {
                model.run((model.current(host).user == "root" ? "" : "sudo ") + "journalctl -p err -n 200 -f", on: host)
            }
            .buttonStyle(.link)
        } header: {
            header(L("Журнал"), badge: nil)
        }
    }

    private func updatesSection(_ updates: [String]) -> some View {
        Section {
            if updates.isEmpty {
                Text(L("Система обновлена.")).foregroundStyle(.secondary)
            } else {
                DisclosureGroup(L("Доступно обновлений: %@", "\(updates.count)")) {
                    Text(updates.joined(separator: ", "))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let update = model.current(host).os?.actions.first {
                    Button(L("Обновить в терминале…")) { model.run(update.command, on: host) }
                        .help(update.command)
                }
            }
        } header: {
            header(L("Обновления"), badge: updates.isEmpty ? nil : "\(updates.count)")
        }
    }

    private func header(_ title: String, badge: String?, refresh: Bool = false) -> some View {
        HStack {
            Text(title)
            if let badge {
                Text(badge)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.red)
            }
            Spacer()
            if model.hostPanelLoading.contains(host.alias) { ProgressView().controlSize(.mini) }
            if refresh {
                Button(L("Обновить")) { Task { await model.refreshPanel(host, interactive: true) } }
                    .buttonStyle(.relaya(.ghost, height: 20))
            }
        }
    }
}
