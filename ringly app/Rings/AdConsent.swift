import Foundation
import IronSource

// Согласие на персонализированную рекламу (GDPR) — только для региона устройства ЕС/ЕЭЗ, UK и CH.
// Решение владельца: системный алерт перед первым запуском рекламы, переключатель на экране Rings,
// регион — из настроек iPhone (без IP и без запросов к серверу; неточно, но ничего не утекает).
// Отказ рекламу НЕ выключает: Unity показывает неперсонализированную, Rings начисляются как обычно.
// Пока пользователь из ЕС не ответил, рекламный SDK не запускается вовсе (RewardedAdController.prepare).
enum AdConsent {
    private static let key = "ads.gdprConsent"

    // ЕС-27 + Исландия, Лихтенштейн, Норвегия (ЕЭЗ) + Великобритания и Швейцария
    private static let regions: Set<String> = [
        "AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR", "DE", "GR", "HU", "IE", "IT",
        "LV", "LT", "LU", "MT", "NL", "PL", "PT", "RO", "SK", "SI", "ES", "SE",
        "IS", "LI", "NO", "GB", "CH"
    ]

    static var required: Bool {
        guard let region = Locale.current.region?.identifier else { return false }
        return regions.contains(region)
    }

    // nil — ещё не спрашивали
    static var granted: Bool? {
        UserDefaults.standard.object(forKey: key) as? Bool
    }

    static var needsAnswer: Bool { required && granted == nil }

    static func set(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: key)
        apply()
    }

    // передать ответ в LevelPlay; вне ЕС флаг не ставим — там действуют настройки сети по умолчанию
    static func apply() {
        guard required, let granted else { return }
        LPMPrivacySettings.setGDPRConsent(granted)
    }
}
