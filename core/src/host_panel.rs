//! Мини-панель хоста: сервисы systemd, слушающие порты, ошибки журнала, обновления — одной командой по ssh.

use crate::server_os::{PackageManager, ServerOs};
use crate::shell_quote;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ServiceUnit {
    pub name: String,
    pub active: String,
    pub sub: String,
    pub description: String,
}

impl ServiceUnit {
    pub fn is_failed(&self) -> bool { self.active == "failed" }
    pub fn is_running(&self) -> bool { self.active == "active" && self.sub == "running" }
    pub fn is_active(&self) -> bool { ["active", "activating", "reloading", "deactivating"].contains(&self.active.as_str()) }
    /// Упавшие → работающие → прочие активные → остановленные.
    pub fn rank(&self) -> u8 { if self.is_failed() { 0 } else if self.is_running() { 1 } else if self.is_active() { 2 } else { 3 } }
}

#[uniffi::export]
pub fn service_rank(unit: ServiceUnit) -> u8 { unit.rank() }

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ListeningPort {
    pub proto: String,
    pub address: String,
    pub process: Option<String>,
    pub port: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HostPanel {
    pub services: Vec<ServiceUnit>,
    pub ports: Vec<ListeningPort>,
    pub errors: Vec<String>,
    /// None — менеджер пакетов не поддерживается.
    pub updates: Option<Vec<String>>,
    pub has_systemd: bool,
}

fn updates_command(os: Option<ServerOs>) -> Option<&'static str> {
    Some(match os.and_then(|o| o.package_manager())? {
        PackageManager::Apt => "apt list --upgradable 2>/dev/null | grep -v '^Listing' | head -n 300",
        PackageManager::Dnf => "dnf -q --cacheonly check-update 2>/dev/null | awk 'NF==3{print $1}' | head -n 300",
        PackageManager::Yum => "yum -q -C check-update 2>/dev/null | awk 'NF==3{print $1}' | head -n 300",
        PackageManager::Apk => "apk -u list 2>/dev/null | head -n 300",
        PackageManager::Pacman => "pacman -Qu 2>/dev/null | head -n 300",
        PackageManager::Zypper => "zypper -q --no-refresh lu 2>/dev/null | awk -F'|' 'NR>2{gsub(/ /,\"\",$3); print $3}' | head -n 300",
        PackageManager::Opkg => "opkg list-upgradable 2>/dev/null | head -n 300",
        _ => return None,
    })
}

#[uniffi::export]
pub fn host_panel_probe_command(os: Option<ServerOs>) -> String {
    format!("echo '##SERVICES'; systemctl list-units --type=service --all --no-legend --plain --no-pager 2>/dev/null | head -n 400\necho '##PORTS'; ss -tulnpH 2>/dev/null | head -n 200\necho '##ERRORS'; journalctl -p err -n 20 --no-pager -o short-iso 2>/dev/null\necho '##UPDATES'; {}\ntrue",
            updates_command(os).unwrap_or("echo RELAYA_NO_PM"))
}

