import Foundation
import GRDB

// Локальный mute-лист. Отличие от блока: от замьюченного сообщение ПРИХОДИТ и сохраняется в чат,
// но НЕ показывается пуш-баннер (NSE) — то есть просто без уведомлений. Локально на устройстве.
enum MuteStore {
    private static var db: DatabaseQueue { AppDatabase.shared.dbQueue }

    static func isMuted(_ userId: String) -> Bool {
        let found = try? db.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM muted_user WHERE userId = ?)",
                              arguments: [userId])
        }
        return (found ?? false) ?? false
    }

    static func setMuted(_ userId: String, muted: Bool) {
        try? db.write { db in
            if muted {
                try db.execute(sql: "INSERT OR REPLACE INTO muted_user (userId, mutedAt) VALUES (?, ?)",
                               arguments: [userId, Int64(Date().timeIntervalSince1970 * 1000)])
            } else {
                try db.execute(sql: "DELETE FROM muted_user WHERE userId = ?", arguments: [userId])
            }
        }
    }

    static func all() -> [String] {
        (try? db.read { db in
            try String.fetchAll(db, sql: "SELECT userId FROM muted_user ORDER BY mutedAt DESC")
        }) ?? []
    }
}
