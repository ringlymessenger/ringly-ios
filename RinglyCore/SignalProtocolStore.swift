import Foundation
import Security
import GRDB
import LibSignalClient

// Keychain-хелпер оставлен ТОЛЬКО для одноразовой миграции старой identity-пары в БД (см. loadOrCreateIdentity).
// Как хранилище протокола Keychain больше не используется.
enum SignalKeychain {
    private static let service = "ringly.signal"
    static func get(account: String) -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let d = result as? Data else { return nil }
        return d
    }
    static func delete(account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}

// Стор протокола libsignal поверх SQLCipher (GRDB). БД сериализует записи (потокобезопасно), а поверх —
// SignalSession actor сериализует целые операции. Keychain хранит лишь ключ БД (SQLCipher) и device-токен.
final class SignalProtocolStore: IdentityKeyStore, PreKeyStore, SignedPreKeyStore, KyberPreKeyStore, SessionStore {

    static let shared = SignalProtocolStore()

    private var dbq: DatabaseQueue { AppDatabase.shared.dbQueue }
    private func addr(_ a: ProtocolAddress) -> String { "\(a.name)-\(a.deviceId)" }

    // Стереть ВСЁ состояние протокола (identity, сессии, prekeys, peer-identities) — SQL-уровень,
    // файл БД не трогаем (он открыт). Зовётся при явном «Выйти» и при входе ДРУГИМ аккаунтом:
    // identity аккаунта не должна пережить смену владельца устройства.
    func wipeAll() {
        try? dbq.write { db in
            for t in ["signal_identity", "signal_peer_identity", "signal_prekey",
                      "signal_signed_prekey", "signal_kyber_prekey", "signal_session"] {
                try db.execute(sql: "DELETE FROM \(t)")
            }
        }
    }

