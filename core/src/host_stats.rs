//! Нагрузка, память, диск, аптайм одной командой по ssh (Linux, /proc).

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct HostStats {
    pub load1: f64,
    pub cores: i64,
    pub mem_total: i64,
    pub mem_available: i64,
    pub disk_total: i64,
    pub disk_used: i64,
    pub uptime: f64,
}

#[uniffi::export]
pub fn host_stats_probe_command() -> String {
    "echo \"L $(cat /proc/loadavg 2>/dev/null)\"; echo \"N $(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null)\"; awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} /^MemFree:/{f=$2} END{if(a==\"\")a=f; print \"M\", t, a}' /proc/meminfo 2>/dev/null; df -Pk / 2>/dev/null | awk 'NR==2{print \"D\", $2, $3}'; echo \"U $(cut -d' ' -f1 /proc/uptime 2>/dev/null)\"".into()
}

/// None — не Linux (нет /proc), показывать нечего.
#[uniffi::export]
pub fn host_stats_parse(output: String) -> Option<HostStats> {
    let mut s = HostStats { load1: 0.0, cores: 0, mem_total: 0, mem_available: 0, disk_total: 0, disk_used: 0, uptime: 0.0 };
    let mut seen = 0;
    for line in output.lines() {
        let p: Vec<&str> = line.split(' ').collect();
        match (p.first().copied(), p.len()) {
            (Some("L"), n) if n >= 2 => if let Ok(v) = p[1].parse() { s.load1 = v; seen += 1 },
            (Some("N"), n) if n >= 2 => if let Ok(v) = p[1].parse() { s.cores = v; seen += 1 },
            (Some("M"), n) if n >= 3 => if let (Ok(t), Ok(a)) = (p[1].parse::<i64>(), p[2].parse::<i64>()) { s.mem_total = t * 1024; s.mem_available = a * 1024; seen += 1 },
            (Some("D"), n) if n >= 3 => if let (Ok(t), Ok(u)) = (p[1].parse::<i64>(), p[2].parse::<i64>()) { s.disk_total = t * 1024; s.disk_used = u * 1024; seen += 1 },
            (Some("U"), n) if n >= 2 => if let Ok(v) = p[1].parse() { s.uptime = v; seen += 1 },
            _ => {}
        }
    }
    (seen >= 3).then_some(s)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parses() {
        let s = host_stats_parse("L 0.52 0.40 0.30 1/200 999\nN 4\nM 8000000 4000000\nD 100000 50000\nU 3600.5\n".into()).unwrap();
        assert_eq!(s.cores, 4);
        assert_eq!(s.mem_total, 8_192_000_000);
        assert!(host_stats_parse("garbage".into()).is_none());
    }
}
