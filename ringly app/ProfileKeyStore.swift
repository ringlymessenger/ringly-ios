import Foundation
import CryptoKit
import Security

final class ProfileKeyStore {
    static let shared = ProfileKeyStore()
    private let account = "profileKey"

    // вернуть существующий ключ или создать новый (на онбординге)
    func keyOrCreate() -> SymmetricKey {
        if let existing = read() { return existing }
        let key = SymmetricKey(size: .bits256)             // 32 случайных байта
        let raw = key.withUnsafeBytes { Data($0) }
        save(raw)
        return key
    }

    // только прочитать (для расшифровки; может вернуть nil на новом устройстве)
    func existingKey() -> SymmetricKey? { read() }

    func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    // --- Keychain-бойлерплейт ---
    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: true,        // ← iCloud Keychain синк
        ]
    }

    private func save(_ data: Data) {
        SecItemDelete(baseQuery() as CFDictionary)
        var attrs = baseQuery()
        attrs[kSecValueData as String] = data
        SecItemAdd(attrs as CFDictionary, nil)
    }

    private func read() -> SymmetricKey? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return SymmetricKey(data: data)
    }
    
    // записать готовый 32-байтовый ключ (получен по sync или восстановлен из PIN-бэкапа)
    func saveRaw(_ raw: Data) {
        save(raw)            // приватный save уже есть в классе
    }

    // сырые байты текущего ключа (для AES-GCM бэкапа). nil, если ключа нет
    func rawKey() -> Data? {
        existingKey()?.withUnsafeBytes { Data($0) }
    }
}
