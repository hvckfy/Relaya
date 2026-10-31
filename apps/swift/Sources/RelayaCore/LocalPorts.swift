import Foundation
import RelayaRust

/// Адреса вида `localhost:3000`, `127.0.0.1:8080`, `0.0.0.0:5173`, `[::1]:9000` в выводе терминала —
/// порты на сервере. Логика — в Rust-ядре (`core/src/local_ports.rs`).
public enum LocalPorts {
    public static func find(in text: String) -> [Int] {
        localPortsFind(text: text).map(Int.init)
    }
}
