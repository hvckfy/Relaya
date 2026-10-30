import SwiftUI
import RelayaCore

/// Плитки «Нагрузка · Память · Диск · Аптайм» в карточке хоста.
/// Обновляются при открытии карточки и каждые 15 секунд, пока она на экране.
struct HostStatsPanel: View {
    @Environment(AppModel.self) private var model
    let host: SSHHost

    var body: some View {
        let stats = model.hostStats[host.alias]
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("Состояние").uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.tx2)
                Spacer()
                if model.hostStatsLoading.contains(host.alias) {
                    ProgressView().controlSize(.mini)
                }
                Button(L("Обновить")) { Task { await model.refreshStats(host, interactive: true) } }
                    .buttonStyle(.relaya(.ghost, height: 20))
            }
            .padding(.leading, 4)

            if let stats {
                HStack(spacing: 8) {
                    tile(L("Нагрузка"), String(format: "%.2f · %d CPU", stats.load1, stats.cores), stats.loadPercent)
                    tile(L("Память"), "\(bytes(stats.memUsed)) / \(bytes(stats.memTotal))", stats.memPercent)
                    tile(L("Диск /"), "\(bytes(stats.diskUsed)) / \(bytes(stats.diskTotal))", stats.diskPercent)
                    tile(L("Аптайм"), uptime(stats.uptime), nil)
                }
            } else if let error = model.hostStatsError[host.alias] {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tx2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.bg2, in: .rect(cornerRadius: 12, style: .continuous))
            }
        }
        .task(id: host.alias) {
            while !Task.isCancelled {
                await model.refreshStats(host, interactive: false)
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private func tile(_ title: String, _ value: String, _ fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.tx2)
            Text(value).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
            if let fraction {
                ProgressView(value: fraction)
                    .tint(fraction > 0.9 ? Theme.red : fraction > 0.7 ? Theme.org : Theme.grn)
            } else {
                Spacer(minLength: 0).frame(height: 4)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg2, in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))
    }

    private func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .memory)
    }

    private func uptime(_ seconds: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 86400 ? [.day, .hour] : [.hour, .minute]
        f.unitsStyle = .abbreviated
        return f.string(from: seconds) ?? "—"
    }
}
