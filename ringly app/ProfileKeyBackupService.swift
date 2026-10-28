import Foundation
import CryptoKit
import LibSignalClient

enum BackupError: LocalizedError {
    case noKey, badData, wrongPin, locked
    var errorDescription: String? {
        switch self {
        case .noKey:    return L("На этом устройстве нет ключа профиля для бэкапа")
        case .badData:  return L("Повреждённые данные бэкапа")
        case .wrongPin: return L("Неверный PIN")
        case .locked:   return L("Слишком много попыток. Попробуйте позже")
        }
    }
}

// Содержимое PIN-копии. v1 — сырые 32 байта Profile Key (так писали до копии в iCloud),
// v2 — JSON с ещё одной половиной ключа копии переписки (docs/icloud-backup.md §3).
// Сервер видит только шифртекст, формат для него не меняется.
private struct PinBackupPayload: Codable {
    var v = 2
    var profileKey: String          // base64 32 байта
    var icloudHalfB: String?        // base64 32 байта
}

final class ProfileKeyBackupService {
    private let kdf = KdfParams(algo: "argon2id-pinhash", v: 1)

    // ---- СОХРАНЕНИЕ (на устройстве, где ключ ЕСТЬ) ----
    // Вместе с ключом профиля уходит halfB ключа копии в iCloud: прежняя, если она уже есть на
    // устройстве (иначе существующая копия перестала бы открываться), или новая.
    func save(pin: String) async throws {
        guard let profileKey = ProfileKeyStore.shared.rawKey() else { throw BackupError.noKey }
        guard let userId = AuthState.myUserId else { throw BackupError.noKey }
        let halfB = BackupKeys.halfB(userId: userId) ?? BackupKeys.newHalfB()
        let payload = try JSONEncoder().encode(PinBackupPayload(
            profileKey: profileKey.base64EncodedString(), icloudHalfB: halfB.base64EncodedString()))

        var salt = Data(count: 32)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }

        let pinHash = try PinHash(normalizedPin: Array(normalize(pin).utf8), salt: Array(salt))
        let encryptionKey = SymmetricKey(data: Data(pinHash.encryptionKey))
        let accessKey = Data(pinHash.accessKey)

        let sealed = try AES.GCM.seal(payload, using: encryptionKey)
        guard let combined = sealed.combined else { throw BackupError.badData }
        let accessKeyHash = Data(SHA256.hash(data: accessKey))

        let body = SaveBackupRequest(
            salt: salt.base64EncodedString(),
            accessKeyHash: accessKeyHash.base64EncodedString(),
            ciphertext: combined.base64EncodedString(),
            kdf: kdf
        )
        let _: OkResponse = try await APIClient.shared.request("backup/profile-key", method: "PUT", body: body)
        BackupKeys.saveHalfB(halfB, userId: userId)    // только после того, как сервер её принял
    }

    // ---- ВОССТАНОВЛЕНИЕ (чистый девайс, у юзера статус уже COMPLETED) ----
    func restore(pin: String) async throws {
        let (profileKey, halfB) = try await open(pin: pin)
        ProfileKeyStore.shared.saveRaw(profileKey)
        if let halfB, let userId = AuthState.myUserId { BackupKeys.saveHalfB(halfB, userId: userId) }
    }

    // Включение копии в iCloud у того, у кого PIN уже задан: проверить PIN, забрать из PIN-копии
    // halfB (если она там есть) и переписать копию в формате v2. Ключ профиля при этом НЕ трогаем:
    // локальный — источник правды, перезаписать его старым из копии значило бы сломать свой профиль.
    func unlockICloudBackup(pin: String) async throws {
        let (_, halfB) = try await open(pin: pin)
        if let halfB, let userId = AuthState.myUserId { BackupKeys.saveHalfB(halfB, userId: userId) }
        try await save(pin: pin)
    }

    private func open(pin: String) async throws -> (profileKey: Data, halfB: Data?) {
        // 1. соль + параметры KDF
        let params: BackupParamsResponse
        do {
            params = try await APIClient.shared.request("backup/profile-key/params")
        } catch APIError.http(429) { throw BackupError.locked }

        guard let salt = Data(base64Encoded: params.salt) else { throw BackupError.badData }
        let pinHash = try PinHash(normalizedPin: Array(normalize(pin).utf8), salt: Array(salt))
        let accessKey = Data(pinHash.accessKey)
        let encryptionKey = SymmetricKey(data: Data(pinHash.encryptionKey))

        // 2. проверить accessKey на сервере и забрать шифртекст
        let resp: RestoreBackupResponse
        do {
            resp = try await APIClient.shared.request(
                "backup/profile-key/restore", method: "POST",
                body: RestoreBackupRequest(accessKey: accessKey.base64EncodedString())
            )
        } catch APIError.server { throw BackupError.wrongPin }      // 401 Invalid PIN
          catch APIError.http(401) { throw BackupError.wrongPin }
          catch APIError.http(429) { throw BackupError.locked }

        // 3. расшифровать своим encryptionKey
        guard let combined = Data(base64Encoded: resp.ciphertext) else { throw BackupError.badData }
        let box = try AES.GCM.SealedBox(combined: combined)
        let plain = try AES.GCM.open(box, using: encryptionKey)

        if plain.count == 32 { return (plain, nil) }     // v1: сырой Profile Key
        guard let payload = try? JSONDecoder().decode(PinBackupPayload.self, from: plain),
              let profileKey = Data(base64Encoded: payload.profileKey), profileKey.count == 32 else {
            throw BackupError.badData
        }
        let halfB = payload.icloudHalfB.flatMap { Data(base64Encoded: $0) }.flatMap { $0.count == 32 ? $0 : nil }

        return (profileKey, halfB)
    }

    func delete() async throws {
        let _: OkResponse = try await APIClient.shared.request("backup/profile-key", method: "DELETE")
    }

    // есть ли на сервере PIN-бэкап. true/false — достоверный ответ; nil — не удалось узнать (сеть),
    // вызывающий попробует позже. Нужно, чтобы решить: восстановление ОБЯЗАТЕЛЬНО (PIN задан) или
    // ключа ждать неоткуда, кроме синка с другого устройства.
    func backupExists() async -> Bool? {
        do {
            let _: BackupParamsResponse = try await APIClient.shared.request("backup/profile-key/params")
            return true
        } catch APIError.server(let msg) {
            if msg.contains("No profile key backup") { return false }   // 404 бэкенда
            return true    // иные ответы сервера (например, залочен после перебора) = бэкап существует
        } catch {
            return nil     // сеть и прочее — неизвестно
        }
    }

    // нормализация PIN (упрощённо). Signal делает NFKD + lowercase для буквенных — можно добить позже.
    private func normalize(_ pin: String) -> String {
        pin.trimmingCharacters(in: .whitespaces)
    }
}
