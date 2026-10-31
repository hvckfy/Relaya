import SwiftUI
import RelayaCore

// Точка входа — main.swift (там askpass-режим).
struct RelayaApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Relaya") {
            MainView()
                .environment(model)
                .environment(model.settings)
                // Смена темы перерисовывает окно; терминалы при этом переиспользуются (см. TerminalView).
                .id(model.settings.themeRevision)
                .frame(minWidth: 900, minHeight: 560)
                .task {
                    model.settings.applyAppearance()
                    model.reloadHosts()
                    model.tunnels.startAutoStart(hosts: model.hosts)
                    model.sync.onImported = { [weak model] items in model?.applySynced(items) }
                    model.sync.start()
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L("Новый хост…")) { model.editor = EditorRequest(original: nil) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button(L("Подключить")) { if let h = model.selectedHost { model.connect(h) } }
                    .keyboardShortcut("t", modifiers: .command)
                    .disabled(model.selectedHost == nil)
                Button(L("Закрыть вкладку")) { model.closeActiveSession() }
                    .keyboardShortcut("w", modifiers: .command)
                    .disabled(model.activeSession == nil)
                Divider()
                Button(L("Перечитать ~/.ssh/config")) { model.reloadHosts() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Button(L("Палитра команд…")) { model.commandPalette.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
            }
            CommandGroup(after: .textEditing) {
                Button(L("Найти в терминале…")) { model.activeSession?.controller?.showFind() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(model.activeSession?.controller == nil)
            }
            CommandMenu(L("Хост")) {
                if let host = model.selectedHost {
                    HostMenuItems(host: host, shortcuts: true).environment(model)
                } else {
                    Text(L("Выберите хост в боковой панели"))
                }
            }
            CommandMenu(L("Вкладки")) {
                ForEach(1..<10) { n in
                    Button(L("Вкладка %@", "\(n)")) { model.selectSession(at: n - 1) }
                        .keyboardShortcut(KeyEquivalent(Character(String(n))), modifiers: .command)
                }
                Divider()
                Button(L("Сниппеты…")) { model.snippetPalette = true }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(model.activeSession == nil)
                Button(L("Переподключить")) { model.activeSession?.controller?.reconnect() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.activeSession == nil)
                Button(model.activeSession?.controller?.logURL == nil ? L("Записывать сессию в файл") : L("Остановить запись сессии")) {
                    model.activeSession?.controller?.toggleLogging()
                }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(model.activeSession?.controller == nil)
                Divider()
                Button(L("Разделить вправо")) { model.splitActive(.right) }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(model.activeSession?.host == nil)
                Button(L("Разделить вниз")) { model.splitActive(.bottom) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(model.activeSession?.host == nil)
                Menu(L("Перейти к плитке")) {
                    Button(L("Слева")) { model.focusTile(.left) }.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    Button(L("Справа")) { model.focusTile(.right) }.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                    Button(L("Сверху")) { model.focusTile(.top) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
                    Button(L("Снизу")) { model.focusTile(.bottom) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
                }
                .disabled(!model.gridMode)
                Divider()
                Menu(L("Раскладки")) {
                    ForEach(model.savedLayouts) { saved in
                        Button(saved.name) { model.openLayout(saved) }
                    }
                    if !model.savedLayouts.isEmpty { Divider() }
                    Button(L("Сохранить текущие плитки…")) { model.savingLayout = true }
                        .disabled(!model.gridMode || (model.layoutToSave?.ids.count ?? 0) < 2)
                    if !model.savedLayouts.isEmpty {
                        Menu(L("Удалить")) {
                            ForEach(model.savedLayouts) { saved in
                                Button(saved.name) { model.savedLayouts.removeAll { $0.id == saved.id } }
                            }
                        }
                    }
                }
            }
        }

        WindowGroup("VNC", id: "vnc", for: RemoteDesktop.ID.self) { $id in
            VNCWindow(desktopID: id)
                .environment(model)
                .environment(model.settings)
        }
        .windowToolbarStyle(.unifiedCompact)

        WindowGroup("RDP", id: "rdp", for: RemoteDesktop.ID.self) { $id in
            RDPWindow(desktopID: id)
                .environment(model)
                .environment(model.settings)
        }
        .windowToolbarStyle(.unifiedCompact)

        // Туннели из строки меню — без открытого окна.
        // Значок показывается, только если есть туннели. macOS пишет в эту привязку при каждом
        // обновлении сцены — запись без изменения снова будила бы @Observable и зацикливала интерфейс.
        MenuBarExtra(isInserted: Binding(get: { model.settings.menuBarIcon && !model.tunnels.tunnels.isEmpty },
                                         set: { shown in
                                             let current = model.settings.menuBarIcon && !model.tunnels.tunnels.isEmpty
                                             if shown != current, !model.tunnels.tunnels.isEmpty { model.settings.menuBarIcon = shown }
                                         })) {
            MenuBarTunnels().environment(model)
        } label: {
            Image(systemName: model.tunnels.activeCount > 0 ? "arrow.left.arrow.right.circle.fill" : "arrow.left.arrow.right.circle")
        }

        Settings {
            SettingsView()
                .environment(model)
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

/// Меню значка в строке меню: туннели с переключением и быстрый переход в Relaya.
struct MenuBarTunnels: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section(L("Туннели")) {
            ForEach(model.tunnels.tunnels) { t in
                let status = model.tunnels.status(of: t)
                let running = status == .running || status == .starting
                Button {
                    if running { model.tunnels.stop(t.id) } else { model.tunnels.start(t, hosts: model.hosts) }
                } label: {
                    Text((running ? "● " : "○ ") + (t.name.isEmpty ? t.spec : t.name) + " — " + t.summary)
                }
            }
        }
        Divider()
        Button(L("Открыть Relaya")) {
            NSApp.activate()
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
        Button(L("Выйти из Relaya")) { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
