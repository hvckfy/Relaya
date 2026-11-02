import Foundation
import RelayaRust

/// The login gate file shared by the app and `Relaya --mcp` (B-7): hosts whose login the server refused.
///
/// The rule (exit 255 plus a refusal or block) and the file live in the core; this is the Mac facade.
public enum LoginGateFile {
    /// `login-gate.json` in Application Support.
    public static var path: String { RelayaPaths.supportDirectory.appending(path: "login-gate.json").path }

    /// What one ssh call says about the login: refused, worked or unknown (timeout, not started).
    public static func outcome(_ r: ProcessResult) -> LoginOutcome {
        loginOutcome(status: r.status, timedOut: r.timedOut, stderr: r.stderr)
    }

    /// The reason background calls to `alias` are stopped, or nil.
    public static func reason(_ alias: String, at file: String = path) -> String? {
        loginGateReason(path: file, alias: alias)
    }

    /// Stops background calls to `alias`.
    /// - Throws: `CoreError` when the file cannot be written.
    public static func close(_ alias: String, reason: String, at file: String = path) throws {
        try loginGateClose(path: file, alias: alias, reason: reason)
    }

    /// Lets background calls to `alias` run again.
    /// - Throws: `CoreError` when the file cannot be written.
    public static func open(_ alias: String, at file: String = path) throws {
        try loginGateOpen(path: file, alias: alias)
    }
}
