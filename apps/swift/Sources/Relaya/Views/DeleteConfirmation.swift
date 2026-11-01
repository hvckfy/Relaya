import SwiftUI
import RelayaCore

/// Удаление, ждущее подтверждения (UI-M1, HIG: необратимое действие подтверждается, «Удалить» — destructive, не по умолчанию).
struct PendingDelete: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let action: () -> Void
}

extension View {
    /// Одно окно подтверждения удаления на сцену: экраны кладут запрос в `AppModel.pendingRemoval`.
    func deleteConfirmation(_ pending: Binding<PendingDelete?>) -> some View {
        confirmationDialog(pending.wrappedValue?.title ?? "",
                           isPresented: Binding(get: { pending.wrappedValue != nil }, set: { if !$0 { pending.wrappedValue = nil } }),
                           titleVisibility: .visible, presenting: pending.wrappedValue) { d in
            Button(L("Удалить"), role: .destructive) { d.action() }
            Button(L("Отмена"), role: .cancel) {}
        } message: { d in
            Text(d.message)
        }
    }
}
