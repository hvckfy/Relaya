import SwiftUI
import SwiftTerm
import RelayaCore

/// Вкладки сессий (34 pt, как в макете Main).
struct SessionTabBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.sessions) { session in
                        SessionTab(session: session, active: session.id == model.activeSessionID)
                    }
                }
            }
            if model.tileableSessions.count >= 2 {
                ToggleIcon(on: model.gridMode, systemImage: "square.grid.2x2",
                           label: L("Сетка: все терминалы сразу"), tint: Theme.acc) { model.gridMode.toggle() }
            }
            if model.terminalSessions.count >= 2 {
                ToggleIcon(on: model.broadcastInput, systemImage: "dot.radiowaves.left.and.right",
                           label: L("Ввод во все терминалы"), tint: Theme.red) { model.broadcastInput.toggle() }
            }
            IconButton(systemImage: "plus", label: L("Новая вкладка"), size: 34) {
                if case .tmux(let w)? = model.activeSession?.kind { w.client.newWindow(); return }
                if let host = model.activeSession?.host ?? model.selectedHost { model.connect(host) }
                else if let d = model.selectedDesktop { model.openDesktop(d) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: 38)
        .background(Theme.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5) }
    }
}

private struct SessionTab: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let active: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: session.systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(session.controller?.ended == true ? Theme.tx2.opacity(0.4)
                                 : session.host?.tags.first.map(TagStyle.color) ?? Theme.tx2)
                .frame(width: 14)
            if model.receivesBroadcast(session) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.red)
                    .help(L("Получает рассылаемый ввод"))
            }
            Text(session.title)
                .fontWeight(active ? .semibold : .regular)
                .lineLimit(1)
            if session.controller?.logURL != nil {
                Image(systemName: "record.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.red)
                    .help(L("Сессия записывается в файл"))
            }
            Spacer(minLength: 4)
            IconButton(systemImage: "xmark", label: L("Закрыть вкладку %@", "\(session.title)"), size: 20) {
                model.close(session)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(active ? Theme.tx : Theme.tx2)
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(minWidth: 160, maxHeight: .infinity)
        .background {
            // Активная вкладка — заметная «таблетка» с обводкой (как в Safari/Xcode), неактивные —
            // плоские, подсветка при наведении. Без обводки в тёмной теме фон почти сливается с панелью.
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            if active {
                shape.fill(Theme.bg)
                    .overlay(shape.strokeBorder(Theme.tx2.opacity(0.35), lineWidth: 1))
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                    .relayaGlass(shape)
            } else if hovering {
                shape.fill(Theme.sel)
            }
        }
        .onHover { hovering = $0 }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .onTapGesture { model.activeSessionID = session.id; model.screen = .hosts }
        .onDrag {
            model.draggingSessionID = session.id
            return NSItemProvider(object: session.id.uuidString as NSString)
        }
        .contextMenu {
            if let c = session.controller {
                Toggle(L("Сессия tmux"), isOn: Binding(get: { c.tmuxName != nil },
                                                      set: { model.setTmux($0, for: session) }))
                    .help(L("Вкладка переподключится: при включении — внутри tmux, при выключении сессия на сервере закроется."))
            }
            if let c = session.controller {
                Button(c.logURL == nil ? L("Записывать сессию в файл") : L("Остановить запись сессии")) { c.toggleLogging() }
                if let url = c.logURL {
                    Button(L("Показать файл записи")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            }
            if session.controller?.tmuxName != nil {
                Button(L("Отсоединить и оставить на сервере")) { Task { await model.detachKeeping(session) } }
                    .help(L("Сессия tmux продолжит работать; сервер закроет её через сутки без подключения."))
            }
            Button(L("Закрыть вкладку")) { model.close(session) }
        }
    }
}


/// Кнопка-переключатель в полосе вкладок.
private struct ToggleIcon: View {
    let on: Bool
    let systemImage: String
    let label: String
    let tint: SwiftUI.Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(on ? SwiftUI.Color.white : Theme.tx2)
                .frame(width: 28, height: 26)
                .background(on ? tint : SwiftUI.Color.clear, in: .rect(cornerRadius: 7, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
