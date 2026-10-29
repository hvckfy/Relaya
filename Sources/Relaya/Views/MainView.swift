import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            VStack(spacing: 0) {
                if !model.sessions.isEmpty {
                    SessionTabBar()
                    Divider()
                }
                content
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if let host = model.selectedHost { model.connect(host) }
                } label: {
                    Label("Подключить", systemImage: "bolt.fill")
                }
                .disabled(model.selectedHost == nil)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let session = model.sessions.first(where: { $0.id == model.activeSessionID }) {
            // id привязывает терминал к сессии — при переключении вкладок процесс не пересоздаётся.
            TerminalSessionView(session: session)
                .id(session.id)
        } else if let host = model.selectedHost {
            HostDetailView(host: host)
        } else {
            EmptyStateView()
        }
    }
}
