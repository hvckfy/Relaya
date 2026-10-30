import Foundation
import Observation
import RelayaCore

/// Очередь передач SFTP: по одной за раз, с прогрессом, скоростью, отменой и повтором.
@MainActor @Observable
final class TransferQueue {
    typealias Operation = @Sendable (@escaping @Sendable (Int64) -> Void) async throws -> Void

    enum State: Equatable {
        case queued, running, done, cancelled
        case failed(String)
    }

    struct Item: Identifiable {
        let id = UUID()
        var name: String
        var upload: Bool
        /// nil — размер неизвестен (папка): прогресс без процентов.
        var total: Int64?
        var transferred: Int64 = 0
        var state: State = .queued
        var started: Date?
        var finished: Date?
        let operation: Operation

        var fraction: Double? {
            guard let total, total > 0 else { return nil }
            return min(1, Double(transferred) / Double(total))
        }

        /// Байт в секунду с начала передачи.
        var speed: Double? {
            guard let started else { return nil }
            let t = (finished ?? Date()).timeIntervalSince(started)
            return t > 0.5 ? Double(transferred) / t : nil
        }
    }

    private(set) var items: [Item] = []
    private var current: (id: UUID, task: Task<Void, Never>)?
    /// Вызывается после каждой успешной передачи (например, перечитать папку).
    var onFinish: (@MainActor (Item) -> Void)?

    var isActive: Bool { items.contains { $0.state == .queued || $0.state == .running } }
    var hasFinished: Bool { items.contains { !($0.state == .queued || $0.state == .running) } }

    func enqueue(name: String, upload: Bool, total: Int64?, _ operation: @escaping Operation) {
        items.append(Item(name: name, upload: upload, total: total, operation: operation))
        pump()
    }

    func cancel(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        switch items[i].state {
        case .queued: items[i].state = .cancelled
        case .running: if current?.id == id { current?.task.cancel() }
        default: break
        }
    }

    func cancelAll() {
        for item in items { cancel(item.id) }
    }

    func retry(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].state = .queued
        items[i].transferred = 0
        items[i].started = nil
        items[i].finished = nil
        pump()
    }

    func clearFinished() {
        items.removeAll { !($0.state == .queued || $0.state == .running) }
    }

    private func pump() {
        guard current == nil, let i = items.firstIndex(where: { $0.state == .queued }) else { return }
        let id = items[i].id
        let operation = items[i].operation
        items[i].state = .running
        items[i].started = Date()
        let task = Task { [self] in
            var outcome: State = .done
            do {
                try await operation { bytes in
                    Task { @MainActor in self.update(id) { $0.transferred = max($0.transferred, bytes) } }
                }
                if Task.isCancelled { outcome = .cancelled }
            } catch is CancellationError {
                outcome = .cancelled
            } catch {
                outcome = Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
            }
            self.complete(id, outcome)
        }
        current = (id, task)
    }

    private func complete(_ id: UUID, _ state: State) {
        update(id) {
            $0.state = state
            $0.finished = Date()
            if state == .done, let total = $0.total { $0.transferred = total }
        }
        current = nil
        if state == .done, let item = items.first(where: { $0.id == id }) { onFinish?(item) }
        pump()
    }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
    }
}

/// Файл с сервера, открытый в локальном редакторе: каждое сохранение загружается обратно.
@MainActor
final class RemoteEditSession {
    let remoteDirectory: String
    let name: String
    let localURL: URL
    private var lastModified: Date?
    private var watcher: Task<Void, Never>?

    init(remoteDirectory: String, name: String, localURL: URL) {
        self.remoteDirectory = remoteDirectory
        self.name = name
        self.localURL = localURL
    }

    /// Следит за датой изменения файла (редакторы сохраняют атомарно — дескриптор не годится).
    func watch(onSave: @escaping @MainActor () -> Void) {
        lastModified = modified
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let now = self.modified
                if let now, now != self.lastModified {
                    self.lastModified = now
                    onSave()
                }
            }
        }
    }

    func stop() {
        watcher?.cancel()
        try? FileManager.default.removeItem(at: localURL.deletingLastPathComponent())
    }

    private var modified: Date? {
        (try? FileManager.default.attributesOfItem(atPath: localURL.path))?[.modificationDate] as? Date
    }
}
