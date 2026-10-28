import Foundation
import CryptoKit

// Синхронизация истории переписки между своими устройствами — схема Signal linked-device history sync
// (полное описание: docs/history-sync.md). Транспорт и модель доверия — те же, что у ProfileKeySyncService:
// PQXDH-конверты устройство-устройство того же userId. Отличие: сам архив (большой) едет отдельным
// E2EE-блобом через storage, а в конверте — только одноразовый ключ + указатель + SHA-256.
//
// Дёргается из цикла AppViewModel.startKeySync (тот же wake: WS {type:"sync"} / silent-пуш / поллинг).
final class HistorySyncService {

    private static let requestedFlag = "historySyncRequested"   // AppGroup.defaults; сбрасывается на logout

    // ===== СТОРОНА-ПОЛУЧАТЕЛЬ (новое устройство): попросить историю =====

    // просим один раз за вход (флаг). НЕ гардим по «история пуста»: живые сообщения могут прийти
    // раньше первого прохода цикла, а импорт всё равно дедупит; лишний запрос при равных устройствах
    // безвреден (донор с пустой историей запросы не обслуживает).
    func requestIfNeeded() async {
        guard !AppGroup.defaults.bool(forKey: Self.requestedFlag) else { return }
        do {
            let _: CreateSyncRequestResponse =
                try await APIClient.shared.request("sync/history/requests", method: "POST")
            AppGroup.defaults.set(true, forKey: Self.requestedFlag)
            print("📚 history: запрос отправлен")
        } catch {
            print("📚 history request error:", error)   // повторим на следующем проходе цикла
        }
    }

    // забрать конверт → скачать блоб → проверить SHA-256 → расшифровать → импортировать → ack
    func fetchAndImport(myUserId: String, devices: [DeviceItem]) async {
        do {
            let resp: HistoryEnvelopesResponse = try await APIClient.shared.request("sync/history/envelopes")
            for env in resp.envelopes {
                guard let sender = devices.first(where: { $0.id == env.senderDeviceId }) else { continue }

                // блоб уже вычищен фоновым джобом → конверт бесполезен: ack + пере-запросить
                guard let urlString = env.archiveUrl, let url = URL(string: urlString) else {
                    try? await ack(env.id)
                    AppGroup.defaults.set(false, forKey: Self.requestedFlag)
                    continue
                }

                let plaintext = try await SignalSession.shared.decrypt(
                    envelopeType: env.envelopeType, ciphertextBase64: env.ciphertext,
                    userId: myUserId, protocolDeviceId: sender.protocolDeviceId)
                let payload = try JSONDecoder().decode(HistoryEnvelopePayload.self, from: plaintext)

                guard let keyData = Data(base64Encoded: payload.key), keyData.count == 32 else { continue }

                // скачиваем зашифрованный архив (сетевая ошибка → НЕ ack-аем, доберём позже)
                let (encrypted, _) = try await URLSession.shared.data(from: url)
                guard let box = try? AES.GCM.SealedBox(combined: encrypted),
                      let archiveData = try? AES.GCM.open(box, using: SymmetricKey(data: keyData)) else {
                    print("📚 history: не расшифровался архив — ack и пере-запрос")
                    try? await ack(env.id)
                    AppGroup.defaults.set(false, forKey: Self.requestedFlag)
                    continue
                }

                // целостность: SHA-256 открытого архива должен совпасть с заявленным в конверте
                let sha = Data(SHA256.hash(data: archiveData)).base64EncodedString()
                guard sha == payload.sha256 else {
                    print("📚 history: SHA-256 не совпал — архив отброшен")
                    try? await ack(env.id)
                    AppGroup.defaults.set(false, forKey: Self.requestedFlag)
                    continue
                }

                let archive = try JSONDecoder().decode(HistoryArchive.self, from: archiveData)
                let inserted = ChatStore.importArchive(archive.messages)
                for (userId, keyB64) in archive.contactKeys {
                    ContactKeyStore.save(userId: userId, profileKeyBase64: keyB64)
                }
                for b in archive.blocked ?? [] {                 // унаследовать блок-лист с донора
                    BlockStore.setBlocked(b.userId, username: b.username, blocked: true)
                }
                print("📚 history: импортировано \(inserted) из \(payload.count) сообщений, "
                      + "\(archive.contactKeys.count) ключей контактов, \(archive.blocked?.count ?? 0) блокировок")

                try await ack(env.id)   // сервер удалит блоб

                // обновить UI: чаты перечитают историю, кэш профилей подтянет имена/аватары
                await MainActor.run {
                    NotificationCenter.default.post(name: .pushNewMessage, object: nil)
                    BlockState.shared.reload()                   // подтянуть унаследованный блок-лист в UI
                    for userId in archive.contactKeys.keys {
                        ContactProfileCache.shared.refresh(userId)
                    }
                }
            }
        } catch {
            print("📚 history fetchAndImport error:", error)
        }
    }

