import AppKit
import RelayaCore

/// `Relaya --demo --screenshots <dir>`: opens each README scene on the fictional demo data, saves the main
/// window as `<dir>/mac-<scene>.png` and quits. Used by screenshots.yml after every release tag.
@MainActor
enum DemoScreenshots {
    /// Output folder from `--screenshots <dir>`, or nil when the app runs normally.
    static let directory: URL? = {
        let args = CommandLine.arguments
        guard RelayaPaths.isDemo, let i = args.firstIndex(of: "--screenshots"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }()

    /// Runs the scenes one by one; exits with 1 when a window could not be saved, so CI fails visibly.
    static func run(_ model: AppModel, into dir: URL) async {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else {
                throw Failure("no main window")
            }
            window.setFrame(NSRect(x: 80, y: 80, width: 1280, height: 800), display: true)
            await settle()
            let hosts = model.hosts

            // Host card with live status.
            if let web = hosts.first(where: { $0.alias == "web-1" }) { model.select(host: web.id) }
            try await shoot(window, dir, "host")

            // Three terminals side by side as tiles.
            for alias in ["web-1", "db-primary", "staging"] {
                if let h = hosts.first(where: { $0.alias == alias }) { model.connect(h) }
            }
            let ids = model.tileableSessions.map(\.id)
            if ids.count >= 2 {
                model.tileLayout = .automatic(ids)
                model.gridMode = true
            }
            await settle(seconds: 3)
            try await shoot(window, dir, "tiles")

            // Tool screens.
            model.gridMode = false
            model.activeSessionID = nil
            for (screen, name) in [(Screen.keys, "keys"), (.snippets, "snippets"), (.tunnels, "tunnels"), (.agents, "agents")] {
                model.screen = screen
                try await shoot(window, dir, name)
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("screenshots: \(error)\n".utf8))
            exit(1)
        }
    }

    /// CI diagnostics: writes the app's windows to `<dir>/launch.log` for 20 seconds after launch, and brings any
    /// hidden one to the front, because on a hosted runner the main window did not appear by itself.
    static func watchLaunch(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = dir.appending(path: "launch.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        Task { @MainActor in
            for second in 0..<20 {
                let windows = NSApp.windows.map {
                    "\($0.className) '\($0.title)' visible=\($0.isVisible) frame=\(NSStringFromRect($0.frame))"
                }
                let line = "t=\(second)s active=\(NSApp.isActive) screens=\(NSScreen.screens.count) windows=\(windows)\n"
                if let h = try? FileHandle(forWritingTo: log) {
                    h.seekToEndOfFile()
                    h.write(Data(line.utf8))
                    try? h.close()
                }
                if second == 5 { NSApp.windows.filter { $0.canBecomeMain }.forEach { $0.makeKeyAndOrderFront(nil) } }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    private static func settle(seconds: Double = 1.5) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// The real window through `screencapture` (Liquid Glass included); without the screen recording permission
    /// it saves nothing, so the view's own rendering is the fallback.
    private static func shoot(_ window: NSWindow, _ dir: URL, _ name: String) async throws {
        await settle()
        FileHandle.standardError.write(Data("screenshots: \(name)\n".utf8))
        let file = dir.appending(path: "mac-\(name).png")
        try? FileManager.default.removeItem(at: file)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l\(window.windowNumber)", file.path]
        try p.run()
        // Without the screen recording permission screencapture may wait for a prompt nobody answers.
        for _ in 0..<60 where p.isRunning { try? await Task.sleep(for: .milliseconds(250)) }
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        if p.terminationStatus == 0, size > 10_000 { return }
        guard let view = window.contentView?.superview ?? window.contentView,
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { throw Failure("cannot render \(name)") }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw Failure("cannot encode \(name)") }
        try png.write(to: file)
        FileHandle.standardError.write(Data("screenshots: \(name) rendered in-process (screencapture gave \(size) bytes)\n".utf8))
    }
}
