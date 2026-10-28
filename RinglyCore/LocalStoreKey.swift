import Foundation
import CryptoKit
import Security

// 256-битный ключ SQLCipher. Device-local: не бэкапится, не синкается, не покидает устройство.
enum LocalStoreKey {
    private static let service = "ringly.localStore"
    private static let account = "localChatDBKey"

    static func keyData() -> Data {
        if let existing = read() { return existing }
        let raw = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        save(raw)
        return raw
    }

    private static func base() -> [String: Any] {
        [ kSecClass as String: kSecClassGenericPassword,
          kSecAttrService as String: service,
          kSecAttrAccount as String: account,
          kSecAttrAccessGroup as String: AppGroup.keychainAccessGroup ]   // общий с NSE
    }
    private static func save(_ data: Data) {
        SecItemDelete(base() as CFDictionary)
        var attrs = base()
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attrs as CFDictionary, nil)
    }
    private static func read() -> Data? {
        var q = base()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return data
    }
}
