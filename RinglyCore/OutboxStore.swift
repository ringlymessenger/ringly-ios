import Foundation
import GRDB

// Очередь исходящих сообщений.
//
// Зачем: до неё отправка была одноразовой попыткой — упала, и сообщение висело с крестиком, пока
// человек сам не нажмёт повтор. На плохой сети это и есть главная причина «сообщения не уходят»:
// не объём трафика, а отсутствие второго шанса.
//
// Что лежит: ссылка на уже вставленную строку `message` (тот же localId) плюс готовый открытый
// payload. Шифрование происходит В МОМЕНТ отправки — см. комментарий у миграции v14_outbox.
public struct OutboxItem: Codable, FetchableRecord, PersistableRecord, Equatable {
    public static let databaseTableName = "outbox"

    public let localId: String            // он же clientMessageId для сервера
    public let conversationId: String
    public let recipientUserId: String
    public let plaintext: Data
    public let createdAt: Int64           // unix ms, задаёт порядок внутри беседы
    public var attempts: Int
    public var nextAttemptAt: Int64       // unix ms; раньше этого момента не трогаем
}

public enum OutboxStore {
    private static var db: DatabaseQueue { AppDatabase.shared.dbQueue }

    public static func enqueue(localId: String, conversationId: String,
                               recipientUserId: String, plaintext: Data) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let item = OutboxItem(localId: localId, conversationId: conversationId,
                              recipientUserId: recipientUserId, plaintext: plaintext,
                              createdAt: now, attempts: 0, nextAttemptAt: now)
        // .ignore: повторная постановка того же localId не должна плодить строк и не должна
        // сбрасывать уже накопленный backoff
        try? db.write { try item.insert($0, onConflict: .ignore) }
    }

    // Головы очередей: по ОДНОЙ самой старой строке на беседу, у которой подошёл срок.
    //
    // Берём именно голову, а не «все готовые»: порядок внутри беседы обязан сохраняться, иначе
    // получатель увидит сообщения переставленными. А вот разные беседы независимы — застрявшая
    // переписка не должна задерживать остальные.
    public static func dueHeads(now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> [OutboxItem] {
        (try? db.read { db in
            try OutboxItem.fetchAll(db, sql: """
                SELECT o.* FROM outbox o
                WHERE o.createdAt = (
                    SELECT MIN(createdAt) FROM outbox WHERE conversationId = o.conversationId
                )
                AND o.nextAttemptAt <= ?
                ORDER BY o.createdAt
            """, arguments: [now])
        }) ?? []
    }

    public static func remove(localId: String) {
        _ = try? db.write { db in
            try OutboxItem.deleteOne(db, key: localId)
        }
    }

    public static func reschedule(localId: String, attempts: Int, nextAttemptAt: Int64) {
        _ = try? db.write { db in
            try db.execute(sql: "UPDATE outbox SET attempts = ?, nextAttemptAt = ? WHERE localId = ?",
                           arguments: [attempts, nextAttemptAt, localId])
        }
    }

    // Когда просыпаться в следующий раз, если прямо сейчас делать нечего (nil = очередь пуста).
    public static func earliestNextAttempt() -> Int64? {
        try? db.read { db in
            try Int64.fetchOne(db, sql: "SELECT MIN(nextAttemptAt) FROM outbox")
        } ?? nil
    }

    public static func wipe() {
        _ = try? db.write { db in try db.execute(sql: "DELETE FROM outbox") }
    }
}
