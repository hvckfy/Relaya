import Foundation
import Observation
import RelayaCore

/// Открытая вкладка с SSH-сессией.
struct Session: Identifiable, Hashable {
    let id = UUID()
    let host: SSHHost
}

/// Открытие редактора хоста: `original == nil` — новый хост, `draft` — начальные значения полей.
struct EditorRequest: Identifiable {
    let id = UUID()
    let original: SSHHost?
    let draft: SSHHost

    init(original: SSHHost?, draft: SSHHost? = nil) {
        self.original = original
        self.draft = draft ?? original ?? SSHHost(alias: "")
    }
}

@MainActor
@Observable
final class AppModel {
    let store = SSHConfigStore()

    var hosts: [SSHHost] = []
    var loadError: String?
    var searchText = ""

    var selectedHostID: SSHHost.ID?
    var sessions: [Session] = []
    var activeSessionID: Session.ID?

    var editor: EditorRequest?
    var pendingDelete: SSHHost?
    var alertMessage: String?

    var selectedHost: SSHHost? { hosts.first { $0.id == selectedHostID } }
    var activeSession: Session? { sessions.first { $0.id == activeSessionID } }

    var groups: [String] {
        Array(Set(hosts.compactMap(\.group).filter { !$0.isEmpty })).sorted()
    }

    /// Хосты без группы идут в «Без группы», остальные — по имени группы.
    var groupedHosts: [(name: String, hosts: [SSHHost])] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let visible = query.isEmpty ? hosts : hosts.filter {
            $0.alias.lowercased().contains(query) || $0.subtitle.lowercased().contains(query)
        }
        return Dictionary(grouping: visible) { $0.group ?? "" }
            .sorted { lhs, rhs in
                if lhs.key.isEmpty != rhs.key.isEmpty { return rhs.key.isEmpty }
                return lhs.key < rhs.key
            }
            .map { (name: $0.key.isEmpty ? "Без группы" : $0.key, hosts: $0.value) }
    }

    func reloadHosts() {
        do {
            hosts = SSHConfigParser.parse(try store.loadDocument().text)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - Хосты

    func save(_ host: SSHHost, originalAlias: String?) throws {
        var doc = try store.loadDocument()
        try doc.upsert(host, originalAlias: originalAlias)
        try store.save(doc)
        reloadHosts()
        selectedHostID = host.alias
    }

    func delete(_ host: SSHHost) {
        do {
            var doc = try store.loadDocument()
            try doc.remove(alias: host.alias)
            try store.save(doc)
            if selectedHostID == host.id { selectedHostID = nil }
            reloadHosts()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    // MARK: - Сессии

    func connect(_ host: SSHHost) {
        let session = Session(host: host)
        sessions.append(session)
        activeSessionID = session.id
    }

    func close(_ session: Session) {
        guard let index = sessions.firstIndex(of: session) else { return }
        sessions.remove(at: index)
        if activeSessionID == session.id {
            activeSessionID = sessions.indices.contains(index) ? sessions[index].id : sessions.last?.id
        }
    }

    func closeActiveSession() {
        if let activeSession { close(activeSession) }
    }

    func selectSession(at index: Int) {
        guard sessions.indices.contains(index) else { return }
        activeSessionID = sessions[index].id
    }

    func isConnected(_ host: SSHHost) -> Bool {
        sessions.contains { $0.host.id == host.id }
    }
}