    // ===== СТОРОНА-ДОНОР (устройство с историей): обслужить запросы =====

    func serveRequests(myUserId: String) async {
        guard ChatStore.messageCount() > 0 else { return }   // нечего отдавать — пусть ответит другой девайс
        do {
            let list: SyncRequestsResponse = try await APIClient.shared.request("sync/history/requests")
            for req in list.requests {
                do {                                   // каждый запрос отдельно: один битый не валит остальные
                    try await fulfill(request: req, myUserId: myUserId)
                } catch {
                    print("📚 history serve: запрос \(req.requestingDeviceId) пропущен:", error)
                }
            }
        } catch {
            print("📚 history serveRequests error:", error)
        }
    }

    private func fulfill(request: SyncRequestItem, myUserId: String) async throws {
        // 1. архив: вся история + Profile Key контактов
        let archive = HistoryArchive(
            messages: ChatStore.exportAll(),
            contactKeys: ContactKeyStore.allKeys(),
            blocked: BlockStore.all().map { ArchivedBlock(userId: $0.userId, username: $0.username) })
        let archiveData = try JSONEncoder().encode(archive)
        let sha = Data(SHA256.hash(data: archiveData)).base64EncodedString()

        // 2. одноразовый ключ (СВЕЖИЙ на каждый перенос — сервер его не видит никогда)
        let key = SymmetricKey(size: .bits256)
        let sealed = try AES.GCM.seal(archiveData, using: key)
        guard let blob = sealed.combined else { throw APIError.decoding }

        // 3. блоб на сервер (непрозрачный)
        let upload: HistoryArchiveUploadResponse =
            try await APIClient.shared.upload("sync/history/archive", fileField: "file", blobs: [blob])

        // 4. ключ+указатель — PQXDH-конвертом запросившему устройству (как Profile Key)
        let payload = HistoryEnvelopePayload(
            attachmentId: upload.attachmentId,
            key: key.withUnsafeBytes { Data($0) }.base64EncodedString(),
            sha256: sha,
            count: archive.messages.count)
        let plaintext = try JSONEncoder().encode(payload)

        let bundleDTO: PreKeyBundleResponse =
            try await APIClient.shared.request("keys/\(request.requestingDeviceId)/bundle")
        try await SignalSession.shared.establish(bundle: bundleDTO, userId: myUserId,
                                                 protocolDeviceId: bundleDTO.protocolDeviceId)
        let (envelopeType, ciphertext) = try await SignalSession.shared.encrypt(
            plaintext, userId: myUserId, protocolDeviceId: bundleDTO.protocolDeviceId)

        let body = DeliverHistoryEnvelopeRequest(
            recipientDeviceId: request.requestingDeviceId,
            requestId: request.id,
            envelopeType: envelopeType,
            ciphertext: ciphertext,
            attachmentId: upload.attachmentId)
        let _: CreateSyncRequestResponse =
            try await APIClient.shared.request("sync/history/envelopes", method: "POST", body: body)
        print("📚 history: архив (\(archive.messages.count) сообщений) отдан устройству \(request.requestingDeviceId.prefix(8))")
    }

    // ===== общее =====

    private func ack(_ envelopeId: String) async throws {
        let _: OkResponse = try await APIClient.shared.request(
            "sync/history/envelopes/\(envelopeId)/ack", method: "POST")
    }

    // на logout: чтобы следующий вход (возможно, другим аккаунтом) мог запросить историю заново
    static func resetFlags() {
        AppGroup.defaults.removeObject(forKey: requestedFlag)
    }
}
