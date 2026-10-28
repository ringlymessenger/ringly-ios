import SwiftUI

// Профиль → Код-пароль. Когда код включён, сами настройки открываются только после ввода кода —
// как в Telegram: иначе любой с разблокированным телефоном просто выключил бы защиту.
struct PasscodeSettingsView: View {
    @ObservedObject private var lock = AppLock.shared
    @State private var verified = false
    @State private var setup: SetupMode?
    @State private var confirmDisable = false
    @State private var biometryFailed = false

    private enum SetupMode: Identifiable {
        case enable, change
        var id: Int { self == .enable ? 0 : 1 }
    }

    var body: some View {
        Group {
            if lock.isEnabled && !verified {
                PasscodePad(title: L("Введите код-пароль")) { code in
                    guard lock.verify(code) else { return false }
                    verified = true
                    return true
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                settings
            }
        }
        .background(AppColor.background.ignoresSafeArea())
        .navigationTitle(L("Код-пароль"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $setup) { mode in
            PasscodeSetupFlow(isChange: mode == .change) { code in
                if mode == .enable { lock.enable(code: code) } else { lock.changeCode(code) }
                verified = true
                setup = nil
            }
        }
        .alert(L("Выключить код-пароль?"), isPresented: $confirmDisable) {
            Button(L("Выключить"), role: .destructive) { lock.disable() }
            Button(L("Отмена"), role: .cancel) {}
        }
        .alert(L("Не удалось включить %@", lock.biometryTitle), isPresented: $biometryFailed) {
            Button("OK", role: .cancel) {}
        }
    }

    private var settings: some View {
        ScrollView {
            VStack(spacing: 16) {
                if lock.isEnabled { enabledCards } else { disabledCard }
                explanation
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
    }

    private var disabledCard: some View {
        Button { setup = .enable } label: {
            HStack(spacing: 12) {
                Image(systemName: "lock.fill").foregroundStyle(AppColor.subtext).frame(width: 22)
                Text(L("Включить код-пароль")).foregroundStyle(AppColor.brand)
                Spacer()
            }
            .padding(14)
            .background(AppColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var enabledCards: some View {
        VStack(spacing: 0) {
            if lock.biometry != .none {
                Toggle(isOn: Binding(get: { lock.biometricsEnabled }, set: setBiometrics)) {
                    row(L("Разблокировка %@", lock.biometryTitle), icon: lock.biometryIcon)
                }
                .tint(.blue)
                .padding(14)
                Divider().padding(.leading, 48)
            }
            HStack {
                row(L("Автоблокировка"), icon: "timer")
                Spacer()
                Picker(L("Автоблокировка"), selection: $lock.timeout) {
                    ForEach(AppLock.Timeout.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .tint(AppColor.subtext)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))

        VStack(spacing: 0) {
            Button { setup = .change } label: {
                row(L("Сменить код-пароль"), icon: "key.fill").frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, 48)
            Button { confirmDisable = true } label: {
                row(L("Выключить код-пароль"), icon: "lock.open.fill", tint: .red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
            .buttonStyle(.plain)
        }
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func row(_ title: String, icon: String, tint: Color = AppColor.text) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(tint == AppColor.text ? AppColor.subtext : tint).frame(width: 22)
            Text(title).foregroundStyle(tint)
        }
    }

    private var explanation: some View {
        Text(L("Ringly будет спрашивать код-пароль при открытии. Он отличается от кода телефона: кто знает пароль от телефона, в Ringly без вашего кода не войдёт.\n\nЕсли забыть код, восстановить его нельзя — останется только выйти из аккаунта: история чатов удалится с этого устройства. Если включена копия в iCloud, переписка вернётся после входа по PIN-коду."))
            .font(.footnote)
            .foregroundStyle(AppColor.subtext)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    // Включение биометрии — только после успешной проверки лицом/пальцем
    private func setBiometrics(_ on: Bool) {
        guard on else { lock.biometricsEnabled = false; return }
        Task { if await !lock.enableBiometrics() { biometryFailed = true } }
    }
}

// Новый код: ввести и повторить. Не совпали — начать заново.
private struct PasscodeSetupFlow: View {
    let isChange: Bool
    let onDone: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var first: String?
    @State private var mismatch = false

    var body: some View {
        NavigationStack {
            PasscodePad(title: first == nil ? (isChange ? L("Введите новый код-пароль") : L("Придумайте код-пароль"))
                                            : L("Повторите код-пароль"),
                        message: mismatch ? L("Коды не совпадают, попробуйте ещё раз") : nil,
                        messageIsError: mismatch) { code in
                guard let first else {
                    self.first = code
                    mismatch = false
                    return true
                }
                guard code == first else {
                    self.first = nil
                    mismatch = true
                    return false
                }
                onDone(code)
                return true
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppColor.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Отмена")) { dismiss() } }
            }
        }
    }
}
