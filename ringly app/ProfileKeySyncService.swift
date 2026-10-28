// файл: ProfileKeySyncService.swift
import Foundation

final class ProfileKeySyncService {

    // ===== СТОРОНА B (нет ключа): попросить =====

    // вызывать после registerIfNeeded(), если ProfileKeyStore.existingKey() == nil
    func requestKey() async {
        do {
            let _: CreateSyncRequestResponse =
                try await APIClient.shared.request("sync/profile-key/requests", method: "POST")
        } catch {
            print("requestKey error:", error)
        }
    }

    // ===== СТОРОНА A (есть ключ): обслужить запросы соседей =====

    func serveRequests(myUserId: String) async {
        guard let profileKey = ProfileKeyStore.shared.rawKey() else { return }   // нет ключа — нечего раздавать
        do {
            let list: SyncRequestsResponse = try await APIClient.shared.request("sync/profile-key/requests")
            for req in list.requests {
                do {                                   // каждый запрос отдельно: один битый не валит остальные
                    try await fulfill(request: req, profileKey: profileKey, myUserId: myUserId)
                } catch {
                    print("serveRequests: запрос \(req.requestingDeviceId) пропущен:", error)
                }
            }
        } catch {
            print("serveRequests error:", error)
        }
    }

    private func fulfill(request: SyncRequestItem, profileKey: Data, myUserId: String) async throws {
        // 1. bundle устройства B (списывает его one-time prekey)
        let bundleDTO: PreKeyBundleResponse =
            try await APIClient.shared.request("keys/\(request.requestingDeviceId)/bundle")

        // 2–4. сессия + шифрование через общий actor (адрес — мой userId: это сосед-устройство того же юзера)
        try await SignalSession.shared.establish(bundle: bundleDTO, userId: myUserId,
                                                  protocolDeviceId: bundleDTO.protocolDeviceId)
        let (envelopeType, ciphertext) = try await SignalSession.shared.encrypt(
            profileKey, userId: myUserId, protocolDeviceId: bundleDTO.protocolDeviceId)

        // 5. отдать конверт серверу (он закроет запрос)
        let body = DeliverEnvelopeRequest(
            recipientDeviceId: request.requestingDeviceId,
            requestId: request.id,
            envelopeType: envelopeType,
            ciphertext: ciphertext
        )
        let _: CreateSyncRequestResponse =
            try await APIClient.shared.request("sync/profile-key/envelopes", method: "POST", body: body)
    }

    // ===== СТОРОНА B: забрать и расшифровать =====

    // true, если ключ получен и сохранён
    @discardableResult
    func fetchAndDecrypt(myUserId: String, devices: [DeviceItem]) async -> Bool {
        do {
            let resp: EnvelopesResponse = try await APIClient.shared.request("sync/profile-key/envelopes")
            for env in resp.envelopes {
                // protocolDeviceId отправителя A — из списка своих устройств (из GET /me)
                guard let sender = devices.first(where: { $0.id == env.senderDeviceId }) else { continue }

                let plaintext = try await SignalSession.shared.decrypt(
                    envelopeType: env.envelopeType, ciphertextBase64: env.ciphertext,
                    userId: myUserId, protocolDeviceId: sender.protocolDeviceId)

                guard plaintext.count == 32 else { continue }   // должен быть 32-байтовый Profile Key
                ProfileKeyStore.shared.saveRaw(plaintext)
                let _: OkResponse =
                    try await APIClient.shared.request("sync/profile-key/envelopes/\(env.id)/ack", method: "POST")
                return true
            }
        } catch {
            print("fetchAndDecrypt error:", error)
        }
        return false
    }
}
