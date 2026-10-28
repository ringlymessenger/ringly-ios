import Foundation
import GRDB

// Снимок списка бесед для запуска без сети — как в Telegram: открыл приложение в метро, чаты на месте.
//
// Список приходит только с сервера (`GET /conversations`) и раньше нигде не сохранялся. Сообщения
// лежали локально, а сам перечень бесед — нет, поэтому офлайн экран чатов был пустым.
//
// В SQLCipher, а не в UserDefaults: «с кем я переписываюсь» — ровно те метаданные, ради защиты которых
// история и лежит в зашифрованной базе. Положить их рядом открытым текстом значило бы обнулить смысл
// шифрования самой переписки для того, кто получит доступ к файлам устройства.
enum ConversationCache {
    private static var db: DatabaseQueue { AppDatabase.shared.dbQueue }

    static func load() -> [ConversationItem] {
        let rows = (try? db.read { try Row.fetchAll($0, sql: "SELECT * FROM conversation_cache") }) ?? []

        return rows.map { r in
            let otherUserId: String? = r["otherUserId"]
            let otherUsername: String? = r["otherUsername"]

            return ConversationItem(
                conversationId: r["conversationId"],
                otherUser: otherUserId.map { OtherUser(userId: $0, username: otherUsername ?? "") },
                lastMessageAt: r["lastMessageAt"]
            )
        }
    }

    // Снимок заменяется ЦЕЛИКОМ: беседа, удалённая на сервере, не должна воскресать офлайн.
    static func save(_ items: [ConversationItem]) {
        try? db.write { db in
            try db.execute(sql: "DELETE FROM conversation_cache")
            for c in items {
                try db.execute(sql: """
                    INSERT INTO conversation_cache (conversationId, otherUserId, otherUsername, lastMessageAt)
                    VALUES (?, ?, ?, ?)
                """, arguments: [c.conversationId, c.otherUser?.userId, c.otherUser?.username, c.lastMessageAt])
            }
        }
    }

    static func wipe() {
        try? db.write { try $0.execute(sql: "DELETE FROM conversation_cache") }
    }
}
