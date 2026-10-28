import SwiftUI

// Ввод 4-значного кода — точки и цифровая клавиатура, как на экране кода iOS и в Telegram.
// Один компонент на всё: экран блокировки, включение/смена кода, вход в настройки кода.
struct PasscodePad: View {
    static let length = 4

    let title: String
    var message: String? = nil                 // ошибка / пауза — под заголовком
    var messageIsError = false
    var disabled = false                       // пауза после ошибок: клавиши не нажимаются
    var biometryIcon: String? = nil            // кнопка Face ID / Touch ID слева от нуля
    var onBiometry: (() -> Void)? = nil
    // false — код не подошёл: точки трясутся и очищаются
    let onComplete: (String) -> Bool

    @State private var code = ""
    @State private var shakes = 0

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "lock.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(AppColor.brand)
                .padding(.bottom, 18)
            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(message ?? " ")
                .font(.footnote)
                .foregroundStyle(messageIsError ? Color.red : AppColor.subtext)
                .multilineTextAlignment(.center)
                .frame(minHeight: 36, alignment: .top)
                .padding(.top, 6)
                .padding(.horizontal, 24)
            dots
                .modifier(Shake(animatableData: CGFloat(shakes)))
                .padding(.bottom, 40)
            keypad
                .opacity(disabled ? 0.4 : 1)
                .allowsHitTesting(!disabled)
        }
    }

    private var dots: some View {
        HStack(spacing: 22) {
            ForEach(0..<Self.length, id: \.self) { i in
                Circle()
                    .strokeBorder(AppColor.text, lineWidth: 1.5)
                    .background(Circle().fill(i < code.count ? AppColor.text : .clear))
                    .frame(width: 14, height: 14)
            }
        }
    }

    private var keypad: some View {
        VStack(spacing: 16) {
            ForEach([[1, 2, 3], [4, 5, 6], [7, 8, 9]], id: \.self) { row in
                HStack(spacing: 26) { ForEach(row, id: \.self) { digitKey($0) } }
            }
            HStack(spacing: 26) {
                if let biometryIcon, let onBiometry {
                    Button(action: onBiometry) {
                        Image(systemName: biometryIcon).font(.system(size: 30)).foregroundStyle(AppColor.text)
                            .frame(width: 78, height: 78)
                    }
                    .accessibilityLabel(AppLock.shared.biometryTitle)
                } else {
                    Color.clear.frame(width: 78, height: 78)
                }
                digitKey(0)
                Button { if !code.isEmpty { code.removeLast() } } label: {
                    Image(systemName: "delete.left").font(.system(size: 24)).foregroundStyle(AppColor.text)
                        .frame(width: 78, height: 78)
                }
                .accessibilityLabel(L("Удалить"))
                .opacity(code.isEmpty ? 0 : 1)
            }
        }
        .buttonStyle(KeyStyle())
    }

    private func digitKey(_ d: Int) -> some View {
        Button { type(d) } label: {
            Text("\(d)").font(.system(size: 34, weight: .regular)).foregroundStyle(AppColor.text)
                .frame(width: 78, height: 78)
                .background(AppColor.fill, in: Circle())
        }
    }

    private func type(_ d: Int) {
        guard code.count < Self.length else { return }
        code.append(String(d))
        guard code.count == Self.length else { return }
        let entered = code
        // точка дорисовывается, и только потом проверка — иначе последнюю цифру не видно вовсе
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if !onComplete(entered) {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                withAnimation(.linear(duration: 0.4)) { shakes += 1 }
            }
            code = ""
        }
    }
}

// Нажатая клавиша подсвечивается, как на экране кода iOS
private struct KeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.5 : 1)
            .contentShape(Circle())
    }
}

// Тряска точек при неверном коде
private struct Shake: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(animatableData * .pi * 4), y: 0))
    }
}

// Содержимое окна блокировки: шторка (свёрнуто, время автоблокировки ещё не вышло — только чтобы
// переписку не было видно в переключателе приложений) или ввод кода.
struct AppLockScreen: View {
    @ObservedObject private var lock = AppLock.shared
    @State private var message: String?
    @State private var messageIsError = false
    @State private var confirmForgot = false
    @State private var savingCopy = false       // досохраняем копию в iCloud перед выходом
    @State private var saveCopyFailed = false
    @State private var promptPending = true     // Face ID — сам один раз на каждое возвращение
    @State private var prompting = false

