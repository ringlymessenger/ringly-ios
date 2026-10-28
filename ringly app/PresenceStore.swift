import Foundation
import Combine

// Статус присутствия собеседника (как в Telegram: «в сети» / «был(а) в сети …»).
// Метаданные, НЕ E2EE: сервер и так знает presence для маршрутизации. Отдаётся только тем,
// с кем есть общая беседа (авторизация на бэке), — не оракул слежки. См. docs/presence-backend.md.
struct PresenceState: Equatable {
    var online: Bool
    var lastSeenAt: Date?
}

@MainActor
final class PresenceStore: ObservableObject {
    static let shared = PresenceStore()
    private init() {}

    // userId → его статус. Обновляется push-событиями presence по WebSocket.
    @Published private(set) var states: [String: PresenceState] = [:]

    func apply(userId: String, online: Bool, lastSeenAt: Date?) {
        states[userId] = PresenceState(online: online, lastSeenAt: lastSeenAt)
    }
}

// Форматирование статуса для шапки чата. Гендер собеседника неизвестен → по-русски «был(а)».
enum PresenceFormatter {
    static func text(_ state: PresenceState?) -> String {
        guard let state else { return "" }        // ещё не знаем — ничего не показываем
        if state.online { return L("в сети") }
        guard let seen = state.lastSeenAt else { return L("не в сети") }

        return L("был(а) в сети %@", relative(seen))
    }

    private static func relative(_ date: Date) -> String {
        let sec = Date().timeIntervalSince(date)
        if sec < 60 { return L("только что") }
        // «мин» и «min» не склоняются — множественное число здесь не нужно ни в одном из языков
        if sec < 3600 { return L("%d мин назад", Int(sec / 60)) }

        // Локаль форматтеров идёт за языком интерфейса, а не за системой: иначе при английском
        // интерфейсе месяц печатался бы по-русски.
        let locale = Locale(identifier: Localization.resolved == .ru ? "ru_RU" : "en_US")
        let cal = Calendar.current
        let hm = DateFormatter(); hm.locale = locale; hm.dateFormat = "HH:mm"
        if cal.isDateInToday(date)     { return L("сегодня в %@", hm.string(from: date)) }
        if cal.isDateInYesterday(date) { return L("вчера в %@", hm.string(from: date)) }
        let d = DateFormatter(); d.locale = locale; d.dateFormat = "d MMM"

        return d.string(from: date)               // «2 июл» / «2 Jul»
    }
}
