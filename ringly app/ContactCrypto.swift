import Foundation
import CryptoKit

enum ContactCrypto {
    // профиль контакта (имя/фамилия) из его encryptedProfile + его Profile Key
    static func decryptProfile(_ base64: String, key: SymmetricKey) -> ProfileData? {
        guard let data = Data(base64Encoded: base64),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return try? JSONDecoder().decode(ProfileData.self, from: plain)
    }

    // аватар контакта: зашифрованный блоб (скачан по presigned-ссылке) + его Profile Key → байты картинки
    static func decryptBlob(_ data: Data, key: SymmetricKey) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return plain
    }
}
