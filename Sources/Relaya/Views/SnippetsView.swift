import SwiftUI
import RelayaCore

/// Экран «Сниппеты» (UI_SPEC 3.10): библиотека команд, запуск на нескольких хостах.
struct SnippetsView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Snippet?
    @State private var runOnHosts: Snippet?
    @State private var query = ""

    private var visible: [Snippet] {
        let q = query.lowercased()
        return q.isEmpty ? model.snippets : model.snippets.filter {
            $0.name.lowercased().contains(q) || $0.command.lowercased().contains(q) || $0.tags.contains { $0.lowercased().contains(q) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(L("Сниппеты")).font(.system(size: 15, weight: .bold))
                TextField(L("Поиск"), text: $query).textFieldStyle(.roundedBorder).frame(width: 220)
                Spacer()
                Button(L("Новый сниппет…")) { editing = Snippet(name: "", command: "") }.buttonStyle(.relayaPrimary)
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5) }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(visible) { s in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(s.name).fontWeight(.semibold)
                                    ForEach(s.tags, id: \.self) { TagChip(tag: $0) }
                                }
                                Text(s.command).font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Theme.tx2).textSelection(.enabled).lineLimit(3)
                            }
                            Spacer()
                            Button(L("На хостах…")) { runOnHosts = s }.buttonStyle(.relaya)
                            Menu {
                                Button(L("Изменить…")) { editing = s }
                                Button(L("Копировать команду")) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(s.command, forType: .string)
                                }
                                Divider()
                                Button(L("Удалить"), role: .destructive) { model.snippets.removeAll { $0.id == s.id } }
                            } label: { Image(systemName: "ellipsis") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        }
                        .padding(12)
                        .background(Theme.bg2, in: .rect(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))
                    }
                }
                .padding(16)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.tx)
        .background(Theme.bg)
        .sheet(item: $editing) { s in SnippetEditor(snippet: s).environment(model) }
        .sheet(item: $runOnHosts) { s in RunOnHostsSheet(snippet: s).environment(model) }
    }
}

private struct SnippetEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var snippet: Snippet
    @State private var tags = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(snippet.name.isEmpty ? L("Новый сниппет") : L("Сниппет")).font(.system(size: 17, weight: .bold))
            TextField(L("Название"), text: $snippet.name).textFieldStyle(.roundedBorder)
            Text(L("Команда · переменные пишите как {{имя}}")).font(.system(size: 12)).foregroundStyle(Theme.tx2)
            TextEditor(text: $snippet.command)
                .font(.system(size: 12.5, design: .monospaced))
                .frame(height: 110)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Theme.bg2, in: .rect(cornerRadius: 8, style: .continuous))
            if !snippet.variables.isEmpty {
                Text(L("Переменные: ") + snippet.variables.joined(separator: ", "))
                    .font(.system(size: 12)).foregroundStyle(Theme.tx2)
            }
            TextField(L("Метки через запятую"), text: $tags).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(L("Отмена")) { dismiss() }.buttonStyle(.relaya).keyboardShortcut(.cancelAction)
                Button(L("Сохранить")) {
                    var s = snippet
                    s.tags = SSHConfigParser.splitTags(tags)
                    if let i = model.snippets.firstIndex(where: { $0.id == s.id }) { model.snippets[i] = s } else { model.snippets.append(s) }
                    dismiss()
                }
                .buttonStyle(.relayaPrimary).keyboardShortcut(.defaultAction)
                .disabled(snippet.name.isEmpty || snippet.command.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(Theme.bg)
        .onAppear { tags = snippet.tags.joined(separator: ", ") }
    }
}

/// Поля для переменных сниппета.
struct VariablesForm: View {
    let snippet: Snippet
    @Binding var values: [String: String]

    var body: some View {
        ForEach(snippet.variables, id: \.self) { name in
            TextField(name, text: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 }))
                .textFieldStyle(.roundedBorder)
        }
        Text(snippet.filled(values)).font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Theme.tx2).textSelection(.enabled)
    }
}

/// ⇧⌘P во вкладке: найти сниппет, заполнить переменные, вставить или выполнить.
struct SnippetPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var chosen: Snippet?
    @State private var values: [String: String] = [:]

    private var matches: [Snippet] {
        let q = query.lowercased()
        return q.isEmpty ? model.snippets : model.snippets.filter {
            $0.name.lowercased().contains(q) || $0.command.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let s = chosen {
                Text(s.name).font(.system(size: 15, weight: .bold))
                VariablesForm(snippet: s, values: $values)
                HStack {
                    Button(L("Назад")) { chosen = nil }.buttonStyle(.relaya)
                    Spacer()
                    Button(L("Вставить")) { send(s, execute: false) }.buttonStyle(.relaya).keyboardShortcut(.defaultAction)
                    Button(L("Выполнить")) { send(s, execute: true) }.buttonStyle(.relayaPrimary)
                }
            } else {
                TextField(L("Найти сниппет"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if let first = matches.first { pick(first) } }
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(matches) { s in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name).fontWeight(.medium)
                                Text(s.command).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.tx2).lineLimit(1)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                            .onTapGesture { pick(s) }
                        }
                    }
                }
                .frame(height: 260)
                HStack { Spacer(); Button(L("Закрыть")) { dismiss() }.buttonStyle(.relaya).keyboardShortcut(.cancelAction) }
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.tx)
        .padding(16)
        .frame(width: 520)
        .background(Theme.bg)
    }

    private func pick(_ s: Snippet) {
        if s.variables.isEmpty { send(s, execute: false) } else { values = [:]; chosen = s }
    }

    private func send(_ s: Snippet, execute: Bool) {
        let cmd = s.filled(values)
        model.activeSession?.controller.insert(execute ? cmd + "\r" : cmd)
        dismiss()
    }
}

/// Выполнить сниппет на нескольких хостах — по вкладке на каждый.
private struct RunOnHostsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let snippet: Snippet
    @State private var chosen: Set<String> = []
    @State private var values: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("«%@» на хостах", "\(snippet.name)")).font(.system(size: 15, weight: .bold))
            VariablesForm(snippet: snippet, values: $values)
            List(model.hosts) { h in
                Toggle(isOn: Binding(get: { chosen.contains(h.alias) },
                                     set: { if $0 { chosen.insert(h.alias) } else { chosen.remove(h.alias) } })) {
                    HStack { OSIcon(os: h.os, size: 16); Text(h.alias); Text(h.subtitle).foregroundStyle(Theme.tx2) }
                }
                .toggleStyle(.checkbox)
            }
            .frame(height: 220)
            Text(L("Откроется вкладка для каждого хоста; команда выполнится после входа."))
                .font(.system(size: 12)).foregroundStyle(Theme.tx2)
            HStack {
                Spacer()
                Button(L("Отмена")) { dismiss() }.buttonStyle(.relaya).keyboardShortcut(.cancelAction)
                Button(L("Выполнить на %@", "\(chosen.count)")) {
                    let cmd = snippet.filled(values)
                    for h in model.hosts where chosen.contains(h.alias) { model.run(cmd, on: h) }
                    dismiss()
                }
                .buttonStyle(.relayaPrimary)
                .disabled(chosen.isEmpty || snippet.variables.contains { (values[$0] ?? "").isEmpty })
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(Theme.bg)
    }
}
