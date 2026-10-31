import Foundation
import RelayaRust

/// Читает `~/.ssh/config` в список хостов. Логика — в Rust-ядре (`core/src/ssh_config.rs`), общем с Windows-клиентом.
///
/// Поддерживается базовое подмножество: блоки `Host` с конкретными алиасами и ключи
/// HostName, User, Port, IdentityFile, ProxyJump, ForwardAgent, ServerAliveInterval,
/// Compression. Шаблоны (`*`, `?`, `!`), `Match` и `Include` пропускаются.
public enum SSHConfigParser {
    public static var defaultConfigURL: URL {
        RelayaPaths.sshDirectory.appending(path: "config")
    }

    public static func load(from url: URL = defaultConfigURL) throws -> [SSHHost] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return parse(try String(contentsOf: url, encoding: .utf8))
    }

    public static func parse(_ text: String) -> [SSHHost] {
        parseConfig(text: text).map(SSHHost.init(rust:))
    }

    public static func isPattern(_ alias: String) -> Bool { RelayaRust.isPattern(alias: alias) }

    /// `prod, db` → `["prod", "db"]` без пустых и повторов.
    public static func splitTags(_ s: String) -> [String] { RelayaRust.splitTags(s: s) }
}

extension SSHHost {
    init(rust h: RelayaRust.SshHost) {
        self.init(alias: h.alias, hostName: h.hostName, user: h.user, port: h.port.map(Int.init), identityFile: h.identityFile,
                  proxyJump: h.proxyJump, forwardAgent: h.forwardAgent, serverAliveInterval: h.serverAliveInterval.map(Int.init),
                  compression: h.compression, group: h.group, tags: h.tags, color: h.color, os: h.os.flatMap(ServerOS.init(rust:)))
        tmux = h.tmux
    }

    var rust: RelayaRust.SshHost {
        RelayaRust.SshHost(alias: alias, hostName: hostName, user: user, port: port.map(Int64.init), identityFile: identityFile,
                           proxyJump: proxyJump, forwardAgent: forwardAgent, serverAliveInterval: serverAliveInterval.map(Int64.init),
                           compression: compression, group: group, tags: tags, color: color, os: os?.rust, tmux: tmux)
    }
}
