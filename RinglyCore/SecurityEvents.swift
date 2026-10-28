import Foundation
import CryptoKit

// События безопасности: смена identity контакта (≈ «изменился код безопасности» в Signal/WhatsApp).
// Принимаем новую identity (не блокируем доставку), но предупреждаем пользователя в чате.
enum SecurityEvents {
    private static let key = "identityChangedUserIds"

    static func recordIdentityChange(userId: String) {
        var s = Set(AppGroup.defaults.stringArray(forKey: key) ?? [])
        s.insert(userId)
        AppGroup.defaults.set(Array(s), forKey: key)
    }

    static func hasIdentityChanged(_ userId: String) -> Bool {
        (AppGroup.defaults.stringArray(forKey: key) ?? []).contains(userId)
    }

    // ---- диагностика: почему предупреждение возвращается после «Ок» ----
    //
    // Смену identity чаще всего записывает расширение уведомлений (оно расшифровывает входящие), а у
    // него журнала нет. Поэтому события копятся в App Group, а приложение переносит их в журнал
    // скрытого меню (drainLog). В журнале — ничего чувствительного: ни кто собеседник, ни отпечатков
    // ключа. Только суть: ключ этого устройства уже встречался («вернулся прежний» — значит, где-то
    // живёт старый ключ и два значения перебивают друг друга) или он новый. Сравнение — тут же, по
    // хэшам в App Group; в журнал они не попадают.
    private static let logKey = "identityChangeLog"
    private static let seenKey = "identitySeenHashes"

    static func recordIdentityChange(userId: String, deviceId: UInt32, old: Data, new: Data) {
        recordIdentityChange(userId: userId)

        let slot = hash(Data("\(userId)-\(deviceId)".utf8))
        var seen = AppGroup.defaults.dictionary(forKey: seenKey) as? [String: [String]] ?? [:]
        var known = seen[slot] ?? []
        let returned = known.contains(hash(new))
        known = Array((known + [hash(old), hash(new)]).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.suffix(5))
        seen[slot] = known
        AppGroup.defaults.set(seen, forKey: seenKey)

        let source = Bundle.main.bundleURL.pathExtension == "appex" ? "уведомления" : "приложение"
        let time = Date().formatted(date: .omitted, time: .standard)
        let line = "🔒 ключ собеседника (устройство \(deviceId)) сменился: " +
            (returned ? "вернулся прежний ключ" : "новый ключ") + " [\(source), \(time)]"
        var log = AppGroup.defaults.stringArray(forKey: logKey) ?? []
        log.append(line)
        AppGroup.defaults.set(Array(log.suffix(30)), forKey: logKey)
    }

    // забрать накопленное (для журнала приложения); после чтения очищается
    static func drainLog() -> [String] {
        let log = AppGroup.defaults.stringArray(forKey: logKey) ?? []
        AppGroup.defaults.removeObject(forKey: logKey)
        return log
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func acknowledge(_ userId: String) {
        var s = Set(AppGroup.defaults.stringArray(forKey: key) ?? [])
        s.remove(userId)
        AppGroup.defaults.set(Array(s), forKey: key)
    }
}
