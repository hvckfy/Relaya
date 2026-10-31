import Foundation
import LocalAuthentication
import RelayaCore

/// Touch ID (или пароль Mac) перед использованием сохранённых паролей из Keychain.
///
/// Проверка на уровне приложения через LocalAuthentication: встроенная биометрия для элементов
/// Keychain требует подписанного приложения с Team ID, а сборки Relaya пока не подписаны.
/// После подтверждения несколько минут не спрашиваем снова.
@MainActor
final class SecretGate {
    static let shared = SecretGate()

    private var unlockedUntil: Date?
    private var pending: Task<Bool, Never>?

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: "touchIDForPasswords") as? Bool ?? true
    }

    /// Сколько минут не спрашивать повторно.
    static var graceMinutes: Int {
        UserDefaults.standard.object(forKey: "touchIDGraceMinutes") as? Int ?? 5
    }

    /// Уже подтверждено (или проверка выключена) — можно брать пароль без запроса.
    var isUnlocked: Bool {
        !Self.enabled || (unlockedUntil.map { $0 > Date() } ?? false)
    }

    /// Есть ли на этом Mac Touch ID (для подписи в настройках).
    static var biometryAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    /// Запрашивает Touch ID / пароль Mac. Параллельные запросы ждут один и тот же системный диалог.
    func authorize(_ reason: String) async -> Bool {
        if isUnlocked { return true }
        if let pending { return await pending.value }
        let task = Task { @MainActor () -> Bool in
            let context = LAContext()
            var error: NSError?
            // Ни Touch ID, ни пароля входа (редкость) — не блокируем работу.
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return true }
            do {
                return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            } catch {
                return false
            }
        }
        pending = task
        let ok = await task.value
        pending = nil
        if ok { unlockedUntil = Date().addingTimeInterval(TimeInterval(Self.graceMinutes * 60)) }
        return ok
    }

    /// Сбросить подтверждение (например, при блокировке экрана).
    func lock() { unlockedUntil = nil }
}