    // одноразовая миграция со старого Keychain-стора: identity переносится лениво в loadOrCreateIdentity,
    // а prekeys форсим перерегистрировать уже в БД (старые сессии/peer-identity переустановятся сами)
    func migrateIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "signalStoreV2") else { return }
        _ = try? loadOrCreateIdentity()                                  // перенесёт старую identity из Keychain (если есть)
        UserDefaults.standard.removeObject(forKey: "signalKeysGeneration") // перерегистрируем prekeys в БД
        UserDefaults.standard.set(true, forKey: "signalStoreV2")
    }

    // ---- identity ----
    func loadOrCreateIdentity() throws -> IdentityKeyPair {
        if let raw = try dbq.read({ try Data.fetchOne($0, sql: "SELECT data FROM signal_identity WHERE id = 0") }) {
            return try IdentityKeyPair(bytes: Array(raw))
        }
        let pair: IdentityKeyPair
        if let old = SignalKeychain.get(account: "identityKeyPair") {   // миграция старой identity-пары
            pair = try IdentityKeyPair(bytes: Array(old))
            SignalKeychain.delete(account: "identityKeyPair")
        } else {
            pair = IdentityKeyPair.generate()
        }
        try dbq.write { try $0.execute(
            sql: "INSERT OR REPLACE INTO signal_identity(id, data) VALUES (0, ?)",
            arguments: [Data(pair.serialize())]) }
        return pair
    }

    func identityKeyPair(context: StoreContext) throws -> IdentityKeyPair { try loadOrCreateIdentity() }
    func localRegistrationId(context: StoreContext) throws -> UInt32 { UInt32(DeviceIdentity.registrationId) }

    func saveIdentity(_ identity: IdentityKey, for address: ProtocolAddress, context: StoreContext) throws -> IdentityChange {
        let a = addr(address)
        let new = Data(identity.serialize())
        let prev = try dbq.read { try Data.fetchOne($0, sql: "SELECT data FROM signal_peer_identity WHERE addr = ?", arguments: [a]) }
        try dbq.write { try $0.execute(
            sql: "INSERT OR REPLACE INTO signal_peer_identity(addr, data) VALUES (?, ?)", arguments: [a, new]) }
        if let prev, prev != new {
            // ≈ «изменился код безопасности» → предупредим в UI (+ запись для журнала, см. SecurityEvents)
            SecurityEvents.recordIdentityChange(userId: address.name, deviceId: address.deviceId, old: prev, new: new)
            return .replacedExisting
        }
        return .newOrUnchanged
    }

    func isTrustedIdentity(_ identity: IdentityKey, for address: ProtocolAddress, direction: Direction, context: StoreContext) throws -> Bool {
        // принимаем смену identity (не блокируем доставку, как WhatsApp по умолчанию). Пользователя предупреждаем
        // баннером — событие записано в saveIdentity. Полная верификация safety number — отдельная фича.
        return true
    }

    func identity(for address: ProtocolAddress, context: StoreContext) throws -> IdentityKey? {
        guard let raw = try dbq.read({ try Data.fetchOne($0, sql: "SELECT data FROM signal_peer_identity WHERE addr = ?", arguments: [addr(address)]) })
        else { return nil }
        return try IdentityKey(bytes: Array(raw))
    }

    // ---- one-time prekeys ----
    func loadPreKey(id: UInt32, context: StoreContext) throws -> PreKeyRecord {
        guard let raw = try dbq.read({ try Data.fetchOne($0, sql: "SELECT data FROM signal_prekey WHERE keyId = ?", arguments: [Int(id)]) })
        else { throw SignalError.invalidKeyIdentifier("no one-time prekey \(id)") }
        return try PreKeyRecord(bytes: Array(raw))
    }
    func storePreKey(_ record: PreKeyRecord, id: UInt32, context: StoreContext) throws {
        try dbq.write { try $0.execute(sql: "INSERT OR REPLACE INTO signal_prekey(keyId, data) VALUES (?, ?)",
                                       arguments: [Int(id), Data(try record.serialize())]) }
    }
    func removePreKey(id: UInt32, context: StoreContext) throws {
        try dbq.write { try $0.execute(sql: "DELETE FROM signal_prekey WHERE keyId = ?", arguments: [Int(id)]) }
    }

    // ---- signed prekeys ----
    func loadSignedPreKey(id: UInt32, context: StoreContext) throws -> SignedPreKeyRecord {
        guard let raw = try dbq.read({ try Data.fetchOne($0, sql: "SELECT data FROM signal_signed_prekey WHERE keyId = ?", arguments: [Int(id)]) })
        else { throw SignalError.invalidKeyIdentifier("no signed prekey \(id)") }
        return try SignedPreKeyRecord(bytes: Array(raw))
    }
    func storeSignedPreKey(_ record: SignedPreKeyRecord, id: UInt32, context: StoreContext) throws {
        try dbq.write { try $0.execute(sql: "INSERT OR REPLACE INTO signal_signed_prekey(keyId, data) VALUES (?, ?)",
                                       arguments: [Int(id), Data(try record.serialize())]) }
    }

    // ---- kyber prekeys ----
    func loadKyberPreKey(id: UInt32, context: StoreContext) throws -> KyberPreKeyRecord {
        guard let raw = try dbq.read({ try Data.fetchOne($0, sql: "SELECT data FROM signal_kyber_prekey WHERE keyId = ?", arguments: [Int(id)]) })
        else { throw SignalError.invalidKeyIdentifier("no kyber prekey \(id)") }
        return try KyberPreKeyRecord(bytes: Array(raw))
    }
    func storeKyberPreKey(_ record: KyberPreKeyRecord, id: UInt32, context: StoreContext) throws {
        try dbq.write { try $0.execute(sql: "INSERT OR REPLACE INTO signal_kyber_prekey(keyId, data, isLastResort) VALUES (?, ?, 0)",
                                       arguments: [Int(id), Data(try record.serialize())]) }
    }
    // пометить kyber-ключ last-resort (его markKyberPreKeyUsed не удаляет)
    func markKyberLastResort(_ id: UInt32) throws {
        try dbq.write { try $0.execute(sql: "UPDATE signal_kyber_prekey SET isLastResort = 1 WHERE keyId = ?", arguments: [Int(id)]) }
    }
    func markKyberPreKeyUsed(id: UInt32, signedPreKeyId: UInt32, baseKey: PublicKey, context: StoreContext) throws {
        let lastResort = (try? dbq.read { try Bool.fetchOne($0, sql: "SELECT isLastResort FROM signal_kyber_prekey WHERE keyId = ?", arguments: [Int(id)]) }) ?? nil
        if lastResort != true {   // one-time kyber удаляем после использования; last-resort оставляем
            try dbq.write { try $0.execute(sql: "DELETE FROM signal_kyber_prekey WHERE keyId = ?", arguments: [Int(id)]) }
        }
    }

    // ---- sessions ----
    func loadSession(for address: ProtocolAddress, context: StoreContext) throws -> SessionRecord? {
        guard let raw = try dbq.read({ try Data.fetchOne($0, sql: "SELECT data FROM signal_session WHERE addr = ?", arguments: [addr(address)]) })
        else { return nil }
        return try SessionRecord(bytes: Array(raw))
    }
    func loadExistingSessions(for addresses: [ProtocolAddress], context: StoreContext) throws -> [SessionRecord] {
        try addresses.map { a in
            guard let s = try loadSession(for: a, context: context) else { throw SignalError.sessionNotFound("\(a)") }
            return s
        }
    }
    // Выбросить сессию с конкретным устройством. Следующая отправка построит новую из PreKeyBundle
    // (envelope type=3). Нужно для самовосстановления: если сессия рассинхронизировалась, чинить её
    // нечем — только заменить. Аналог archiveCurrentState() у Signal.
    func deleteSession(for address: ProtocolAddress) {
        try? dbq.write { try $0.execute(sql: "DELETE FROM signal_session WHERE addr = ?",
                                        arguments: [addr(address)]) }
    }

    func storeSession(_ record: SessionRecord, for address: ProtocolAddress, context: StoreContext) throws {
        try dbq.write { try $0.execute(sql: "INSERT OR REPLACE INTO signal_session(addr, data) VALUES (?, ?)",
                                       arguments: [addr(address), Data(try record.serialize())]) }
    }
}
