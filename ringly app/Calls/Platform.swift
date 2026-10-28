import Foundation

// Глобальные переключатели звонков.
enum Calls {
    static let useCallKit = true   // нативный входящий (CallKit) + VoIP-пуш на залок/фон
}

enum Platform {
    // CallKit/VoIP-пуши имеют смысл только на настоящем iOS-устройстве.
    // Симулятор CallKit-UI не показывает; Mac (Designed for iPad / Catalyst) — тоже.
    // Там используем внутренний оверлей и не регистрируем VoIP-токен.
    static var supportsCallKit: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return !ProcessInfo.processInfo.isiOSAppOnMac && !ProcessInfo.processInfo.isMacCatalystApp
        #endif
    }
}
