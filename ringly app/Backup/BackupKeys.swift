import Foundation
import CryptoKit
import Security

// Ключ резервной копии переписки в iCloud (docs/icloud-backup.md §3). Две половины:
//   • halfA — в iCloud Keychain (синхронизируется между устройствами Apple ID со сквозным шифрованием
//     Apple; пользователь ничего не запоминает);
//   • halfB — внутри PIN-копии ключа профиля на нашем сервере (формат v2, ProfileKeyBackupService);
//     на устройстве лежит копия в обычном (не синхронизируемом) Keychain.
// Без PIN копию не открыть даже с доступом к Apple ID, без Apple ID — даже с нашей базой.
//
// ⚠️ halfA НЕ удаляется при выходе из аккаунта: копия ради того и существует, чтобы пережить выход.
// halfB на устройстве — удаляется (вернётся из PIN-копии при восстановлении).
enum BackupKeys {
    private static let service = "ringly.icloudBackup"

    // ---- halfA: iCloud Keychain ----

    static func halfA(userId: String) -> Data? {
        read(account: "halfA.\(userId)", synchronizable: true)
    }

    // Создавать halfA можно ТОЛЬКО когда копии этого аккаунта в iCloud ещё нет: на новом устройстве
    // Связка ключей может просто не успеть синхронизироваться, и новая половина затёрла бы ту, которой
    // зашифрована существующая копия.
    static func createHalfA(userId: String) -> Data {
        let value = random32()
        write(value, account: "halfA.\(userId)", synchronizable: true)
        return value
    }

    // «Сбросить копию»: новая половина вместо старой (старая копия при этом удаляется целиком)
    static func replaceHalfA(userId: String) -> Data {
        createHalfA(userId: userId)
    }

    // ---- halfB: локальная копия половины из PIN-копии ----

    static func halfB(userId: String) -> Data? {
        read(account: "halfB.\(userId)", synchronizable: false)
    }

    static func saveHalfB(_ value: Data, userId: String) {
        write(value, account: "halfB.\(userId)", synchronizable: false)
    }

    static func newHalfB() -> Data { random32() }

    // «Сбросить копию»: следующий save(pin:) создаст новую половину
    static func removeHalfB(userId: String) {
        SecItemDelete(base(account: "halfB.\(userId)", synchronizable: false) as CFDictionary)
    }

    // при выходе из аккаунта: только локальная halfB (всех аккаунтов этого устройства)
    static func clearLocal() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false
        ] as CFDictionary)
    }

    // ---- выведенные ключи ----

    struct Derived {
        let encryption: SymmetricKey   // AES-GCM для всего содержимого копии
        let naming: SymmetricKey       // HMAC для имён записей: Apple не видит наших id
    }

    static func derive(halfA: Data, halfB: Data, userId: String) -> Derived {
        let ikm = SymmetricKey(data: halfA + halfB)
        func sub(_ label: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm,
                                   info: Data("ringly-icloud-backup-v1|\(label)|\(userId)".utf8),
                                   outputByteCount: 32)
        }

        return Derived(encryption: sub("enc"), naming: sub("names"))
    }

    // ---- Keychain ----

    private static func random32() -> Data {
        var bytes = Data(count: 32)
        _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        return bytes
    }

    private static func base(account: String, synchronizable: Bool) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable
        ]
    }

    private static func read(account: String, synchronizable: Bool) -> Data? {
        var query = base(account: account, synchronizable: synchronizable)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count == 32 else { return nil }
        return data
    }

    private static func write(_ value: Data, account: String, synchronizable: Bool) {
        let query = base(account: account, synchronizable: synchronizable)
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = value
        // AfterFirstUnlock: копия делается и в фоновой задаче, когда экран может быть заблокирован.
        // ThisDeviceOnly — только у локальной половины: синхронизируемым элементам он запрещён.
        attrs[kSecAttrAccessible as String] = synchronizable
            ? kSecAttrAccessibleAfterFirstUnlock
            : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attrs as CFDictionary, nil)
    }
}
