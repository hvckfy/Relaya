import SwiftUI

// Точка входа — main.swift (там askpass-режим).
struct RelayaApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Relaya") {
            MainView()
                .environment(model)
                .environment(model.settings)
                .frame(minWidth: 900, minHeight: 560)
                .task {
                    model.settings.applyAppearance()
                    model.reloadHosts()
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Новый хост…") { model.editor = EditorRequest(original: nil) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Подключить") { if let h = model.selectedHost { model.connect(h) } }
                    .keyboardShortcut("t", modifiers: .command)
                    .disabled(model.selectedHost == nil)
                Button("Закрыть вкладку") { model.closeActiveSession() }
                    .keyboardShortcut("w", modifiers: .command)
                    .disabled(model.activeSession == nil)
                Divider()
                Button("Перечитать ~/.ssh/config") { model.reloadHosts() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandGroup(after: .textEditing) {
                Button("Найти в терминале…") { model.activeSession?.controller.showFind() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(model.activeSession == nil)
            }
            CommandMenu("Вкладки") {
                ForEach(1..<10) { n in
                    Button("Вкладка \(n)") { model.selectSession(at: n - 1) }
                        .keyboardShortcut(KeyEquivalent(Character(String(n))), modifiers: .command)
                }
                Divider()
                Button("Переподключить") { model.activeSession?.controller.reconnect() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.activeSession == nil)
            }
        }

        Settings {
            SettingsView()
                .environment(model.settings)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
