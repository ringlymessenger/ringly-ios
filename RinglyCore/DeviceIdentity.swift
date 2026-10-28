import Foundation
import Security

enum DeviceIdentity {
    // ===== protocolDeviceId — идентичность ФИЗИЧЕСКОГО устройства =====
    //
    // Уникален на каждом устройстве: сервер ищет строку Device по @@unique([userId, protocolDeviceId]),
    // поэтому одинаковые номера у двух устройств склеили бы их в одно.
    //
    // Хранится в KEYCHAIN, а не в контейнере приложения, и НЕ стирается при выходе из аккаунта.
    // Причина: при удалении приложения контейнер (вместе с AppGroup.defaults) уничтожается, а Keychain
    // переживает — именно поэтому вход сохраняется после переустановки. Пока номер лежал в контейнере,
    // каждая переустановка или выход из аккаунта давали новый номер → upsert на сервере не находил
    // прежнюю строку и заводил НОВУЮ, а старая оставалась «призраком»: она проходит проверку пригодности,
    // все отправители обязаны под неё шифровать, но забрать сообщения некому. Один такой призрак с
    // рассогласованными ключами однажды полностью парализовал отправку у аккаунта.
    // Разбор: docs/keys-consistency-incident.md
    //
    // Переиспользование безопасно и при смене аккаунта: ключ уникальности включает userId, поэтому
    // другой пользователь на том же устройстве всё равно получит собственную строку.
    static var protocolDeviceId: Int {
        // libsignal требует device ID в диапазоне 1...127 (см. ProtocolAddress).
        if let saved = keychainInt(account: Keys.protocolDeviceId), (1...127).contains(saved) {
            return saved
        }

        // Миграция: у существующих установок номер лежит в контейнере. Переносим ЕГО, а не генерим
        // новый — иначе обновление приложения само создало бы призрака каждому пользователю.
        if let legacy = AppGroup.defaults.object(forKey: Keys.protocolDeviceId) as? Int,
           (1...127).contains(legacy) {
            setKeychainInt(legacy, account: Keys.protocolDeviceId)

            return legacy
        }

        let value = Int.random(in: 2...127)   // 1 ← у «первого» устройства; коллизии при паре устройств редки
        setKeychainInt(value, account: Keys.protocolDeviceId)

        return value
    }

    // ===== registrationId — идентификатор КОНКРЕТНОЙ регистрации =====
    //
    // Намеренно НЕ в Keychain: он привязан к текущему состоянию libsignal-стора. Сброс стора
    // (выход из аккаунта, вход другим аккаунтом) создаёт новую identity — значит и регистрация новая.
    // Сервер обязан подхватывать изменившееся значение в ветке update у device.upsert, иначе будет
    // отдавать в PreKeyBundle устаревший registrationId.
    static var registrationId: Int {
        if let saved = AppGroup.defaults.object(forKey: Keys.registrationId) as? Int {
            return saved
        }
        let value = Int.random(in: 1...16380)
        AppGroup.defaults.set(value, forKey: Keys.registrationId)

        return value
    }

    private enum Keys {
        static let protocolDeviceId = "protocolDeviceId"
        static let registrationId = "registrationId"
    }

    // ===== Keychain (атрибуты — как у TokenStore, включая общую с NSE access group) =====

    private static func base(account: String) -> [String: Any] {
        [ kSecClass as String: kSecClassGenericPassword,
          kSecAttrAccount as String: account,
          kSecAttrAccessGroup as String: AppGroup.keychainAccessGroup ]
    }

    private static func keychainInt(account: String) -> Int? {
        var q = base(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let text = String(data: data, encoding: .utf8) else { return nil }

        return Int(text)
    }

    private static func setKeychainInt(_ value: Int, account: String) {
        SecItemDelete(base(account: account) as CFDictionary)
        var attrs = base(account: account)
        attrs[kSecValueData as String] = Data(String(value).utf8)
        // как у токена: доступно на залоке после первой разблокировки (нужно NSE и VoIP на холодном старте)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attrs as CFDictionary, nil)
    }
}
