import AppKit
import RelayaCore
import SwiftUI

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
            // Hosted Mac runners have a 1024x768 screen: the window must fit under the menu bar.
            let visible = window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 740)
            window.setFrame(NSRect(x: visible.minX, y: visible.minY, width: min(1024, visible.width), height: visible.height), display: true)
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
                // On a fresh runner SwiftUI opened no main window at launch (only the menu bar extra), so the
                // scenes never started; host the same MainView in a window of our own and run them there.
                if second == 3, !NSApp.windows.contains(where: { $0.canBecomeMain }) { openFallbackWindow(dir) }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Keeps the fallback window and its model alive for the whole run.
    private static var fallback: (window: NSWindow, model: AppModel)?

    private static func openFallbackWindow(_ dir: URL) {
        let model = AppModel()
        model.started = true
        model.settings.applyAppearance()
        model.reloadHosts()
        let root = MainView()
            .environment(model)
            .environment(model.settings)
            .frame(minWidth: 900, minHeight: 560)
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Relaya"
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: root)
        window.makeKeyAndOrderFront(nil)
        fallback = (window, model)
        Task { @MainActor in await run(model, into: dir) }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    private static func settle(seconds: Double = 1.5) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// Hands the window to CI: writes `mac-<name>.ready` with its rectangle in screen points (top-left origin)
    /// and waits for CI's `screencapture -R` to save `mac-<name>.png`. The app itself may not capture the screen
    /// (no screen recording permission), the runner's shell may.
    private static func shoot(_ window: NSWindow, _ dir: URL, _ name: String) async throws {
        await settle()
        FileHandle.standardError.write(Data("screenshots: \(name)\n".utf8))
        let file = dir.appending(path: "mac-\(name).png")
        try? FileManager.default.removeItem(at: file)
        let screenHeight = window.screen?.frame.height ?? NSScreen.main?.frame.height ?? 0
        let f = window.frame
        let rect = "\(Int(f.minX)) \(Int(screenHeight - f.maxY)) \(Int(f.width)) \(Int(f.height))\n"
        try rect.write(to: dir.appending(path: "mac-\(name).ready"), atomically: true, encoding: .utf8)
        for _ in 0..<240 where !FileManager.default.fileExists(atPath: file.path) {
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard FileManager.default.fileExists(atPath: file.path) else { throw Failure("no capture for \(name)") }
    }
}
