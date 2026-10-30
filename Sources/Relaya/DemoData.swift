import Foundation
import RelayaCore

/// Вымышленные данные для `Relaya --demo` (скриншоты, презентации).
/// Всё создаётся заново во временной папке; настоящие файлы пользователя не читаются.
enum DemoData {
    static func prepare() -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "relaya-demo")
        try? FileManager.default.removeItem(at: root)
        let ssh = root.appending(path: "ssh")
        let support = root.appending(path: "support")
        try? FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        try? config.write(to: ssh.appending(path: "config"), atomically: true, encoding: .utf8)
        for (name, comment) in [("id_ed25519", "alex@macbook-pro"), ("id_ed25519_work", "alex@acme · deploy"),
                                ("id_ed25519_homelab", "alex@macbook-pro · homelab")] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            p.arguments = ["-t", "ed25519", "-N", "", "-q", "-C", comment, "-f", ssh.appending(path: name).path]
            try? p.run()
            p.waitUntilExit()
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let tunnels = [
            Tunnel(name: "Postgres prod", hostAlias: "db-primary", listenPort: 15432, targetHost: "localhost", targetPort: 5432, autoStart: true),
            Tunnel(name: "Grafana", hostAlias: "web-1", listenPort: 3000, targetHost: "grafana.internal", targetPort: 3000),
            Tunnel(name: "SOCKS через VPS", hostAlias: "vps-fra", kind: .dynamic, listenPort: 1080),
        ]
        try? encoder.encode(tunnels).write(to: support.appending(path: "tunnels.json"))
        let desktops = [
            RemoteDesktop(name: "Mac mini (студия)", kind: .vnc, address: "localhost", user: "alex", viaSSHHost: "mac-mini"),
            RemoteDesktop(name: "Windows build agent", kind: .rdp, address: "10.20.0.15", user: "ACME\\builder"),
        ]
        try? encoder.encode(desktops).write(to: support.appending(path: "desktops.json"))
        try? encoder.encode(MCPPolicy(enabled: true, defaultMode: .confirm,
                                      hosts: ["db-primary": .readOnly, "web-1": .confirm, "pi-home": .trusted, "router": .off]))
            .write(to: support.appending(path: "mcp.json"))
        let log = MCPLog(url: support.appending(path: "mcp-log.jsonl"))
        let now = Date()
        log.append(MCPLogEntry(date: now.addingTimeInterval(-900), client: "Claude", tool: "run_command", host: "db-primary",
                               detail: "df -h /var/lib/postgresql", decision: "разрешено: чтение", exitCode: 0))
        log.append(MCPLogEntry(date: now.addingTimeInterval(-600), client: "Claude", tool: "run_command", host: "db-primary",
                               detail: "systemctl restart postgresql", decision: "запрещено: только чтение"))
        log.append(MCPLogEntry(date: now.addingTimeInterval(-300), client: "Cursor", tool: "run_command", host: "web-1",
                               detail: "docker compose pull && docker compose up -d", decision: "одобрено пользователем", exitCode: 0))
        return root
    }

    /// Окружение локальной оболочки во вкладке: приглашение как на сервере и короткое приветствие.
    static func shellEnvironment(for host: SSHHost) -> [String] {
        let user = host.user ?? "alex"
        let motd: String
        switch host.os {
        case .ubuntu?: motd = "Welcome to Ubuntu 24.04.1 LTS (GNU/Linux 6.8.0-45-generic x86_64)"
        case .debian?: motd = "Debian GNU/Linux 12 (bookworm)"
        case .openwrt?: motd = "BusyBox v1.36.1 · OpenWrt 23.05.4"
        case .raspbian?: motd = "Raspberry Pi OS · Linux 6.6.51-v8+ aarch64"
        default: motd = "Last login: \(Date().formatted(date: .abbreviated, time: .shortened))"
        }
        let rc = "printf '%s\\n\\n' '\(motd)'; PS1='\\[\\e[32m\\]\(user)@\(host.alias)\\[\\e[0m\\]:\\[\\e[34m\\]~\\[\\e[0m\\]\\$ '"
        return ["TERM=xterm-256color", "LANG=en_US.UTF-8", "HOME=\(NSTemporaryDirectory())",
                "PROMPT_COMMAND=\(rc); unset PROMPT_COMMAND", "BASH_SILENCE_DEPRECATION_WARNING=1"]
    }

    static let config = """
    # Демо-конфигурация Relaya — вымышленные хосты.

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
    """
}
