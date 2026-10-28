import Foundation

// Общий контейнер приложения и Notification Service Extension.
// База SQLCipher, ключ БД, device-токен и process-local настройки живут здесь,
// чтобы оба процесса видели одно и то же состояние.
enum AppGroup {
    // Dev (Debug) и прод (Release) — РАЗНЫЕ App Group, чтобы два установленных рядом приложения
    // (dev + TestFlight) не делили один контейнер (БД/keychain/настройки) и не портили состояние друг друга.
    #if DEBUG
    static let identifier = "group.com.reguzov.ringly.dev"
    #else
    static let identifier = "group.com.reguzov.ringly"
    #endif

    // App Group-идентификатор iOS автоматически считает валидной keychain access-group
    // (без team-префикса), поэтому используем его же для общего Keychain — не нужен $(AppIdentifierPrefix).
    static let keychainAccessGroup = identifier

    // shared-контейнер на диске (тут лежит ringly.sqlite и lock-файлы).
    // На реальном девайсе группа резолвится — приложение и NSE делят файлы.
    // Фолбэк на Application Support — чтобы приложение не падало там, где группа недоступна
    // (напр. симулятор без provisioning); NSE там всё равно не запускается.
    static var containerURL: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
            return url
        }
        print("⚠️ App Group \(identifier) недоступна — фолбэк на Application Support (sharing с NSE не работает)")
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // общие UserDefaults (process-local настройки: protocolDeviceId, myUserId, security-события)
    static let defaults: UserDefaults = UserDefaults(suiteName: identifier) ?? .standard
}
