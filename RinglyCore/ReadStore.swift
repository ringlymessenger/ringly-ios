import Foundation
import GRDB

// Сводка по беседе для списка чатов: время последней активности (для сортировки, Telegram-style),
// число непрочитанных входящих (для бейджа) и само последнее сообщение (превью под именем).
struct ConvSummary: Equatable {
    let lastAt: Int64
    let unread: Int
    var last: LastMessage? = nil
}

// Последнее сообщение беседы — ровно те поля, что нужны строке списка.
struct LastMessage: Equatable {
    let kind: String
    let text: String          // у медиа — JSON MediaRef (миниатюра), у звонка — JSON CallLog
    let caption: String?
    let isMine: Bool
    let status: MessageStatus
}

// Локальное read-состояние бесед. Непрочитанные считаются локально (E2EE: сервер не знает содержимого),
// как «входящие с sentAt > lastReadAt». Не синкается между устройствами — это чисто UI-состояние.
enum ReadStore {
    private static var db: DatabaseQueue { AppDatabase.shared.dbQueue }

    // отметить беседу прочитанной до самого свежего входящего (вызывать при открытии/просмотре чата).
    // Двигаем lastReadAt только ВВЕРХ, чтобы не «разпрочитать» уже прочитанное.
    static func markRead(conversationId: String) {
        try? db.write { db in
            let maxIn = try Int64.fetchOne(db, sql:
                "SELECT MAX(sentAt) FROM message WHERE conversationId = ? AND isMine = 0",
                arguments: [conversationId])
            guard let upTo = maxIn else { return }   // входящих нет → непрочитанных и так ноль
            try db.execute(sql: """
                INSERT INTO conversation_read (conversationId, lastReadAt) VALUES (?, ?)
                ON CONFLICT(conversationId) DO UPDATE SET lastReadAt = MAX(lastReadAt, excluded.lastReadAt)
                """, arguments: [conversationId, upTo])
        }
    }

    // суммарное число непрочитанных для бейджа иконки. Замьюченные отправители ИСКЛЮЧЕНЫ (Telegram-style:
    // мьют не бейджит). В DIRECT-беседе все входящие — от одного собеседника, поэтому фильтр по
    // senderUserId NOT IN muted_user корректно убирает замьюченные чаты целиком.
    static func totalUnreadBadge() -> Int {
        (try? db.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM message m
                LEFT JOIN conversation_read r ON r.conversationId = m.conversationId
                WHERE m.isMine = 0
                  AND m.sentAt > COALESCE(r.lastReadAt, 0)
                  AND \(countsAsUnread)
                  AND m.senderUserId NOT IN (SELECT userId FROM muted_user)
                """) ?? 0
        }) ?? 0
    }

    // Что вообще может быть непрочитанным. Запись о звонке — только ПРОПУЩЕННЫЙ: принятый или
    // отклонённый ты и так видел на экране звонка, а раньше «Входящий звонок» висел непрочитанным
    // и бейджил иконку, пока не откроешь чат. Итог звонка лежит JSON'ом CallLog в text
    // (JSONEncoder пишет `"outcome":"…"` без пробелов).
    private static let countsAsUnread = """
        (m.kind != 'call' OR m.text LIKE '%"outcome":"unanswered"%')
        """

    // разовый снимок сводок (для рефреша после фоновой доставки из NSE — ValueObservation её не видит).
    static func snapshot() -> [String: ConvSummary] {
        (try? db.read { db -> [String: ConvSummary] in
            let rows = try Row.fetchAll(db, sql: summarySQL)
            var out: [String: ConvSummary] = [:]
            for row in rows { out[row["cid"]] = summary(row) }
            return out
        }) ?? [:]
    }

    // ⚠️ Поля последнего сообщения берутся «голыми» столбцами рядом с MAX(sentAt): SQLite в таком
    // запросе гарантирует, что они придут из той же строки, на которой достигнут максимум. Так
    // превью получается одним проходом, без подзапроса на каждую беседу.
    private static let summarySQL = """
        SELECT m.conversationId AS cid,
               MAX(m.sentAt) AS lastAt,
               m.kind AS kind, m.text AS text, m.caption AS caption, m.isMine AS isMine, m.status AS status,
               SUM(CASE WHEN m.isMine = 0 AND m.sentAt > COALESCE(r.lastReadAt, 0) AND \(countsAsUnread)
                        THEN 1 ELSE 0 END) AS unread
        FROM message m
        LEFT JOIN conversation_read r ON r.conversationId = m.conversationId
        GROUP BY m.conversationId
        """

    private static func summary(_ row: Row) -> ConvSummary {
        let status: String = row["status"] ?? ""
        let last = LastMessage(kind: row["kind"] ?? "text", text: row["text"] ?? "", caption: row["caption"],
                               isMine: row["isMine"] ?? false, status: MessageStatus(rawValue: status) ?? .sent)

        return ConvSummary(lastAt: row["lastAt"] ?? 0, unread: row["unread"] ?? 0, last: last)
    }

    // живой поток сводок по всем беседам: conversationId → {lastAt, unread}.
    // Пере-выдаётся при любом изменении message / conversation_read (пришло сообщение, открыли чат).
    static func observeSummaries() -> AsyncStream<[String: ConvSummary]> {
        AsyncStream { continuation in
            let observation = ValueObservation.tracking { db -> [String: ConvSummary] in
                let rows = try Row.fetchAll(db, sql: summarySQL)
                var out: [String: ConvSummary] = [:]
                for row in rows { out[row["cid"]] = summary(row) }
                return out
            }
            let cancellable = observation.start(
                in: AppDatabase.shared.dbQueue,
                onError: { _ in continuation.finish() },
                onChange: { continuation.yield($0) }
            )
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }

    static func wipe() {
        try? db.write { db in try db.execute(sql: "DELETE FROM conversation_read") }
    }

    // ---- резервная копия в iCloud (docs/icloud-backup.md §5) ----
    // Без этого восстановленная история целиком показывалась бы непрочитанной.

    static func allLastRead() -> [String: Int64] {
        (try? db.read { db -> [String: Int64] in
            var out: [String: Int64] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT conversationId, lastReadAt FROM conversation_read") {
                out[row["conversationId"]] = row["lastReadAt"]
            }
            return out
        }) ?? [:]
    }

    // только вверх, как markRead: восстановление не «разпрочитывает» уже прочитанное на устройстве
    static func importLastRead(_ values: [String: Int64]) {
        try? db.write { db in
            for (conversationId, at) in values {
                try db.execute(sql: """
                    INSERT INTO conversation_read (conversationId, lastReadAt) VALUES (?, ?)
                    ON CONFLICT(conversationId) DO UPDATE SET lastReadAt = MAX(lastReadAt, excluded.lastReadAt)
                    """, arguments: [conversationId, at])
            }
        }
    }
}
