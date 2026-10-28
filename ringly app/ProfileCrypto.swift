import Foundation
import CryptoKit

enum ProfileCryptoError: Error { case noKey, badData }

enum ProfileCrypto {
    // ProfileData → зашифрованный base64 (для PUT /me)
    static func encrypt(_ profile: ProfileData) throws -> String {
        let key = ProfileKeyStore.shared.keyOrCreate()
        let plaintext = try JSONEncoder().encode(profile)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { throw ProfileCryptoError.badData }
        return combined.base64EncodedString()              // nonce + ciphertext + tag
    }

    // зашифрованный base64 (из GET /me) → ProfileData
    static func decrypt(_ base64: String) throws -> ProfileData {
        guard let key = ProfileKeyStore.shared.existingKey() else {
            throw ProfileCryptoError.noKey                  // нет ключа на этом устройстве
        }
        guard let data = Data(base64Encoded: base64) else {
            throw ProfileCryptoError.badData
        }
        let box = try AES.GCM.SealedBox(combined: data)
        let plaintext = try AES.GCM.open(box, using: key)
        return try JSONDecoder().decode(ProfileData.self, from: plaintext)
    }
    
    static func encryptBlob(_ data: Data) throws -> Data {
        let key = ProfileKeyStore.shared.keyOrCreate()
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else { throw ProfileCryptoError.badData }
        return combined            // nonce + ciphertext + tag
    }
    
    static func decryptBlob(_ data: Data) throws -> Data {
        guard let key = ProfileKeyStore.shared.existingKey() else { throw ProfileCryptoError.noKey }
        let box = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(box, using: key)
    }
}
