import SwiftUI
import RelayaCore

/// Плитки терминалов: дерево разбиений с перетаскиваемыми границами, без наложений.
/// Вкладку или заголовок плитки можно перетащить на край другой плитки — она прилипнет туда
/// и займёт половину; к краю всей сетки — займёт всю ширину или высоту. В центр — поменяться местами.
struct SessionGrid: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @State private var frames: [Session.ID: CGRect] = [:]
    @State private var hint: CGRect?

    var body: some View {
        VStack(spacing: 0) {
            if model.broadcastInput { BroadcastBanner() }
            GeometryReader { geo in
                Group {
                    if let layout = model.currentLayout { node(layout) }
                }
                .padding(6)
                .coordinateSpace(.named("tiles"))
                .onPreferenceChange(TileFrames.self) { frames = $0 }
                .overlay(alignment: .topLeading) { DockHint(rect: hint) }
                .onDrop(of: [.plainText], delegate: TileDropDelegate(
                    model: model, frames: { frames }, bounds: CGRect(origin: .zero, size: geo.size), hint: $hint))
            }
        }
        .background(ThemeStore.sessionOpacity < 1 ? Color.clear : Theme.bar)
    }

    private func node(_ layout: TileLayout<Session.ID>) -> AnyView {
        switch layout {
        case .leaf(let id):
            if let s = model.tileableSessions.first(where: { $0.id == id }) {
                return AnyView(cell(s)
                    .frame(minWidth: 160, maxWidth: .infinity, minHeight: 100, maxHeight: .infinity)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: TileFrames.self, value: [id: g.frame(in: .named("tiles"))])
                    }))
            }
            return AnyView(EmptyView())
        case .row(let children):
            return AnyView(HSplitView { ForEach(Array(children.enumerated()), id: \.offset) { node($0.element) } })
        case .column(let children):
            return AnyView(VSplitView { ForEach(Array(children.enumerated()), id: \.offset) { node($0.element) } })
        }
    }

    private func cell(_ session: Session) -> some View {
        let controller = session.controller
        let active = session.id == model.activeSessionID
        let receiving = model.receivesBroadcast(session)
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                if let host = session.host { OSIcon(os: model.current(host).os, size: 14) }
                if controller == nil { Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(Theme.tx2) }
                Text(session.title).font(.system(size: 12, weight: active ? .semibold : .regular))
                // Куда подключены: user@адрес:порт из ~/.ssh/config.
                if let host = session.host {
                    Text(model.current(host).subtitle)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.tx2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if controller?.ended == true { Text(L("отключён")).font(.system(size: 11)).foregroundStyle(Theme.red) }
                Spacer()
                if model.broadcastInput, controller != nil {
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
            // Полупрозрачный заголовок — как вкладки: не перекрывает стекло и картинку фона.
            .background(.ultraThinMaterial)
            .background(Theme.bg2.opacity(0.35))
            .contentShape(.rect)
            .onTapGesture { model.activeSessionID = session.id }
            .onDrag {
                model.draggingSessionID = session.id
                return NSItemProvider(object: session.id.uuidString as NSString)
            }
            .help(L("Перетащите заголовок на край другой плитки, чтобы переставить"))

            Group {
                if let controller {
                    TerminalView(controller: controller)
                        .id("\(session.id)-\(controller.generation)")
                        .padding(4)
                        .background(Color(nsColor: settings.theme.backgroundColor.withAlphaComponent(ThemeStore.sessionOpacity)))
                } else if case .files(let host) = session.kind {
                    SFTPView(host: host, embedded: true).id(session.id)
                } else if case .tmux(let w) = session.kind {
                    TmuxPaneContent(window: w).id(session.id)
                }
            }
            .simultaneousGesture(TapGesture().onEnded { model.activeSessionID = session.id })
        }
        .clipShape(.rect(cornerRadius: 8, style: .continuous))
        .relayaGlass(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(receiving ? Theme.red.opacity(0.8) : (active ? Theme.acc.opacity(0.45) : Theme.line),
                              lineWidth: receiving ? 1.5 : active ? 1 : 0.5)
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

/// Рамки плиток в общей системе координат сетки.
struct TileFrames: PreferenceKey {
    static let defaultValue: [Session.ID: CGRect] = [:]
    static func reduce(value: inout [Session.ID: CGRect], nextValue: () -> [Session.ID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Подсветка места, куда встанет плитка.
struct DockHint: View {
    let rect: CGRect?

    var body: some View {
        if let rect {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.acc.opacity(0.18))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.acc, lineWidth: 2))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.12), value: rect)
        }
    }
}

/// Куда встанет перетаскиваемая вкладка: у края всей сетки (полоса 28 pt) — на всю ширину/высоту;
/// у края плитки (четверть) — рядом с ней; в центре — поменяться местами.
@MainActor
struct TileDropDelegate: DropDelegate {
    let model: AppModel
    let frames: () -> [Session.ID: CGRect]
    let bounds: CGRect
    @Binding var hint: CGRect?

    enum Target {
        case edge(TileLayout<Session.ID>.Edge, Session.ID?, CGRect)
        case swap(Session.ID, CGRect)
    }

    func target(at p: CGPoint) -> Target? {
        guard let dragged = model.draggingSessionID else { return nil }
        let band: CGFloat = 28
        if p.x < band { return .edge(.left, nil, CGRect(x: 0, y: 0, width: bounds.width / 3, height: bounds.height)) }
        if p.x > bounds.width - band {
            return .edge(.right, nil, CGRect(x: bounds.width * 2 / 3, y: 0, width: bounds.width / 3, height: bounds.height))
        }
        if p.y < band { return .edge(.top, nil, CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height / 3)) }
        if p.y > bounds.height - band {
            return .edge(.bottom, nil, CGRect(x: 0, y: bounds.height * 2 / 3, width: bounds.width, height: bounds.height / 3))
        }
        guard let (id, r) = frames().first(where: { $0.value.contains(p) }) else { return nil }
        let fx = (p.x - r.minX) / r.width, fy = (p.y - r.minY) / r.height
        let edges: [(CGFloat, TileLayout<Session.ID>.Edge, CGRect)] = [
            (fx, .left, CGRect(x: r.minX, y: r.minY, width: r.width / 2, height: r.height)),
            (1 - fx, .right, CGRect(x: r.midX, y: r.minY, width: r.width / 2, height: r.height)),
            (fy, .top, CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height / 2)),
            (1 - fy, .bottom, CGRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2)),
        ]
        let nearest = edges.min { $0.0 < $1.0 }!
        if nearest.0 < 0.28 {
            return id == dragged ? nil : .edge(nearest.1, id, nearest.2)
        }
        return id == dragged ? nil : .swap(id, r)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        switch target(at: info.location) {
        case .edge(_, _, let r)?, .swap(_, let r)?: hint = r
        case nil: hint = nil
        }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { hint = nil }

    func performDrop(info: DropInfo) -> Bool {
        defer { hint = nil; model.draggingSessionID = nil }
        guard let dragged = model.draggingSessionID, let t = target(at: info.location) else { return false }
        switch t {
        case .edge(let edge, let id, _): model.dock(dragged, at: edge, of: id)
        case .swap(let id, _): model.swapTiles(dragged, id)
        }
        return true
    }
}
