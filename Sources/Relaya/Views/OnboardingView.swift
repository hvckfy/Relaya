import SwiftUI
import RelayaCore

/// Первый запуск (docs/design/Onboarding1–3, UI_SPEC 3.1).
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step = 0
    @State private var keyCount: Int?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: found
                default: permissions
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(28)

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<3) { i in
                        Circle().fill(i == step ? Theme.accBg : Theme.sel).frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if step > 0 {
                    Button(L("Назад")) { step -= 1 }.buttonStyle(.relaya)
                }
                Button(step == 0 ? L("Продолжить") : step == 1 ? L("Готово") : L("Начать работу")) {
                    if step < 2 { step += 1 } else { model.finishOnboarding() }
                }
                .buttonStyle(.relayaPrimary)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 0.5) }
        }
        .frame(width: 560, height: 440)
        .background(Theme.bg)
        .foregroundStyle(Theme.tx)
        .font(.system(size: 13))
        .task { keyCount = await KeyScanner.scan().count }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 36))
                .foregroundStyle(Theme.acc)
            (Text(L("Ваши ключи живут в ")) + Text("~/.ssh").font(.system(size: 22, weight: .bold, design: .monospaced)) + Text(L(", а не у нас")))
                .font(.system(size: 22, weight: .bold))
            Text(L("Relaya читает ваш ~/.ssh/config и ключи как есть. Любое изменение файлов или сервера мы покажем заранее и применим только после подтверждения."))
                .foregroundStyle(Theme.tx2)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                bullet(L("Нет своего хранилища и облачной синхронизации"))
                bullet(L("Пароли и passphrase — только в Keychain"))
                bullet(L("Diff и бэкап перед каждой правкой config"))
            }
        }
    }

    private var found: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Нашли в ~/.ssh")).font(.system(size: 22, weight: .bold))
            Text(L("%@ %@ в ~/.ssh/config и %@ %@. Только чтение: ничего не копируется.", "\(model.hosts.count)", "\(plural(model.hosts.count, L("хост"), L("хоста"), L("хостов")))", "\(keyCount.map(String.init) ?? "…")", "\(plural(keyCount ?? 0, L("ключ"), L("ключа"), L("ключей")))"))
                .foregroundStyle(Theme.tx2)
            if model.hosts.isEmpty {
                Text(L("Хостов пока нет — добавьте первый кнопкой «Хост» в тулбаре."))
                    .foregroundStyle(Theme.tx2)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.hosts) { h in
                            HStack {
                                Text(h.alias).fontWeight(.medium)
                                Text(h.subtitle).font(.system(size: 11)).foregroundStyle(Theme.tx2)
                                Spacer()
                                ForEach(h.tags.prefix(3), id: \.self) { TagChip(tag: $0) }
                            }
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 200)
                .background(Theme.bg2, in: .rect(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Как это работает")).font(.system(size: 22, weight: .bold))
            permission(L("Доступ к ~/.ssh"), L("Читать config и ключи, записывать изменения после вашего подтверждения. Копия config перед правкой — в config.bak."), "folder")
            permission("Keychain", L("Пароли серверов и passphrase ключей. macOS спросит разрешение при первом обращении."), "key")
            permission(L("Системный ssh"), L("Подключения идут через /usr/bin/ssh — ~/.ssh/config, ssh-agent и ProxyJump работают как в Terminal.app."), "terminal")
        }
    }

    private func bullet(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .labelStyle(.titleAndIcon)
            .foregroundStyle(Theme.tx)
            .symbolRenderingMode(.multicolor)
    }

    private func permission(_ title: String, _ detail: String, _ icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(Theme.acc).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.tx2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let n10 = n % 10, n100 = n % 100
        if n10 == 1 && n100 != 11 { return one }
        if (2...4).contains(n10) && !(12...14).contains(n100) { return few }
        return many
    }
}
