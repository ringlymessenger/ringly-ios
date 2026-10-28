import SwiftUI
import Combine
import LocalAuthentication
import CryptoKit
import Security

// Код-пароль на вход в приложение — как в Telegram: свой 4-значный код (не код телефона), по желанию
// Face ID / Touch ID вместо ввода, автоблокировка через выбранное время после сворачивания.
//
// Модель угрозы — человек с разблокированным телефоном в руках. От того, кто вытащит данные с
// устройства, код не защищает: переписка и так зашифрована SQLCipher-ключом, а не этим кодом.
//
// Решения (согласованы с пользователем):
//  • код восстановить нельзя; забыл — «Выйти из аккаунта» прямо с экрана блокировки (полная очистка,
//    как обычный выход);
//  • подбор тормозится растущими паузами после 5 ошибок, данные НЕ стираются;
//  • уведомления не трогаем — их видимость на заблокированном телефоне регулирует сама iOS.
//
// Блокировка рисуется в ОТДЕЛЬНОМ окне поверх всех остальных: экран звонка, просмотрщик медиа и шиты
// живут в своих контроллерах, и оверлей внутри SwiftUI-дерева их бы не накрыл.
@MainActor
final class AppLock: ObservableObject {
    static let shared = AppLock()

    enum Phase { case unlocked, covered, locked }

    @Published private(set) var phase: Phase = .unlocked
    @Published private(set) var isEnabled: Bool
    @Published var biometricsEnabled: Bool { didSet { defaults.set(biometricsEnabled, forKey: Keys.biometrics) } }
    @Published var timeout: Timeout { didSet { defaults.set(timeout.rawValue, forKey: Keys.timeout) } }

