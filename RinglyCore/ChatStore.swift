import Foundation
import GRDB

enum MessageStatus: String, Codable {
    case sending, sent, delivered, read, failed
    var rank: Int {
        switch self {
        case .failed:    return -1
        case .sending:   return 0
        case .sent:      return 1
        case .delivered: return 2
        case .read:      return 3
        }
    }
}

struct LocalMessage: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "message"
    let id: String                 // локальный id (UUID для исходящих) или серверный messageId (для входящих)
    let conversationId: String
    let senderUserId: String
    let isMine: Bool
    var text: String               // для kind=="call" — JSON CallLog; var — редактирование правит на месте
    var sentAt: Int64          // время СЕРВЕРА (у своих — после отправки, см. markSent)
    var status: MessageStatus
    var serverMessageId: String?   // серверный messageId (для сопоставления статусов delivered/read)
    var kind: String = "text"      // "text" | "call" (дефолт — старые вызовы/строки не меняются)
    // реплай (цитата) — снапшот, как quote у Signal; nil = обычное сообщение
    var replyToId: String? = nil            // серверный id цитируемого
    var replyAuthorUserId: String? = nil
    var replyText: String? = nil
    var editedAt: Int64? = nil              // время последней правки → подпись «изменено»
    var forwardFromUserId: String? = nil    // автор оригинала пересланного → подпись «Переслано от …»
    // подпись к медиа (kind=="media"): отдельная колонка, потому что `text` у медиа занят JSON'ом MediaRef
    var caption: String? = nil
    // реакции — JSON [MessageReaction]; отдельной таблицы нет, чтобы они ехали в архивах
    // history-sync вместе со строкой сообщения (как правки и подписи)
    var reactions: String? = nil
}

// Реакция одного человека. emoji == nil — снята, но запись остаётся: по `at` отбрасываются
// опоздавшие (переупорядоченные) обновления, иначе старая реакция могла бы вернуться после снятия.
struct MessageReaction: Codable, Equatable {
    var userId: String
    var emoji: String?
    var at: Int64
}

extension LocalMessage {
    // С кешем по самой JSON-строке: лента спрашивает реакции у каждого видимого сообщения на каждой
    // перерисовке, а разбор JSON там — лишняя работа (строка меняется, только когда меняются реакции).
    var reactionList: [MessageReaction] {
        guard let raw = reactions, !raw.isEmpty else { return [] }
        if let hit = ReactionListCache.shared.object(forKey: raw as NSString) { return hit.list }
        let list = (raw.data(using: .utf8)).flatMap { try? JSONDecoder().decode([MessageReaction].self, from: $0) } ?? []
        ReactionListCache.shared.setObject(ReactionListBox(list), forKey: raw as NSString)

        return list
    }
}

private final class ReactionListBox {
    let list: [MessageReaction]
    init(_ list: [MessageReaction]) { self.list = list }
}

private enum ReactionListCache {
    static let shared: NSCache<NSString, ReactionListBox> = {
        let c = NSCache<NSString, ReactionListBox>()
        c.countLimit = 500
        return c
    }()
}

extension LocalMessage {
    // окно редактирования (как в Telegram): 48 часов от отправки, дальше — нельзя
    static let editWindowMs: Int64 = 48 * 3600 * 1000

    // можно ли редактировать СЕЙЧАС (для UI и гарда отправки)
    var editableNow: Bool {
        isMine && kind == "text" && serverMessageId != nil
            && Int64(Date().timeIntervalSince1970 * 1000) - sentAt <= Self.editWindowMs
    }
}

enum ChatStore {
    private static var db: DatabaseQueue { AppDatabase.shared.dbQueue }

    // вставить с дедупом по id (PK). .ignore — из-за идемпотентного приёма
    static func add(_ msg: LocalMessage) {
        try? db.write { try msg.insert($0, onConflict: .ignore) }
    }

    // ==== дедуп входящих доставок (Signal-style): расшифровка строго один раз ====

