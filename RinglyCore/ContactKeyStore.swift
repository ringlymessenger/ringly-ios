import Foundation
import CryptoKit
import Security

enum ContactKeyStore {
    private static let service = "ringly.contactKeys"

    static func save(userId: String, profileKeyBase64: String) {
        guard let data = Data(base64Encoded: profileKeyBase64), data.count == 32 else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: userId,
            kSecAttrAccessGroup as String: AppGroup.keychainAccessGroup,   // общий с NSE
        ]
        SecItemDelete(base as CFDictionary)
        var attrs = base
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func key(for userId: String) -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: userId,
            kSecAttrAccessGroup as String: AppGroup.keychainAccessGroup,   // общий с NSE
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return SymmetricKey(data: data)
    }

    static func has(_ userId: String) -> Bool { key(for: userId) != nil }

    // стереть ВСЕ ключи контактов (при входе другим аккаунтом — ключи прошлого не должны утечь новому)
    static func wipeAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: AppGroup.keychainAccessGroup,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // все Profile Key контактов (userId → base64) — для архива синхронизации истории:
    // без них новое устройство не расшифрует имена/аватары контактов до их следующего сообщения
    static func allKeys() -> [String: String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: AppGroup.keychainAccessGroup,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [:] }
        var out: [String: String] = [:]
        for item in items {
            if let userId = item[kSecAttrAccount as String] as? String,
               let data = item[kSecValueData as String] as? Data, data.count == 32 {
                out[userId] = data.base64EncodedString()
            }
        }
        return out
    }
}
