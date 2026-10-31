import Foundation
import RelayaRust

/// Состояние сервера для карточки хоста: нагрузка, память, диск, аптайм.
/// Снимается одной командой по ssh, без агентов на сервере (Linux, включая busybox/OpenWrt).
public struct HostStats: Equatable, Sendable {
    public var load1: Double
    public var cores: Int
    public var memTotal: Int64
    public var memAvailable: Int64
    public var diskTotal: Int64
    public var diskUsed: Int64
    public var uptime: TimeInterval

    public init(load1: Double, cores: Int, memTotal: Int64, memAvailable: Int64,
                diskTotal: Int64, diskUsed: Int64, uptime: TimeInterval) {
        self.load1 = load1
        self.cores = cores
        self.memTotal = memTotal
        self.memAvailable = memAvailable
        self.diskTotal = diskTotal
        self.diskUsed = diskUsed
        self.uptime = uptime
    }

    public var loadPercent: Double { cores > 0 ? min(1, load1 / Double(cores)) : 0 }
    public var memUsed: Int64 { max(0, memTotal - memAvailable) }
    public var memPercent: Double { memTotal > 0 ? Double(memUsed) / Double(memTotal) : 0 }
    public var diskPercent: Double { diskTotal > 0 ? Double(diskUsed) / Double(diskTotal) : 0 }

    /// Команда для POSIX sh. Логика — в Rust-ядре (`core/src/host_stats.rs`).
    public static var probeCommand: String { hostStatsProbeCommand() }

    public static func parse(_ output: String) -> HostStats? {
        hostStatsParse(output: output).map {
            HostStats(load1: $0.load1, cores: Int($0.cores), memTotal: $0.memTotal, memAvailable: $0.memAvailable,
                      diskTotal: $0.diskTotal, diskUsed: $0.diskUsed, uptime: $0.uptime)
        }
    }
}
