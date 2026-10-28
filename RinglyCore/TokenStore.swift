import Foundation
import Security

final class TokenStore {
    static let shared = TokenStore()
    private let account = "deviceAuthToken"

    // кэш в памяти. Если на старте keychain был недоступен (залок) — перечитываем лениво.
    private var _token: String?
    var token: String? {
        if let _token { return _token }
        _token = read()
        return _token
    }

    private init() {
        _token = read()
    }

    func save(_ value: String) {
        _token = value
        let data = Data(value.utf8)
        SecItemDelete(base() as CFDictionary)               // перезаписываем
        var attrs = base()
        attrs[kSecValueData as String] = data
        // доступен на залоке (после первой разблокировки) — нужно для CallKit/VoIP на холодном старте
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attrs as CFDictionary, nil)
    }

    func clear() {
        _token = nil
        SecItemDelete(base() as CFDictionary)
    }

    private func base() -> [String: Any] {
        [ kSecClass as String: kSecClassGenericPassword,
          kSecAttrAccount as String: account,
          kSecAttrAccessGroup as String: AppGroup.keychainAccessGroup ]   // общий с NSE
    }

    private func read() -> String? {
        var q = base()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
