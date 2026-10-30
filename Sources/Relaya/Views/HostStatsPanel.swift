import SwiftUI
import RelayaCore

/// Плитки «Нагрузка · Память · Диск · Аптайм» в карточке хоста.
/// Обновляются при открытии карточки и каждые 15 секунд, пока она на экране.
struct HostStatsPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
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
                let rows: [(String, String, Double?)] = [
                    (L("Нагрузка"), String(format: "%.2f · %d CPU", stats.load1, stats.cores), stats.loadPercent),
                    (L("Память"), "\(bytes(stats.memUsed)) / \(bytes(stats.memTotal))", stats.memPercent),
                    (L("Диск /"), "\(bytes(stats.diskUsed)) / \(bytes(stats.diskTotal))", stats.diskPercent),
                    (L("Аптайм"), uptime(stats.uptime), nil),
                ]
                switch settings.statsStyle {
                case .tiles:
                    HStack(spacing: 8) { ForEach(rows, id: \.0) { tile($0.0, $0.1, $0.2) } }
                case .compact:
                    compact(rows)
                case .pixel:
                    pixel(rows)
                case .console:
                    console(rows)
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

    private func level(_ f: Double) -> Color {
        f > 0.9 ? Theme.red : f > 0.7 ? Theme.org : Theme.grn
    }

    /// Одна строка: подпись · значение · тонкая полоска.
    private func compact(_ rows: [(String, String, Double?)]) -> some View {
        VStack(spacing: 6) {
            ForEach(rows, id: \.0) { r in
                HStack(spacing: 10) {
                    Text(r.0).foregroundStyle(Theme.tx2).frame(width: 80, alignment: .leading)
                    if let f = r.2 {
                        Capsule().fill(Theme.line)
                            .overlay(alignment: .leading) {
                                GeometryReader { g in Capsule().fill(level(f)).frame(width: g.size.width * f) }
                            }
                            .frame(height: 4)
                    } else {
                        Spacer()
                    }
                    Text(r.1).monospacedDigit().frame(minWidth: 150, alignment: .trailing)
                }
                .font(.system(size: 12))
            }
        }
        .padding(12)
        .background(Theme.bg2, in: .rect(cornerRadius: 12, style: .continuous))
    }

    /// Полоски из квадратиков-«пикселей», как индикатор на железке.
    private func pixel(_ rows: [(String, String, Double?)]) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(rows, id: \.0) { r in
                VStack(alignment: .leading, spacing: 6) {
                    Text(r.0.uppercased()).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Theme.tx2)
                    Text(r.1).font(.system(size: 12, weight: .bold, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.6)
                    if let f = r.2 {
                        HStack(spacing: 2) {
                            ForEach(0..<12, id: \.self) { i in
                                Rectangle()
                                    .fill(Double(i) < (f * 12).rounded() ? level(Double(i + 1) / 12) : Theme.line)
                                    .frame(width: 8, height: 8)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(Theme.bg2, in: .rect(cornerRadius: 4))
    }

    /// Как вывод htop: моноширинный текст на фоне терминала.
    private func console(_ rows: [(String, String, Double?)]) -> some View {
        let width = 24
        let lines = rows.map { r -> String in
            let label = r.0.padding(toLength: 9, withPad: " ", startingAt: 0)
            guard let f = r.2 else { return "\(label) \(r.1)" }
            let filled = Int((f * Double(width)).rounded())
            let bar = String(repeating: "|", count: filled) + String(repeating: " ", count: width - filled)
            return "\(label)[\(bar)] \(String(format: "%3d%%", Int(f * 100)))  \(r.1)"
        }
        return Text(lines.joined(separator: "\n"))
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Color(nsColor: settings.theme.foregroundColor))
            .textSelection(.enabled)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: settings.theme.backgroundColor), in: .rect(cornerRadius: 8))
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