    static func isProcessed(deliveryId: String) -> Bool {
        let found = try? db.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM processed_delivery WHERE deliveryId = ?)",
                              arguments: [deliveryId])
        }
        return (found ?? false) ?? false
    }

    static func markProcessed(deliveryId: String) {
        try? db.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO processed_delivery (deliveryId, processedAt) VALUES (?, ?)",
                           arguments: [deliveryId, Int64(Date().timeIntervalSince1970 * 1000)])
        }
    }

    // атомарно: вставить сообщение И пометить доставку обработанной (одна транзакция)
    static func persistIncoming(_ msg: LocalMessage, deliveryId: String) {
        try? db.write { db in
            try msg.insert(db, onConflict: .ignore)
            try db.execute(sql: "INSERT OR IGNORE INTO processed_delivery (deliveryId, processedAt) VALUES (?, ?)",
                           arguments: [deliveryId, Int64(Date().timeIntervalSince1970 * 1000)])
        }
    }

    // исходящее: POST вернул messageId → проставить серверный id и статус sent
    // serverSentAt — время сервера из ответа на отправку: до отправки строка стоит со временем
    // телефона, после — переезжает на серверное (как у получателя), чтобы сбитые часы не ломали ленту
    static func markSent(localId: String, serverMessageId: String, serverSentAt: Int64? = nil) {
        try? db.write { db in
            guard var m = try LocalMessage.fetchOne(db, key: localId) else { return }
            if m.status.rank < MessageStatus.sent.rank { m.status = .sent }
            m.serverMessageId = serverMessageId
            if let serverSentAt { m.sentAt = serverSentAt }
            try m.update(db)
        }
    }

    // исходящее: отправка не удалась
    static func markFailed(localId: String) {
        try? db.write { db in
            guard var m = try LocalMessage.fetchOne(db, key: localId) else { return }
            m.status = .failed
            try m.update(db)
        }
    }

    static func delete(localId: String) {
        try? db.write { db in _ = try LocalMessage.deleteOne(db, key: localId) }
    }

    // удалить всю локальную историю беседы («Удалить контакт»)
    static func deleteConversation(_ conversationId: String) {
        try? db.write { db in
            _ = try LocalMessage.filter(Column("conversationId") == conversationId).deleteAll(db)
        }
    }

    // Заменить payload медиа-сообщения. Нужно для телеграм-стиля отправки: бабл с превью появляется
    // СРАЗУ после выбора файла (с пустым attachmentId), а реальные id/ключ дописываются сюда после
    // заливки. Без этого пользователь несколько секунд смотрел бы на пустой чат.
    static func updateMediaPayload(localId: String, json: String) {
        try? db.write { db in
            guard var m = try LocalMessage.filter(Column("id") == localId).fetchOne(db) else { return }
            m.text = json
            try m.update(db)
        }
    }

    // найти своё отправленное сообщение по серверному id — нужно для переотправки по retry receipt
    static func findByServerMessageId(_ serverMessageId: String) -> LocalMessage? {
        try? db.read { db in
            try LocalMessage.filter(Column("serverMessageId") == serverMessageId).fetchOne(db)
        }
    }

    // статус от сервера (delivered) / квитанции (read) — только ВВЕРХ (не понижаем)
    static func applyStatus(serverMessageId: String, _ status: MessageStatus) {
        try? db.write { db in
            guard var m = try LocalMessage
                .filter(Column("serverMessageId") == serverMessageId).fetchOne(db) else { return }
            if status.rank > m.status.rank { m.status = status; try m.update(db) }
        }
    }

    // редактирование (type:"edit"): применить новый текст к оригиналу. ГРАНИЦЫ: правка применяется
    // ТОЛЬКО если автор совпадает (собеседник не может править чужие сообщения), это текст, и правка
    // уложилась в 48ч-окно. Времена (editedAt/sentAt) — с ОДНИХ часов автора → сравнение честное.
    @discardableResult
    static func applyEdit(targetId: String, newText: String, editedAt: Int64, authorUserId: String) -> Bool {
        (try? db.write { db -> Bool in
            guard var m = try LocalMessage
                .filter(Column("serverMessageId") == targetId || Column("id") == targetId)
                .fetchOne(db) else { return false }             // оригинала нет локально — правка теряется (MVP)
            guard m.senderUserId == authorUserId, m.kind == "text" else { return false }
            guard editedAt - m.sentAt <= LocalMessage.editWindowMs else { return false }   // окно 48ч
            m.text = newText
            m.editedAt = editedAt
            try m.update(db)
            return true
        }) ?? false
    }

    // полное удаление у всех (type:"delete"): строка удаляется ФИЗИЧЕСКИ, без tombstone —
    // «как будто не было». ГРАНИЦА: применяется только если отправитель == автор оригинала.
    @discardableResult
    static func applyDelete(targetId: String, authorUserId: String) -> Bool {
        (try? db.write { db -> Bool in
            guard let m = try LocalMessage
                .filter(Column("serverMessageId") == targetId || Column("id") == targetId)
                .fetchOne(db) else { return false }
            guard m.senderUserId == authorUserId else { return false }
            try m.delete(db)
            return true
        }) ?? false
    }

    // реакция (type:"reaction"): одна на человека — новая заменяет прежнюю, nil снимает.
    // ГРАНИЦЫ: сообщение должно лежать в ТОЙ ЖЕ беседе, откуда пришла реакция (иначе собеседник
    // мог бы «реагировать» на чужие переписки по угаданному id), на записи о звонках не реагируют,
    // а обновление старше уже применённого от того же человека отбрасывается.
    @discardableResult
    static func applyReaction(targetId: String, conversationId: String, userId: String,
                              emoji: String?, at: Int64) -> Bool {
        (try? db.write { db -> Bool in
            guard var m = try LocalMessage
                .filter(Column("serverMessageId") == targetId || Column("id") == targetId)
                .fetchOne(db) else { return false }             // оригинала нет локально — реакция теряется
            guard m.conversationId == conversationId, m.kind != "call" else { return false }

            var list = m.reactionList
            if let prev = list.first(where: { $0.userId == userId }), prev.at > at { return false }
            list.removeAll { $0.userId == userId }
            list.append(MessageReaction(userId: userId, emoji: emoji, at: at))
            m.reactions = (try? JSONEncoder().encode(list)).flatMap { String(data: $0, encoding: .utf8) }
            try m.update(db)

            return true
        }) ?? false
    }

    // read-квитанция «прочитано до X»: пометить read все МОИ исходящие в беседе с sentAt <= sentAt(X)
    static func markReadUpTo(conversationId: String, upToServerMessageId: String) {
        try? db.write { db in
            guard let anchor = try LocalMessage
                .filter(Column("serverMessageId") == upToServerMessageId).fetchOne(db) else { return }
            let mine = try LocalMessage.filter(
                Column("conversationId") == conversationId
                && Column("isMine") == true
                && Column("sentAt") <= anchor.sentAt
            ).fetchAll(db)
            for var m in mine where m.status.rank < MessageStatus.read.rank {
                m.status = .read
                try m.update(db)
            }
        }
    }

    // одноразовая выборка истории беседы (для перечитки после записи из другого процесса/NSE)
    static func messages(conversationId: String) -> [LocalMessage] {
        (try? db.read { db in
            try LocalMessage.filter(Column("conversationId") == conversationId)
                .order(Column("sentAt")).fetchAll(db)
        }) ?? []
    }

    // живой поток сообщений беседы (AsyncStream — без import GRDB во View)
    static func observe(conversationId: String) -> AsyncStream<[LocalMessage]> {
        AsyncStream { continuation in
            let observation = ValueObservation.tracking { db in
                try LocalMessage
                    .filter(Column("conversationId") == conversationId)
                    .order(Column("sentAt"))
                    .fetchAll(db)
            }
            let cancellable = observation.start(
                in: AppDatabase.shared.dbQueue,
                onError: { _ in continuation.finish() },
                onChange: { rows in continuation.yield(rows) }
            )
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }

    // ==== синхронизация истории между своими устройствами (docs/history-sync.md) ====

    // вся история для архива донора
    static func exportAll() -> [LocalMessage] {
        (try? db.read { db in
            try LocalMessage.order(Column("sentAt"), Column("id")).fetchAll(db)   // id — для стабильного порядка (сравнение сегментов копии)
        }) ?? []
    }

    // сообщения, сгруппированные для резервной копии: беседа → [сообщения по времени]
    static func exportByConversation() -> [String: [LocalMessage]] {
        Dictionary(grouping: exportAll(), by: \.conversationId)
    }

    static func messageCount() -> Int {
        (try? db.read { db in try LocalMessage.fetchCount(db) }) ?? 0
    }

    // импорт архива с дедупом. ВАЖНО: дедуп по serverMessageId, а не только по PK id —
    // исходящие строки донора имеют локальный UUID как id, а та же переписка, принятая этим
    // устройством вживую (fan-out с момента линковки), лежит с id == messageId. Совпадение — только
    // через serverMessageId. Возвращает число вставленных строк.
    static func importArchive(_ messages: [LocalMessage]) -> Int {
        var inserted = 0
        try? db.write { db in
            for m in messages {
                if let sid = m.serverMessageId {
                    let dup = (try Bool.fetchOne(db, sql:
                        "SELECT EXISTS(SELECT 1 FROM message WHERE serverMessageId = ? OR id = ?)",
                        arguments: [sid, sid])) ?? false
                    if dup { continue }
                }
                let idDup = (try Bool.fetchOne(db, sql:
                    "SELECT EXISTS(SELECT 1 FROM message WHERE id = ?)", arguments: [m.id])) ?? false
                if idDup { continue }
                try m.insert(db, onConflict: .ignore)
                inserted += 1
            }
        }
        return inserted
    }

    static func wipe() {
        try? db.write { db in
            _ = try LocalMessage.deleteAll(db)
            try db.execute(sql: "DELETE FROM processed_delivery")
            // Очередь исходящих — тоже данные аккаунта: в ней лежит открытый payload. Оставить её
            // при выходе значило бы и утечку, и попытку дослать чужие сообщения после входа другим.
            try db.execute(sql: "DELETE FROM outbox")
        }
    }
}
