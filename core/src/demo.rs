//! Fictional data for `--demo` (README screenshots, presentations) shared by every client.

/// `~/.ssh/config` of the demo: fictional hosts in two groups, documentation addresses (RFC 5737) only.
#[uniffi::export]
pub fn demo_ssh_config() -> String {
    DEMO_CONFIG.to_string()
}

const DEMO_CONFIG: &str = r#"# Демо-конфигурация Relaya — вымышленные хосты.

# relaya: group=Работа tags=prod,web os=ubuntu
Host web-1
    HostName 203.0.113.10
    User deploy
    IdentityFile ~/.ssh/id_ed25519_work

# relaya: group=Работа tags=prod,web os=ubuntu
Host web-2
    HostName 203.0.113.11
    User deploy
    IdentityFile ~/.ssh/id_ed25519_work

# relaya: group=Работа tags=prod,db os=debian
Host db-primary
    HostName 10.20.0.5
    User postgres
    ProxyJump bastion
    IdentityFile ~/.ssh/id_ed25519_work

# relaya: group=Работа tags=staging os=ubuntu
Host staging
    HostName staging.example.com
    User ubuntu

# relaya: group=Работа tags=infra os=debian
Host bastion
    HostName bastion.example.com
    User alex
    IdentityFile ~/.ssh/id_ed25519_work

# relaya: group=Дом tags=homelab os=raspbian
Host pi-home
    HostName 192.168.1.20
    User pi
    IdentityFile ~/.ssh/id_ed25519_homelab

# relaya: group=Дом tags=homelab,network os=openwrt
Host router
    HostName 192.168.1.1
    User root

# relaya: group=Дом tags=homelab os=macos
Host mac-mini
    HostName mac-mini.local
    User alex
    IdentityFile ~/.ssh/id_ed25519_homelab

# relaya: group=Дом tags=vpn os=alpine
Host vps-fra
    HostName 198.51.100.7
    User root
    IdentityFile ~/.ssh/id_ed25519
"#;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn demo_config_parses_into_hosts() {
        let hosts = crate::ssh_config::parse_config(demo_ssh_config());
        assert_eq!(hosts.len(), 9);
        assert!(hosts.iter().any(|h| h.alias == "web-1"));
    }
}
