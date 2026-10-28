import Foundation
import GRDB

// Локальный блок-лист (Signal-style): сервер о блокировках НЕ знает — приватность социального графа.
// Применение — на ПРИЁМНИКЕ: всё от заблокированного молча отбрасывается (MessageIngest — общий
// конвейер приложения и NSE; CallManager — входящие звонки). Заблокированный видит «доставлено» и
// о блоке не узнаёт (осознанно, как у Signal). Синк между своими устройствами — silent type:"block"
// только своим девайсам + поле в архиве history-sync.
enum BlockStore {
    private static var db: DatabaseQueue { AppDatabase.shared.dbQueue }

    static func isBlocked(_ userId: String) -> Bool {
        let found = try? db.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM blocked_user WHERE userId = ?)",
                              arguments: [userId])
        }
        return (found ?? false) ?? false
    }

    static func setBlocked(_ userId: String, username: String?, blocked: Bool) {
        try? db.write { db in
            if blocked {
                try db.execute(sql: "INSERT OR REPLACE INTO blocked_user (userId, username, blockedAt) VALUES (?, ?, ?)",
                               arguments: [userId, username, Int64(Date().timeIntervalSince1970 * 1000)])
            } else {
                try db.execute(sql: "DELETE FROM blocked_user WHERE userId = ?", arguments: [userId])
            }
        }
    }

    // весь список (для экрана «Заблокированные» и архива history-sync)
    static func all() -> [(userId: String, username: String?)] {
        (try? db.read { db in
            try Row.fetchAll(db, sql: "SELECT userId, username FROM blocked_user ORDER BY blockedAt DESC")
                .map { ($0["userId"] as String, $0["username"] as String?) }
        }) ?? []
    }
}
