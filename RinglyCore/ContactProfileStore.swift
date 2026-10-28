import Foundation
import GRDB

// расшифрованный профиль контакта в SQLCipher (имя + аватар-blob), чтобы показывать мгновенно из БД
struct ContactProfile: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "contact_profile"
    let userId: String
    let name: String?
    let avatar: Data?
    let updatedAt: Int64
}

enum ContactProfileStore {
    // `name` — то, что показываем: своё имя контакта, если задано, иначе имя из его профиля.
    // `realName` — имя из профиля как есть (экран профиля показывает его под своим).
    // Через `load` имя берут уведомления (NSE), CallKit и подписи «Переслано от» — поэтому своё имя
    // подмешивается здесь, в одной точке, а не у каждого вызывающего.
    static func load(_ userId: String) -> (name: String?, avatar: Data?, realName: String?)? {
        let (p, alias) = (try? AppDatabase.shared.dbQueue.read { db in
            (try ContactProfile.fetchOne(db, key: userId),
             try String.fetchOne(db, sql: "SELECT name FROM contact_alias WHERE userId = ?", arguments: [userId]))
        }) ?? (nil, nil)
        guard p != nil || alias != nil else { return nil }

        return (alias ?? p?.name, p?.avatar, p?.name)
    }

    // Своё имя контакта — только локально (не синкается ни на сервер, ни на другие свои устройства).
    static func alias(_ userId: String) -> String? {
        try? AppDatabase.shared.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT name FROM contact_alias WHERE userId = ?", arguments: [userId])
        }
    }

    // nil или пустая строка — вернуть имя из профиля
    static func setAlias(_ userId: String, _ name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try? AppDatabase.shared.dbQueue.write { db in
            if trimmed.isEmpty {
                try db.execute(sql: "DELETE FROM contact_alias WHERE userId = ?", arguments: [userId])
            } else {
                try db.execute(sql: "INSERT OR REPLACE INTO contact_alias (userId, name) VALUES (?, ?)",
                               arguments: [userId, trimmed])
            }
        }
    }

    // все свои имена контактов — для резервной копии в iCloud
    static func allAliases() -> [String: String] {
        (try? AppDatabase.shared.dbQueue.read { db -> [String: String] in
            var out: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT userId, name FROM contact_alias") {
                out[row["userId"]] = row["name"]
            }
            return out
        }) ?? [:]
    }

    static func save(userId: String, name: String?, avatar: Data?) {
        let p = ContactProfile(userId: userId, name: name, avatar: avatar,
                               updatedAt: Int64(Date().timeIntervalSince1970))
        try? AppDatabase.shared.dbQueue.write { try p.save($0) }   // upsert по PK userId
    }

    static func wipe() {
        try? AppDatabase.shared.dbQueue.write { db in
            _ = try ContactProfile.deleteAll(db)
            try db.execute(sql: "DELETE FROM contact_alias")   // свои имена — тоже данные аккаунта
        }
    }
}
