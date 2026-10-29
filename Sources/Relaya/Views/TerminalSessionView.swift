import SwiftUI
import SwiftTerm
import RelayaCore

/// Вкладки сессий (34 pt, как в макете Main).
struct SessionTabBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(model.sessions) { session in
                        SessionTab(session: session, active: session.id == model.activeSessionID)
                    }
                }
            }
            IconButton(systemImage: "plus", label: "Новая вкладка", size: 34) {
                if let host = model.activeSession?.host ?? model.selectedHost { model.connect(host) }
            }
            Spacer(minLength: 0)
        }
        .frame(height: 34)
        .background(Theme.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5) }
    }
}

private struct SessionTab: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let active: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.controller.ended ? Theme.tx2.opacity(0.4)
                      : session.host.tags.first.map(TagStyle.color) ?? Theme.tx2)
                .frame(width: 7, height: 7)
            Text(session.host.alias)
                .fontWeight(active ? .semibold : .regular)
                .lineLimit(1)
            Spacer(minLength: 4)
            IconButton(systemImage: "xmark", label: "Закрыть вкладку \(session.host.alias)", size: 20) {
                model.close(session)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(active ? Theme.tx : Theme.tx2)
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(minWidth: 170, maxHeight: .infinity)
        .background(active ? Theme.bg : .clear)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 0.5) }
        .contentShape(.rect)
        .onTapGesture { model.activeSessionID = session.id; model.screen = .hosts }
    }
}

