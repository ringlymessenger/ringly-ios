import Foundation
import GRDB

final class AppDatabase {
    static let shared = AppDatabase()
    let dbQueue: DatabaseQueue

    private init() {
        do {
            // База в shared-контейнере App Group: и приложение, и NSE открывают ОДИН файл.
            let url = AppGroup.containerURL.appendingPathComponent("ringly.sqlite")

            var config = Configuration()
            config.busyMode = .timeout(5)   // два процесса (приложение+NSE) пишут в один файл — ждём лок, не падаем
            config.prepareDatabase { db in
                try db.usePassphrase(LocalStoreKey.keyData())   // SQLCipher: весь файл зашифрован ключом из Keychain
            }

            dbQueue = try DatabaseQueue(path: url.path, configuration: config)
            try Self.migrator.migrate(dbQueue)
        } catch {
            fatalError("AppDatabase init failed: \(error)")
        }
    }

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1_messages") { db in
            try db.create(table: "message") { t in
                t.column("id", .text).primaryKey()                  // messageId (дедуп через onConflict .ignore)
                t.column("conversationId", .text).notNull()
                t.column("senderUserId", .text).notNull()
                t.column("isMine", .boolean).notNull()
                t.column("text", .text).notNull()
                t.column("sentAt", .integer).notNull()
            }
            try db.create(index: "idx_message_convo_time", on: "message", columns: ["conversationId", "sentAt"])
        }
        m.registerMigration("v2_status") { db in
            try db.alter(table: "message") { t in
                t.add(column: "status", .text).notNull().defaults(to: "sent")   // статус сообщения
                t.add(column: "serverMessageId", .text)                          // серверный messageId (для статусов)
            }
            try db.create(index: "idx_message_server_id", on: "message", columns: ["serverMessageId"])
        }
        m.registerMigration("v3_contact_profile") { db in
            try db.create(table: "contact_profile") { t in
                t.column("userId", .text).primaryKey()
                t.column("name", .text)
                t.column("avatar", .blob)
                t.column("updatedAt", .integer).notNull()
            }
        }
        m.registerMigration("v4_signal_store") { db in
            // состояние протокола libsignal — в зашифрованной БД (раньше было в Keychain)
            try db.execute(sql: "CREATE TABLE signal_identity (id INTEGER PRIMARY KEY, data BLOB NOT NULL)")
            try db.execute(sql: "CREATE TABLE signal_prekey (keyId INTEGER PRIMARY KEY, data BLOB NOT NULL)")
            try db.execute(sql: "CREATE TABLE signal_signed_prekey (keyId INTEGER PRIMARY KEY, data BLOB NOT NULL)")
            try db.execute(sql: "CREATE TABLE signal_kyber_prekey (keyId INTEGER PRIMARY KEY, data BLOB NOT NULL, isLastResort INTEGER NOT NULL DEFAULT 0)")
            try db.execute(sql: "CREATE TABLE signal_session (addr TEXT PRIMARY KEY, data BLOB NOT NULL)")
            try db.execute(sql: "CREATE TABLE signal_peer_identity (addr TEXT PRIMARY KEY, data BLOB NOT NULL)")
        }
        m.registerMigration("v5_processed_delivery") { db in
            // дедуп входящих доставок (Signal-style): расшифровываем строго ОДИН раз —
            // и приложение, и NSE сверяются с этим маркером, чтобы не двигать ратчет дважды.
            try db.execute(sql: "CREATE TABLE processed_delivery (deliveryId TEXT PRIMARY KEY, processedAt INTEGER NOT NULL)")
        }
        m.registerMigration("v6_message_kind") { db in
            // вид записи: "text" — обычное сообщение, "call" — итог звонка (text хранит JSON CallLog)
            try db.alter(table: "message") { t in
                t.add(column: "kind", .text).notNull().defaults(to: "text")
            }
        }
        m.registerMigration("v7_reply") { db in
            // реплай (цитата): ссылка на серверный id + снапшот автора/текста (рендерится без оригинала)
            try db.alter(table: "message") { t in
                t.add(column: "replyToId", .text)
                t.add(column: "replyAuthorUserId", .text)
                t.add(column: "replyText", .text)
            }
        }
        m.registerMigration("v8_edited") { db in
            // редактирование: время последней правки (nil = не редактировалось) → подпись «изменено»
            try db.alter(table: "message") { t in
                t.add(column: "editedAt", .integer)
            }
        }
        m.registerMigration("v9_forward") { db in
            // пересылка: автор оригинала (nil = не пересланное) → подпись «Переслано от …»
            try db.alter(table: "message") { t in
                t.add(column: "forwardFromUserId", .text)
            }
        }
        m.registerMigration("v10_blocked") { db in
            // локальный блок-лист (Signal-style: сервер о нём не знает); username — снапшот для списка
            try db.execute(sql: "CREATE TABLE blocked_user (userId TEXT PRIMARY KEY, username TEXT, blockedAt INTEGER NOT NULL)")
        }
        m.registerMigration("v11_muted") { db in
            // локальный mute-лист: от заблокированного отбрасываем, а от замьюченного лишь не показываем пуш
            try db.execute(sql: "CREATE TABLE muted_user (userId TEXT PRIMARY KEY, mutedAt INTEGER NOT NULL)")
        }
        m.registerMigration("v12_read") { db in
            // локальное read-состояние беседы (Telegram-style непрочитанные): до какого sentAt я прочитал.
            // Непрочитанные = входящие с sentAt > lastReadAt. Хранится локально (не E2EE, не синкается).
            try db.execute(sql: "CREATE TABLE conversation_read (conversationId TEXT PRIMARY KEY, lastReadAt INTEGER NOT NULL)")
        }
        m.registerMigration("v13_media_caption") { db in
            // подпись к фото/видео. Отдельная колонка, а не `text`: у медиа там лежит JSON MediaRef
            // с миниатюрой, и класть подпись туда же значило бы парсить смысл строки по kind в каждом месте.
            try db.alter(table: "message") { t in
                t.add(column: "caption", .text)
            }
        }
        m.registerMigration("v14_outbox") { db in
            // Очередь исходящих. Сообщение ложится сюда СРАЗУ и уходит фоновой задачей с повторами,
            // а не умирает с крестиком при первом же обрыве связи (network-optimization.md, этап 1б).
            //
            // ⚠️ Здесь лежит ОТКРЫТЫЙ payload, а не шифртекст — и это сознательно. Double Ratchet
            // двигает цепочку на каждом шифровании: зашифровать заранее и отправить потом значило бы
            // ломать её при повторах и переупорядочивании. Шифруем в момент попытки. На секретность
            // это не влияет — тот же открытый текст и так лежит в соседней таблице `message`,
            // а вся база под SQLCipher.
            //
            // localId служит и ключом идемпотентности для сервера (clientMessageId), поэтому он
            // ОБЯЗАН пережить все повторы: новый id на повторе = дубликат в переписке.
            try db.execute(sql: """
                CREATE TABLE outbox (
                    localId TEXT PRIMARY KEY,
                    conversationId TEXT NOT NULL,
                    recipientUserId TEXT NOT NULL,
                    plaintext BLOB NOT NULL,
                    createdAt INTEGER NOT NULL,
                    attempts INTEGER NOT NULL DEFAULT 0,
                    nextAttemptAt INTEGER NOT NULL
                )
            """)
            // порядок внутри беседы — по createdAt; выборка головы очереди идёт по этому индексу
            try db.execute(sql: "CREATE INDEX outbox_conversation ON outbox(conversationId, createdAt)")
        }
        m.registerMigration("v15_conversation_cache") { db in
            // Снимок списка бесед для запуска без сети (см. ConversationCache). Сам список приходит
            // только с сервера и раньше нигде не сохранялся — офлайн экран чатов был пустым, хотя
            // вся переписка лежала локально.
            try db.execute(sql: """
                CREATE TABLE conversation_cache (
                    conversationId TEXT PRIMARY KEY,
                    otherUserId TEXT,
                    otherUsername TEXT,
                    lastMessageAt TEXT
                )
            """)
        }
        m.registerMigration("v16_reactions") { db in
            // эмодзи-реакции: JSON [MessageReaction] прямо в строке сообщения (см. LocalMessage.reactions)
            try db.alter(table: "message") { t in
                t.add(column: "reactions", .text)
            }
        }
        m.registerMigration("v17_contact_alias") { db in
            // своё имя контакта («мама» вместо «Ирина») — только на этом устройстве, см. ContactProfileStore.
            // Отдельная таблица, а не колонка contact_profile: профиль перезаписывается при каждом
            // обновлении с сервера, и имя, заданное пользователем, затиралось бы.
            try db.create(table: "contact_alias", ifNotExists: true) { t in
                t.column("userId", .text).primaryKey()
                t.column("name", .text).notNull()
            }
        }
        return m
    }
}
