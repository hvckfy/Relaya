import SwiftUI
import RelayaCore

/// Контейнеры Docker на хосте: статус, логи, оболочка внутри, запуск/остановка/перезапуск.
/// Если Docker на хосте нет — блок не показывается.
struct DockerPanel: View {
    @Environment(AppModel.self) private var model
    let host: SSHHost
    @State private var confirmStop: DockerContainer?

    var body: some View {
        Group {
            switch model.docker[host.alias] {
            case nil, .notInstalled?:
                EmptyView()
            case .containers(let list)?:
                section(count: list.count) {
                    if list.isEmpty {
                        Text(L("Контейнеров нет.")).font(.system(size: 12)).foregroundStyle(Theme.tx2).padding(12)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, c in
                                row(c)
                                if i < list.count - 1 { Divider().overlay(Theme.line2).padding(.leading, 12) }
                            }
                        }
                    }
                }
            case .permissionDenied?:
                section(count: nil) {
                    message(L("Нет прав на Docker. Добавьте пользователя в группу docker (sudo usermod -aG docker $USER) и войдите заново, или подключайтесь под root."))
                }
            case .failed(let m)?:
                section(count: nil) { message(m) }
            }
        }
        .confirmationDialog(L("Остановить контейнер «%@»?", confirmStop?.name ?? ""),
                            isPresented: Binding(get: { confirmStop != nil }, set: { if !$0 { confirmStop = nil } }),
                            presenting: confirmStop) { c in
            Button(L("Остановить"), role: .destructive) { Task { await model.dockerAction("stop", c, on: host) } }
        }
    }

    private func section<Content: View>(count: Int?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(count.map { "Docker · \($0)" } ?? "Docker")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.tx2)
                Spacer()
                if model.dockerLoading.contains(host.alias) { ProgressView().controlSize(.mini) }
                Button(L("Обновить")) { Task { await model.refreshDocker(host, interactive: true) } }
                    .buttonStyle(.relaya(.ghost, height: 20))
            }
            .padding(.leading, 4)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.bg2, in: .rect(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))
        }
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.tx2)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).padding(12)
    }

    private func row(_ c: DockerContainer) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(c.state == "running" ? Theme.grn : c.state == "restarting" || c.state == "paused" ? Theme.org : Theme.tx2.opacity(0.5))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(c.name).font(.system(size: 13, weight: .semibold))
                    Text(c.image).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.tx2).lineLimit(1)
                }
                Text(c.ports.isEmpty ? c.status : "\(c.status) · \(c.ports)")
                    .font(.system(size: 11)).foregroundStyle(Theme.tx2).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if model.dockerBusy.contains(c.id) {
                ProgressView().controlSize(.small)
            } else {
                Button(L("Логи")) { model.run(Docker.logsCommand(c), on: host) }
                    .buttonStyle(.relaya(.ghost, height: 22))
                    .help("docker logs -f")
                if c.isRunning {
                    Button(L("Терминал")) { model.run(Docker.shellCommand(c), on: host) }
                        .buttonStyle(.relaya(.ghost, height: 22))
                        .help("docker exec -it … sh")
                }
                Menu {
                    if c.isRunning {
                        Button(L("Перезапустить")) { Task { await model.dockerAction("restart", c, on: host) } }
                        Button(L("Остановить…"), role: .destructive) { confirmStop = c }
                    } else {
                        Button(L("Запустить")) { Task { await model.dockerAction("start", c, on: host) } }
                    }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
