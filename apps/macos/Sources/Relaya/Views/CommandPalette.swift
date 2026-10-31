import SwiftUI
import RelayaCore

/// Палитра команд ⌘K (как Spotlight / «Open Quickly» в Xcode): одно поле, нечёткий поиск
/// по хостам, удалённым столам, сниппетам, туннелям, раскладкам и действиям; ↑↓ — выбор, ⏎ — выполнить,
/// ⌘⏎ — альтернативное действие (файлы вместо терминала), Esc — закрыть. Недавние — сверху.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    struct Item: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let systemImage: String
        let section: String
        var fields: [String] = []
        let run: @MainActor (AppModel) -> Void
        var alternate: (@MainActor (AppModel) -> Void)?
    }

    var body: some View {
        let results = self.results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 17)).foregroundStyle(.secondary)
                TextField(L("Хост, действие, сниппет…"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .focused($focused)
                    .onSubmit { run(results, alternate: false) }
                    .onChange(of: query) { selection = 0 }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            if !results.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { i, item in
                                if i == 0 || results[i - 1].section != item.section {
                                    Text(item.section)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 16)
                                        .padding(.top, 8)
                                        .padding(.bottom, 2)
                                }
                                row(item, selected: i == selection)
                                    .id(item.id)
                                    .onTapGesture { selection = i; run(results, alternate: false) }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: selection) { if results.indices.contains(selection) { proxy.scrollTo(results[selection].id) } }
                }
            }
            Divider()
            HStack(spacing: 14) {
                hint("↑↓", L("выбрать"))
                hint("⏎", L("открыть"))
                hint("⌘⏎", L("файлы"))
                hint("esc", L("закрыть"))
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(height: 30)
        }
        .frame(width: 620)
        .background(.regularMaterial, in: .rect(cornerRadius: 14, style: .continuous))
        .relayaGlass(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
        .onAppear { focused = true }
        .onKeyPress(.downArrow) { selection = min(selection + 1, max(results.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
        .onKeyPress(.escape) { model.commandPalette = false; return .handled }
        .onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            run(results, alternate: true)
            return .handled
        }
    }

    private func row(_ item: Item, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.systemImage)
                .frame(width: 20)
                .foregroundStyle(selected ? Color.white : Theme.tx2)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.caption).lineLimit(1)
                        .foregroundStyle(selected ? Color.white.opacity(0.8) : Theme.tx2)
                }
            }
            Spacer()
            if selected, item.alternate != nil {
                Text("⌘⏎ " + L("файлы")).font(.caption).foregroundStyle(Color.white.opacity(0.8))
            }
        }
        .foregroundStyle(selected ? Color.white : Theme.tx)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(selected ? Color.accentColor : .clear, in: .rect(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 6)
        .contentShape(.rect)
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.caption.monospaced())
                .padding(.horizontal, 4)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line, lineWidth: 0.5))
            Text(text)
        }
    }

    private func run(_ results: [Item], alternate: Bool) {
        guard results.indices.contains(selection) else { return }
        let item = results[selection]
        model.commandPalette = false
        model.paletteRecents = ([item.id] + model.paletteRecents.filter { $0 != item.id }).prefix(8).map { $0 }
        if alternate, let alt = item.alternate { alt(model) } else { item.run(model) }
    }

    // MARK: - Источник пунктов

    private var results: [Item] {
        let all = items
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            let recent = model.paletteRecents.compactMap { id in all.first { $0.id == id } }
                .map { Item(id: $0.id, title: $0.title, subtitle: $0.subtitle, systemImage: $0.systemImage,
                            section: L("Недавние"), fields: $0.fields, run: $0.run, alternate: $0.alternate) }
            let rest = all.filter { item in !recent.contains { $0.id == item.id } }
            return recent + rest.filter { $0.section != L("Действия") }.prefix(12)
        }
        return all
            .compactMap { item in FuzzyMatch.score(q, in: [item.title] + item.fields).map { (item, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(40)
            .map(\.0)
    }

    private var items: [Item] {
        var list: [Item] = []
        for h in model.hosts where !h.isGitService {
            list.append(Item(id: "host:" + h.alias, title: h.alias, subtitle: h.subtitle, systemImage: "terminal",
                             section: L("Хосты"), fields: [h.subtitle, h.group ?? ""] + h.tags,
                             run: { $0.connect(h) }, alternate: { $0.openFiles(h) }))
        }
        for d in model.desktops {
            list.append(Item(id: "desktop:" + d.id.uuidString, title: d.displayName, subtitle: d.kind.title + " · " + d.summary,
                             systemImage: d.kind == .vnc ? "display" : "pc", section: L("Удалённые столы"),
                             fields: [d.summary], run: { $0.openDesktop(d) }))
        }
        for layout in model.savedLayouts {
            list.append(Item(id: "layout:" + layout.id.uuidString, title: layout.name,
                             subtitle: layout.layout.ids.joined(separator: ", "), systemImage: "square.grid.2x2",
                             section: L("Раскладки"), fields: layout.layout.ids, run: { $0.openLayout(layout) }))
        }
        for s in model.snippets {
            list.append(Item(id: "snippet:" + s.id.uuidString, title: s.name, subtitle: s.command, systemImage: "text.badge.plus",
                             section: L("Сниппеты"), fields: [s.command] + s.tags,
                             run: { m in m.paletteSnippet = s; m.snippetPalette = true }))
        }
        for t in model.tunnels.tunnels {
            let running = model.tunnels.status(of: t) == .running
            list.append(Item(id: "tunnel:" + t.id.uuidString, title: (running ? L("Остановить туннель") : L("Запустить туннель")) + " · " + t.name,
                             subtitle: t.spec, systemImage: "arrow.left.arrow.right", section: L("Туннели"),
                             fields: [t.name, t.spec],
                             run: { m in running ? m.tunnels.stop(t.id) : m.tunnels.start(t, hosts: m.hosts) }))
        }
        let actions: [(String, String, String, @MainActor (AppModel) -> Void)] = [
            ("new-host", L("Новый хост…"), "plus", { $0.add(nil) }),
            ("new-vnc", L("Подключение VNC…"), "display", { $0.add(.vnc) }),
            ("new-rdp", L("Подключение RDP…"), "pc", { $0.add(.rdp) }),
            ("keys", L("Ключи"), "key", { $0.screen = .keys }),
            ("tunnels", L("Туннели"), "arrow.left.arrow.right", { $0.screen = .tunnels }),
            ("snippets", L("Сниппеты"), "text.badge.plus", { $0.screen = .snippets }),
            ("agents", L("Агенты (MCP)"), "sparkles", { $0.screen = .agents }),
            ("grid", L("Сетка: все терминалы сразу"), "square.grid.2x2", { $0.gridMode.toggle() }),
            ("reload", L("Перечитать ~/.ssh/config"), "arrow.clockwise", { $0.reloadHosts() }),
        ]
        list += actions.map { Item(id: "action:" + $0.0, title: $0.1, subtitle: "", systemImage: $0.2,
                                   section: L("Действия"), run: $0.3) }
        return list
    }
}