    var body: some View {
        ZStack {
            AppColor.background.ignoresSafeArea()
            if lock.phase == .locked {
                lockedContent
            } else {
                Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(AppColor.brand)
            }
        }
        .onAppear { autoPrompt() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            promptPending = true
        }
        // ⚠️ Запрос Face ID сам делает приложение неактивным и потом снова активным. Поэтому сам он
        // всплывает только раз на возвращение (promptPending), иначе неудачная попытка зациклилась бы.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            autoPrompt()
        }
        .onChange(of: lock.phase) { phase in
            if phase == .locked { autoPrompt() }
        }
        .alert(L("Забыли код-пароль?"), isPresented: $confirmForgot) {
            Button(ICloudBackup.shared.savedCopyDate == nil ? L("Выйти и удалить данные") : L("Выйти"),
                   role: .destructive) {
                // logoutSavingBackup — тот же выход, что lock.forgotCode(), но сперва досохраняет копию
                savingCopy = true
                Task {
                    let ok = await AppViewModel.shared.logoutSavingBackup()
                    savingCopy = false
                    if !ok { saveCopyFailed = true }
                }
            }
            Button(L("Отмена"), role: .cancel) {}
        } message: {
            if ICloudBackup.shared.savedCopyDate != nil {
                Text(L("Код-пароль восстановить нельзя. Можно выйти из аккаунта: перед выходом копия в iCloud обновится, и переписка вернётся после входа по PIN-коду. С этого устройства история удалится."))
            } else {
                Text(L("Код-пароль восстановить нельзя. Можно выйти из аккаунта — история чатов на этом устройстве будет удалена, как при обычном выходе."))
            }
        }
        .alert(L("Не удалось обновить копию в iCloud"), isPresented: $saveCopyFailed) {
            Button(L("Выйти всё равно"), role: .destructive) { lock.forgotCode() }
            Button(L("Отмена"), role: .cancel) {}
        } message: {
            Text(L("Сообщения новее последней копии (%@) будут потеряны. Можно проверить подключение и попробовать ещё раз.",
                   (ICloudBackup.shared.savedCopyDate ?? Date()).formatted(date: .abbreviated, time: .shortened)))
        }
        .overlay {
            if savingCopy {
                ZStack {
                    Color.black.opacity(0.6).ignoresSafeArea()
                    ProgressView(L("Сохраняем переписку в iCloud…")).tint(.white).foregroundStyle(.white)
                }
            }
        }
    }

    private var lockedContent: some View {
        VStack {
            Spacer()
            // секундомер паузы обновляется сам; клавиатура оживает, когда пауза кончилась
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let wait = lock.lockoutRemaining
                PasscodePad(title: L("Введите код-пароль"),
                            message: wait > 0 ? waitText(wait) : message,
                            messageIsError: wait > 0 || messageIsError,
                            disabled: wait > 0,
                            biometryIcon: lock.biometricsEnabled && lock.biometry != .none ? lock.biometryIcon : nil,
                            onBiometry: { runBiometrics() },
                            onComplete: { code in
                                if lock.unlock(code: code) {
                                    message = nil
                                    return true
                                }
                                message = L("Неверный код-пароль")
                                messageIsError = true
                                return false
                            })
            }
            Spacer()
            Button(L("Забыли код-пароль?")) { confirmForgot = true }
                .font(.subheadline)
                .padding(.bottom, 24)
        }
    }

    private func waitText(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        let time = s >= 60 ? String(format: "%d:%02d", s / 60, s % 60) : "\(s) " + L("сек")

        return L("Слишком много попыток. Повторите через %@", time)
    }

    private func autoPrompt() {
        guard promptPending, lock.phase == .locked, UIApplication.shared.applicationState == .active else { return }
        promptPending = false
        runBiometrics()
    }

    private func runBiometrics() {
        guard !prompting, lock.biometricsEnabled, lock.biometry != .none else { return }
        prompting = true
        Task {
            let result = await lock.unlockWithBiometrics()
            prompting = false
            if result == .enrollmentChanged {
                message = L("Лица или отпечатки в телефоне изменились — введите код-пароль. %@ можно включить снова в настройках.", lock.biometryTitle)
                messageIsError = true
            }
        }
    }
}
