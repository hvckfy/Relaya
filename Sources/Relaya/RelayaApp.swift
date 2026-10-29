import SwiftUI

@main
struct RelayaApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Relaya") {
            MainView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
                .task { model.reloadHosts() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Перечитать ~/.ssh/config") { model.reloadHosts() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}

/// Запуск через `swift run` даёт процесс без бандла — делаем его обычным приложением с окном.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
}