#[uniffi::export]
pub fn host_panel_parse(output: String) -> HostPanel {
    let unit_re = regex::Regex::new(r"^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s*(.*)$").unwrap();
    let mut section = "";
    let (mut services, mut ports, mut errors) = (Vec::new(), Vec::<ListeningPort>::new(), Vec::new());
    let mut updates: Option<Vec<String>> = Some(Vec::new());
    for line in output.split('\n') {
        if line.starts_with("##") { section = if line.starts_with("##SERVICES") { "s" } else if line.starts_with("##PORTS") { "p" } else if line.starts_with("##ERRORS") { "e" } else if line.starts_with("##UPDATES") { "u" } else { "" }; continue; }
        let t = line.trim();
        if t.is_empty() { continue; }
        match section {
            "s" => {
                let Some(c) = unit_re.captures(t) else { continue };
                if !c[1].ends_with(".service") { continue; }
                services.push(ServiceUnit { name: c[1].into(), active: c[3].into(), sub: c[4].into(), description: c[5].trim().into() });
            }
            "p" => {
                let f: Vec<&str> = t.split_whitespace().collect();
                if f.len() < 5 { continue; }
                let process = f.iter().find(|x| x.starts_with("users:")).and_then(|u| {
                    let a = u.find("((\"")? + 3;
                    let rest = &u[a..];
                    Some(rest[..rest.find('"')?].to_string())
                });
                let port = f[4].rsplit(':').next().and_then(|p| p.parse().ok());
                ports.push(ListeningPort { proto: f[0].into(), address: f[4].into(), process, port });
            }
            "e" => if !t.starts_with("-- ") { errors.push(t.to_string()) },
            "u" => {
                if t == "RELAYA_NO_PM" { updates = None; continue; }
                let name = t.split(['/', ' ']).next().unwrap_or(t).to_string();
                if let Some(u) = updates.as_mut() { u.push(name); }
            }
            _ => {}
        }
    }
    let mut seen = std::collections::HashSet::new();
    ports.retain(|p| seen.insert(format!("{} {}", p.proto, p.address)));
    ports.sort_by(|a, b| (a.port.unwrap_or(0), &a.proto).cmp(&(b.port.unwrap_or(0), &b.proto)));
    services.sort_by(|a, b| (a.rank(), a.name.to_lowercase()).cmp(&(b.rank(), b.name.to_lowercase())));
    let has_systemd = !services.is_empty();
    HostPanel { services, ports, errors, updates, has_systemd }
}

/// systemctl-действие; `sudo` — если не root.
#[uniffi::export]
pub fn service_command(action: String, unit: String, root: bool) -> String {
    format!("{}systemctl {action} {}", if root { "" } else { "sudo " }, shell_quote(&unit))
}

#[uniffi::export]
pub fn service_logs_command(unit: String, root: bool) -> String {
    format!("{}journalctl -u {} -n 200 -f", if root { "" } else { "sudo " }, shell_quote(&unit))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parses_sections() {
        let sample = "##SERVICES\ncron.service loaded active running Regular background program processing daemon\nnginx.service loaded failed failed A high performance web server\nssh.service loaded active running OpenBSD Secure Shell server\n##PORTS\ntcp LISTEN 0 4096 0.0.0.0:22 0.0.0.0:* users:((\"sshd\",pid=612,fd=3))\ntcp LISTEN 0 511 [::]:80 [::]:* users:((\"nginx\",pid=700,fd=6))\nudp UNCONN 0 0 127.0.0.53%lo:53 0.0.0.0:* users:((\"systemd-resolve\",pid=500,fd=13))\n##ERRORS\n2026-10-31T10:00:00+0000 web nginx[700]: bind() failed\n##UPDATES\nopenssl/stable 3.0.15-1 amd64 [upgradable from: 3.0.14-1]\ncurl/stable 8.5.0-2 amd64 [upgradable from: 8.5.0-1]\n";
        let p = host_panel_parse(sample.into());
        assert_eq!(p.services.iter().map(|s| s.name.as_str()).collect::<Vec<_>>(), ["nginx.service", "cron.service", "ssh.service"]);
        assert_eq!(p.services[1].description, "Regular background program processing daemon");
        assert_eq!(p.ports.iter().map(|p| p.port.unwrap()).collect::<Vec<_>>(), [22, 53, 80]);
        assert_eq!(p.ports[0].process.as_deref(), Some("sshd"));
        assert_eq!(p.updates, Some(vec!["openssl".into(), "curl".into()]));
        assert_eq!(host_panel_parse("##SERVICES\n##UPDATES\nRELAYA_NO_PM\n".into()).updates, None);
        assert_eq!(service_command("restart".into(), "my app.service".into(), false), "sudo systemctl restart 'my app.service'");
    }
}
