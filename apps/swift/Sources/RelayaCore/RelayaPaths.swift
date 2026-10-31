import Foundation

/// Корневые пути Relaya. В демо-режиме подменяются на временную папку,
/// чтобы не трогать настоящие ~/.ssh и Application Support.
public enum RelayaPaths {
    /// Задаётся один раз при запуске (`--demo`), до первого обращения к путям.
    nonisolated(unsafe) public static var demoRoot: URL?

    public static var isDemo: Bool { demoRoot != nil }

    public static var sshDirectory: URL {
        demoRoot?.appending(path: "ssh") ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh")
    }

    public static var supportDirectory: URL {
        demoRoot?.appending(path: "support")
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Relaya")
    }
}
