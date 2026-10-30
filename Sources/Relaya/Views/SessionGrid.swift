import SwiftUI
import RelayaCore

/// Все терминалы сразу, сеткой. Клик по ячейке делает её активной; в режиме рассылки
/// у каждой ячейки галочка «получает ввод».
struct SessionGrid: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let sessions = model.terminalSessions
        let columns = max(1, Int(Double(sessions.count).squareRoot().rounded(.up)))
        VStack(spacing: 0) {
            if model.broadcastInput { BroadcastBanner() }
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(Array(stride(from: 0, to: sessions.count, by: columns)), id: \.self) { start in
                    GridRow {
                        ForEach(sessions[start..<min(start + columns, sessions.count)]) { s in
                            if let c = s.controller { cell(s, c) }
                        }
                    }
                }
            }
            .padding(6)
        }
        .background(Theme.bar)
    }

    private func cell(_ session: Session, _ controller: SessionController) -> some View {
        let active = session.id == model.activeSessionID
        let receiving = model.receivesBroadcast(session)
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                OSIcon(os: model.current(controller.host).os, size: 14)
                Text(controller.host.alias).font(.system(size: 12, weight: active ? .semibold : .regular))
                if controller.ended { Text(L("отключён")).font(.system(size: 11)).foregroundStyle(Theme.red) }
                Spacer()
                if model.broadcastInput {
                    Toggle(L("ввод"), isOn: Binding(
                        get: { !model.broadcastExcluded.contains(session.id) },
                        set: { if $0 { model.broadcastExcluded.remove(session.id) } else { model.broadcastExcluded.insert(session.id) } }))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                        .help(L("Получает рассылаемый ввод"))
                }
                IconButton(systemImage: "arrow.up.left.and.arrow.down.right", label: L("Развернуть"), size: 20) {
                    model.activeSessionID = session.id
                    model.gridMode = false
                }
            }
            .foregroundStyle(Theme.tx)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Theme.bg2)
            .contentShape(.rect)
            .onTapGesture { model.activeSessionID = session.id }

            TerminalView(controller: controller)
                .id("\(session.id)-\(controller.generation)")
                .padding(4)
                .background(Color(nsColor: settings.theme.backgroundColor))
                .simultaneousGesture(TapGesture().onEnded { model.activeSessionID = session.id })
        }
        .clipShape(.rect(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(receiving ? Theme.red : (active ? Theme.acc : Theme.line),
                              lineWidth: receiving || active ? 1.5 : 0.5)
        }
    }
}

/// Предупреждение: всё, что набираете, уходит в несколько терминалов.
struct BroadcastBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let count = model.terminalSessions.filter { model.receivesBroadcast($0) }.count
        HStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right")
            Text(L("Ввод рассылается в терминалы: %@. Пароли и сниппеты не рассылаются.", "\(count)"))
            Spacer()
            Button(L("Выключить")) { model.broadcastInput = false }
                .buttonStyle(.relaya(.normal, height: 22))
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Theme.red)
    }
}
