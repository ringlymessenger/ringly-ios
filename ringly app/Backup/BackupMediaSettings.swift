import Foundation
import UIKit

// Что из медиа попадает в копию iCloud (docs/icloud-backup.md §2). Локально, как остальные настройки.
// По умолчанию — всё, без ограничения размера, только по Wi-Fi, зарядка не обязательна.
enum BackupMediaSettings {
    enum Mode: String, CaseIterable, Identifiable {
        case all, photos, none
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all:    return L("Фото и видео")
            case .photos: return L("Только фото")
            case .none:   return L("Не сохранять")
            }
        }
    }

    // 0 — без ограничения. Варианты только меньше потолка медиа (MediaProcessor.maxBytes, 25 МБ — тот же
    // лимит у сервера): больших файлов в переписке не бывает, и «до 50/100 МБ» ничего бы не ограничивало.
    static let sizeOptions = [5, 10, 0]

    private enum Keys {
        static let mode = "icloudBackup.media.mode"
        static let maxMB = "icloudBackup.media.maxMB"
        static let cellular = "icloudBackup.media.cellular"
        static let charging = "icloudBackup.media.chargingOnly"
    }
    private static var defaults: UserDefaults { .standard }

    static var mode: Mode {
        get { Mode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .all }
        set { defaults.set(newValue.rawValue, forKey: Keys.mode) }
    }
    static var maxMB: Int {
        // значение, которого больше нет среди вариантов (50/100 из первой версии), — «без ограничения»
        get {
            let saved = defaults.integer(forKey: Keys.maxMB)
            return sizeOptions.contains(saved) ? saved : 0
        }
        set { defaults.set(newValue, forKey: Keys.maxMB) }
    }
    static var cellular: Bool {
        get { defaults.bool(forKey: Keys.cellular) }
        set { defaults.set(newValue, forKey: Keys.cellular) }
    }
    static var chargingOnly: Bool {
        get { defaults.bool(forKey: Keys.charging) }
        set { defaults.set(newValue, forKey: Keys.charging) }
    }

    static func wants(isVideo: Bool, bytes: Int) -> Bool {
        switch mode {
        case .none: return false
        case .photos where isVideo: return false
        default: break
        }
        return maxMB == 0 || bytes <= maxMB * 1024 * 1024
    }

    // Wi-Fi — тем же признаком, что у автозагрузки (usesInterfaceType, не isExpensive: тот true и
    // для персональной точки доступа, а с неё как раз качать гигабайты не надо)
    static var networkAllowed: Bool { cellular || MediaSettings.shared.isOnWiFi }

    static var powerAllowed: Bool {
        guard chargingOnly else { return true }
        UIDevice.current.isBatteryMonitoringEnabled = true
        return [.charging, .full].contains(UIDevice.current.batteryState)
    }

    static func sizeTitle(_ mb: Int) -> String {
        mb == 0 ? L("Без ограничения") : String(format: L("До %d МБ"), mb)
    }
}
