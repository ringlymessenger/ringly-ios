import Foundation
import Security

// Полный сброс устройства: стирает ВСЁ локальное состояние приложения.
// Нужен потому, что на iOS Keychain переживает переустановку — без этого «чистого» состояния не получить.
// Чистит: токен, libsignal-стор, Profile Key, ключи контактов, ключ БД (Keychain) + UserDefaults + локальную БД.
enum DeviceReset {

    static func wipeEverything() {
        // 1. Локальная БД (SQLCipher) — теперь в shared-контейнере App Group; чистим и legacy Application Support.
        var dbDirs = [AppGroup.containerURL]
        dbDirs.append(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
        for dir in dbDirs {
            for name in ["ringly.sqlite", "ringly.sqlite-wal", "ringly.sqlite-shm"] {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("chats", isDirectory: true))
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("ingest.lock"))
        }

        // 2. Keychain — по сервисам/аккаунтам. localStore/token/contactKeys теперь в ОБЩЕЙ access-group
        //    (удаление без неё их не заденет), поэтому чистим оба варианта.
        deleteService("ringly.signal")                                  // legacy identity (до переноса в SQLCipher)
        deleteService("ringly.contactKeys", inSharedGroup: true)        // Profile Key контактов
        deleteService("ringly.localStore", inSharedGroup: true)         // ключ SQLCipher
        deleteAccount("deviceAuthToken", inSharedGroup: true)           // токен устройства (TokenStore)
        deleteAccount("profileKey", synchronizable: true)               // свой Profile Key (⚠️ уйдёт и из iCloud)

        // 3. UserDefaults — домен приложения + общий App-Group suite (protocolDeviceId, myUserId, security-события)
        if let bundleId = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleId)
        }
        AppGroup.defaults.removePersistentDomain(forName: AppGroup.identifier)
    }

    private static func deleteService(_ service: String, inSharedGroup: Bool = false) {
        for group in groupVariants(inSharedGroup) {
            var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service]
            if let group { q[kSecAttrAccessGroup as String] = group }
            SecItemDelete(q as CFDictionary)
        }
    }

    private static func deleteAccount(_ account: String, synchronizable: Bool = false, inSharedGroup: Bool = false) {
        for group in groupVariants(inSharedGroup) {
            var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: account]
            if synchronizable { q[kSecAttrSynchronizable as String] = true }
            if let group { q[kSecAttrAccessGroup as String] = group }
            SecItemDelete(q as CFDictionary)
        }
    }

    // [default-group, shared-group] если итем мог лечь в общую группу; иначе только default.
    private static func groupVariants(_ shared: Bool) -> [String?] {
        shared ? [nil, AppGroup.keychainAccessGroup] : [nil]
    }
}
