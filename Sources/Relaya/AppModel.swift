import Foundation
import Observation
import RelayaCore

/// Открытая вкладка с SSH-сессией.
struct Session: Identifiable, Hashable {
    let id = UUID()
    let host: SSHHost
}

@MainActor
@Observable
final class AppModel {
    var hosts: [SSHHost] = []
    var loadError: String?

    var selectedHostID: SSHHost.ID?
    var sessions: [Session] = []
    var activeSessionID: Session.ID?

    var selectedHost: SSHHost? { hosts.first { $0.id == selectedHostID } }

    /// Хосты без группы идут в «Без группы», остальные — по имени группы.
    var groupedHosts: [(name: String, hosts: [SSHHost])] {
        Dictionary(grouping: hosts) { $0.group ?? "" }
            .sorted { lhs, rhs in
                if lhs.key.isEmpty != rhs.key.isEmpty { return rhs.key.isEmpty }
                return lhs.key < rhs.key
            }
            .map { (name: $0.key.isEmpty ? "Без группы" : $0.key, hosts: $0.value) }
    }

    func reloadHosts() {
        do {
            hosts = try SSHConfigParser.load()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

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

    func isConnected(_ host: SSHHost) -> Bool {
        sessions.contains { $0.host.id == host.id }
    }
}