    // Автоблокировка — те же варианты, что в Telegram
    enum Timeout: Int, CaseIterable, Identifiable {
        case immediately = 0, oneMinute = 60, fiveMinutes = 300, oneHour = 3600, fiveHours = 18000
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .immediately: return L("Сразу")
            case .oneMinute:   return L("Через 1 минуту")
            case .fiveMinutes: return L("Через 5 минут")
            case .oneHour:     return L("Через 1 час")
            case .fiveHours:   return L("Через 5 часов")
            }
        }
    }

    private let defaults = UserDefaults.standard
    private var backgroundedAt: Date?
    private var window: UIWindow?

    private enum Keys {
        static let enabled = "appLock.enabled"
        static let biometrics = "appLock.biometrics"
        static let timeout = "appLock.timeout"
        static let failed = "appLock.failed"
        static let lockoutStart = "appLock.lockoutStart"
        static let lockoutSeconds = "appLock.lockoutSeconds"
        static let domainState = "appLock.bioDomainState"
    }

    private init() {
        // ⚠️ Keychain переживает переустановку приложения, UserDefaults — нет. Без этой сверки код от
        // прошлой установки требовался бы в чистом приложении, где уже нечего защищать.
        //
        // ⚠️ Включён ли код, решает ТОЛЬКО флаг в UserDefaults, а не наличие записи в Keychain: запись
        // доступна лишь при разблокированном телефоне (WhenUnlocked). Раньше здесь стояло
        // `flag && exists`, и запуск при залоченном телефоне (входящий звонок, фоновое пробуждение)
        // читал «кода нет» — блокировка не вставала до перезапуска приложения.
        let flag = defaults.bool(forKey: Keys.enabled)
        if !flag { PasscodeKeychain.clear() }
        isEnabled = flag
        biometricsEnabled = defaults.bool(forKey: Keys.biometrics)
        timeout = Timeout(rawValue: defaults.object(forKey: Keys.timeout) as? Int ?? 60) ?? .oneMinute

        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppLock.shared.didEnterBackground() }
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppLock.shared.willEnterForeground() }
        }
    }

    // Холодный старт: код включён → сразу заблокировано. Зовётся с корня (RootView.onAppear) —
    // раньше окна сцены ещё нет.
    func start() {
        dropIfCodeLost()
        guard isEnabled, phase == .unlocked else { return }
        setPhase(.locked)
    }

    // Флаг есть, а кода в Keychain нет (например, восстановили бэкап на другой телефон: UserDefaults
    // переезжают, а запись «только этого устройства» — нет). Такой код не ввести никак — выключаем,
    // а не запираем человека навсегда. Проверять можно только при доступном Keychain: на залоченном
    // телефоне запись просто не читается, и это НЕ значит, что её нет.
    private func dropIfCodeLost() {
        guard isEnabled, UIApplication.shared.isProtectedDataAvailable, !PasscodeKeychain.exists else { return }
        disable()
    }

    // --- жизненный цикл ---
    // ⚠️ Решения принимаются по ФОНУ, а не по .inactive: неактивной сцена становится и от экрана
    // CallKit, и от Пункта управления, и от системного запроса Face ID — блокироваться на этом нельзя.

    private func didEnterBackground() {
        guard isEnabled else { return }
        backgroundedAt = Date()
        // Снимок для переключателя приложений iOS делает ПОСЛЕ этого вызова — шторка должна стоять уже
        // сейчас, иначе переписку видно в списке открытых приложений.
        if phase == .unlocked { setPhase(timeout == .immediately ? .locked : .covered) }
    }

    private func willEnterForeground() {
        dropIfCodeLost()
        guard isEnabled, phase == .covered else { return }
        let away = backgroundedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        setPhase(away >= Double(timeout.rawValue) ? .locked : .unlocked)
    }

    // --- код ---

    func enable(code: String) {
        PasscodeKeychain.save(code)
        defaults.set(true, forKey: Keys.enabled)
        resetFailures()
        isEnabled = true
    }

    func changeCode(_ code: String) {
        PasscodeKeychain.save(code)
    }

    func disable() {
        PasscodeKeychain.clear()
        for key in [Keys.enabled, Keys.biometrics, Keys.domainState, Keys.failed, Keys.lockoutStart, Keys.lockoutSeconds] {
            defaults.removeObject(forKey: key)
        }
        biometricsEnabled = false
        isEnabled = false
        setPhase(.unlocked)
    }

    // Выход из аккаунта стирает и код: новый владелец аккаунта не должен упираться в чужой код.
    func reset() { disable() }

    func verify(_ code: String) -> Bool { PasscodeKeychain.matches(code) }

    // Попытка разблокировать кодом. Ошибки копятся и после пятой включают растущую паузу.
    func unlock(code: String) -> Bool {
        guard lockoutRemaining == 0 else { return false }
        if PasscodeKeychain.matches(code) {
            resetFailures()
            setPhase(.unlocked)
            return true
        }
        let failed = defaults.integer(forKey: Keys.failed) + 1
        defaults.set(failed, forKey: Keys.failed)
        if failed >= 5 {
            let steps: [Double] = [30, 60, 300, 900, 3600]
            defaults.set(steps[min(failed - 5, steps.count - 1)], forKey: Keys.lockoutSeconds)
            defaults.set(Date().timeIntervalSince1970, forKey: Keys.lockoutStart)
        }
        objectWillChange.send()

        return false
    }

    // Сколько ещё ждать до следующей попытки. Если часы перевели НАЗАД (время раньше начала паузы),
    // пауза начинается заново — иначе её снимал бы перевод часов.
    var lockoutRemaining: TimeInterval {
        let seconds = defaults.double(forKey: Keys.lockoutSeconds)
        guard seconds > 0 else { return 0 }
        let start = defaults.double(forKey: Keys.lockoutStart)
        let now = Date().timeIntervalSince1970
        if now < start {
            defaults.set(now, forKey: Keys.lockoutStart)
            return seconds
        }

        return max(0, seconds - (now - start))
    }

    var failedAttempts: Int { defaults.integer(forKey: Keys.failed) }

    private func resetFailures() {
        defaults.removeObject(forKey: Keys.failed)
        defaults.removeObject(forKey: Keys.lockoutStart)
        defaults.removeObject(forKey: Keys.lockoutSeconds)
    }

    // --- биометрия ---

    enum Biometry { case none, faceID, touchID, opticID }

    var biometry: Biometry {
        let ctx = LAContext()
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return .none }
        switch ctx.biometryType {
        case .faceID:  return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        default:       return .none
        }
    }

    var biometryTitle: String {
        switch biometry {
        case .faceID:  return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        case .none:    return ""
        }
    }

    var biometryIcon: String {
        switch biometry {
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        default:       return "faceid"
        }
    }

    // Включение — только после успешной проверки: запоминаем набор лиц/отпечатков на этот момент.
    func enableBiometrics() async -> Bool {
        let ctx = LAContext()
        ctx.localizedFallbackTitle = ""
        guard (try? await ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                             localizedReason: L("Разблокировка Ringly"))) == true else { return false }
        defaults.set(ctx.evaluatedPolicyDomainState, forKey: Keys.domainState)
        biometricsEnabled = true

        return true
    }

    // Разблокировка биометрией. ⚠️ Если в телефон добавили новое лицо или отпечаток, биометрия
    // отключается и нужен код: иначе любой, кто знает пароль телефона, добавил бы своё лицо и вошёл
    // в Ringly, минуя наш код.
    enum BiometricResult { case unlocked, failed, enrollmentChanged }

    func unlockWithBiometrics() async -> BiometricResult {
        guard biometricsEnabled, biometry != .none, lockoutRemaining == 0 else { return .failed }
        let ctx = LAContext()
        ctx.localizedFallbackTitle = L("Ввести код")
        guard (try? await ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                             localizedReason: L("Разблокировка Ringly"))) == true else { return .failed }
        let saved = defaults.data(forKey: Keys.domainState)
        if let saved, saved != ctx.evaluatedPolicyDomainState {
            biometricsEnabled = false
            defaults.removeObject(forKey: Keys.domainState)
            return .enrollmentChanged
        }
        resetFailures()
        setPhase(.unlocked)

        return .unlocked
    }

    // «Забыли код?» — восстановления нет: выходим из аккаунта с полной очисткой, как обычный «Выйти».
    func forgotCode() {
        AppViewModel.shared.logout(wipeLocal: true)   // внутри зовёт reset() → окно снимается
    }

    // --- окно ---

    private func setPhase(_ new: Phase) {
        // в журнал звонков (служебное меню): блокировка рисуется своим окном поверх всего, и при
        // разборе звонков нужно видеть, когда она вставала и снималась
        CallDiag.log("🔒 AppLock \(phase) → \(new), app=\(UIApplication.shared.applicationState.rawValue)")
        phase = new
        if new == .unlocked { hideWindow() } else { showWindow() }
    }

    private func showWindow() {
        if window == nil {
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState != .unattached }) ?? UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first else { return }
            let w = UIWindow(windowScene: scene)
            w.windowLevel = .alert + 1                       // выше алертов и полноэкранных модалок
            let host = UIHostingController(rootView: AppLockScreen().preferredColorScheme(.dark))
            host.view.backgroundColor = .black
            w.rootViewController = host
            window = w
        }
        // клавиатура живёт в своём окне выше нашего — убираем её, иначе она висела бы поверх блокировки
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for w in scene.windows where w !== window { w.endEditing(true) }
        }
        window?.isHidden = false
        window?.makeKeyAndVisible()
    }

    private func hideWindow() {
        guard let w = window else { return }
        w.isHidden = true
        window = nil
        w.windowScene?.windows.first { $0 !== w && $0.windowLevel == .normal }?.makeKey()
    }
}

// Код хранится НЕ в открытом виде: HMAC-SHA256 с солью, в Keychain только этого устройства.
// Честно: 4 цифры — это 10 000 вариантов, от перебора хэша они не спасают. Защиту дают Keychain
// (ключи не покидают устройство) и паузы между попытками в интерфейсе; хэш лишь не держит код открытым.
private enum PasscodeKeychain {
    private static let account = "appLockPasscode"

    static var exists: Bool { read() != nil }

    static func save(_ code: String) {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        clear()
        var attrs = base()
        attrs[kSecValueData as String] = salt + digest(code, salt: salt)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func matches(_ code: String) -> Bool {
        guard let data = read(), data.count > 16 else { return false }
        let salt = data.prefix(16), stored = data.dropFirst(16)

        return digest(code, salt: Data(salt)) == Data(stored)
    }

    static func clear() { SecItemDelete(base() as CFDictionary) }

    private static func digest(_ code: String, salt: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(code.utf8), using: SymmetricKey(data: salt)))
    }

    private static func base() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account]
    }

    private static func read() -> Data? {
        var q = base()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }

        return result as? Data
    }
}
