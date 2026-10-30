import Foundation

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

    /// Команда для POSIX sh: строки «L …», «N …», «M …», «D …», «U …».
    public static let probeCommand = """
    echo "L $(cat /proc/loadavg 2>/dev/null)"; \
    echo "N $(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null)"; \
    awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} /^MemFree:/{f=$2} END{if(a=="")a=f; print "M", t, a}' /proc/meminfo 2>/dev/null; \
    df -Pk / 2>/dev/null | awk 'NR==2{print "D", $2, $3}'; \
    echo "U $(cut -d' ' -f1 /proc/uptime 2>/dev/null)"
    """

    public static func parse(_ output: String) -> HostStats? {
        var s = HostStats(load1: 0, cores: 0, memTotal: 0, memAvailable: 0, diskTotal: 0, diskUsed: 0, uptime: 0)
        var seen = 0
        for line in output.split(whereSeparator: \.isNewline) {
            let p = line.split(separator: " ").map(String.init)
            guard let tag = p.first else { continue }
            switch tag {
            case "L" where p.count >= 2: if let v = Double(p[1]) { s.load1 = v; seen += 1 }
            case "N" where p.count >= 2: if let v = Int(p[1]) { s.cores = v; seen += 1 }
            case "M" where p.count >= 3:
                if let t = Int64(p[1]), let a = Int64(p[2]) { s.memTotal = t * 1024; s.memAvailable = a * 1024; seen += 1 }
            case "D" where p.count >= 3:
                if let t = Int64(p[1]), let u = Int64(p[2]) { s.diskTotal = t * 1024; s.diskUsed = u * 1024; seen += 1 }
            case "U" where p.count >= 2: if let v = Double(p[1]) { s.uptime = v; seen += 1 }
            default: break
            }
        }
        // Не Linux (нет /proc) — показывать нечего.
        return seen >= 3 ? s : nil
    }
}
