import Foundation
import Observation
import RelayaCore

/// Состояние вкладки «Файлы»: живёт в сессии, а не во View, поэтому переключение вкладок
/// не сбрасывает папку, список, очередь передач и открытые в редакторе файлы (К6).
@MainActor @Observable
final class SFTPTab {
    let host: SSHHost
    var path = ""
    var pathField = ""
    var files: [RemoteFile] = []
    var selection = Set<RemoteFile.ID>()
    let queue = TransferQueue()
    var edits: [RemoteEditSession] = []
    /// Домашняя папка уже открыта — при возврате на вкладку не загружаем заново.
    var started = false

    init(host: SSHHost) { self.host = host }
}
