// файл: KeysService.swift
import Foundation
import LibSignalClient

final class KeysService {
    private let store = SignalProtocolStore.shared
    private let ctx = NullContext()                 // libsignal: «контекст без транзакции»

    // монотонный счётчик keyId, чтобы id не пересекались между регистрацией и дозаливами
    private func nextKeyId() -> Int {
        let k = "signalNextKeyId"
        let cur = UserDefaults.standard.integer(forKey: k)
        let next = (cur == 0 ? 1 : cur)
        UserDefaults.standard.set(next + 1, forKey: k)
        return next
    }

    // Регистрация привязана к ХОСТУ API: identity/signed живут в БД конкретного сервера.
    // Если хост сменился (локальный → прод, другой инстанс, ресет БД с другим хостом) —
    // считаем «не зарегистрированы» и форсим повторный POST /keys. Иначе на новом сервере
    // окажутся только one-time/kyber (из topUp), без identity/signed → устройство выпадает
    // из GET /users/:id/devices и сообщения не отправляются.
    // Поколение регистрации. Увеличить — значит заставить КАЖДОЕ устройство один раз перезалить
    // ключевой материал. Это путь восстановления для устройств, у которых он уже рассогласован.
    //
    // Зачем понадобился: старый POST /keys заменял identity, но оставлял kyber-ключи, подписанные
    // ПРЕЖНИМ identity (а новые терялись из-за skipDuplicates + сброса счётчика keyId при
    // переустановке). Отправитель, забрав такой бандл, падал с invalidSignature и молча выкидывал
    // устройство из fan-out — сообщения переставали доходить, и само это не лечилось никогда.
    //
    // Перерегистрация безопасна: loadOrCreateIdentity() отдаёт СУЩЕСТВУЮЩИЙ локальный identity,
    // он не меняется. Обновляются только prekeys, поэтому уже установленные сессии собеседников
    // остаются валидными и «номер безопасности» не меняется.
    //
    // ВАЖНО: поднимать поколение можно только когда на сервере уже развёрнут POST /keys,
    // удаляющий прежний набор. Иначе новые ключи снова будут отброшены по совпадению keyId.
    private static let keysGeneration = 2

    var isRegistered: Bool {
        UserDefaults.standard.integer(forKey: "signalKeysGeneration") == Self.keysGeneration
            && UserDefaults.standard.string(forKey: "signalRegisteredHost") == AppConfig.apiBaseURL.host
    }

    // POST /keys — первичная регистрация ключевого материала этого устройства
    func registerIfNeeded() async {
        guard !isRegistered else { return }
        do {
            let identity = try store.loadOrCreateIdentity()

            // 1. signed prekey (классический X25519, подписан identity-ключом)
            let spkId = nextKeyId()
            let spkPair = PrivateKey.generate()
            let spkSig = identity.privateKey.generateSignature(message: spkPair.publicKey.serialize())
            let spkRecord = try SignedPreKeyRecord(
                id: UInt32(spkId), timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                privateKey: spkPair, signature: spkSig
            )
            try store.storeSignedPreKey(spkRecord, id: UInt32(spkId), context: ctx)

            // 2. kyber prekeys: одна last-resort + пачка одноразовых (post-quantum половина PQXDH)
            var kyberDTOs: [KyberPreKeyDTO] = []
            // last-resort (переиспользуемый запасной)
            kyberDTOs.append(try makeKyber(identity: identity, isLastResort: true))
            // одноразовые kyber
            for _ in 0..<10 { kyberDTOs.append(try makeKyber(identity: identity, isLastResort: false)) }

            // 3. one-time prekeys (классические)
            let oneTimeDTOs = try (0..<50).map { _ in try makeOneTime() }

            let body = RegisterKeysRequest(
                identityKey: Data(identity.identityKey.serialize()).base64EncodedString(),
                signedPreKey: SignedPreKeyDTO(
                    keyId: spkId,
                    publicKey: Data(spkPair.publicKey.serialize()).base64EncodedString(),
                    signature: Data(spkSig).base64EncodedString()
                ),
                kyberPreKeys: kyberDTOs,
                oneTimePreKeys: oneTimeDTOs
            )
            let _: OkResponse = try await APIClient.shared.request("keys", method: "POST", body: body)
            UserDefaults.standard.set(Self.keysGeneration, forKey: "signalKeysGeneration")
            UserDefaults.standard.set(AppConfig.apiBaseURL.host, forKey: "signalRegisteredHost")  // привязка к серверу
        } catch {
            print("registerKeys error:", error)   // не критично для UI — попробуем снова на следующем старте
        }
    }

    // GET /keys/count → POST /keys/one-time, если пул просел
    func topUpIfLow() async {
        guard isRegistered else { return }
        do {
            let count: KeyCountResponse = try await APIClient.shared.request("keys/count")
            guard count.oneTimePreKeys < 10 || count.kyberOneTimePreKeys < 3 else { return }

            let identity = try store.loadOrCreateIdentity()
            let oneTime = count.oneTimePreKeys < 10 ? try (0..<50).map { _ in try makeOneTime() } : []
            let kyber = count.kyberOneTimePreKeys < 3
                ? try (0..<10).map { _ in try makeKyber(identity: identity, isLastResort: false) } : []

            let body = TopUpKeysRequest(oneTimePreKeys: oneTime, kyberPreKeys: kyber)
            let _: OkResponse = try await APIClient.shared.request("keys/one-time", method: "POST", body: body)
        } catch {
            print("topUp error:", error)
        }
    }

    // --- helpers: создаём запись, кладём приватную часть в стор, возвращаем публичный DTO ---

    private func makeOneTime() throws -> OneTimePreKeyDTO {
        let id = nextKeyId()
        let pair = PrivateKey.generate()
        let record = try PreKeyRecord(id: UInt32(id), publicKey: pair.publicKey, privateKey: pair)
        try store.storePreKey(record, id: UInt32(id), context: ctx)
        return OneTimePreKeyDTO(keyId: id, publicKey: Data(pair.publicKey.serialize()).base64EncodedString())
    }

    private func makeKyber(identity: IdentityKeyPair, isLastResort: Bool) throws -> KyberPreKeyDTO {
        let id = nextKeyId()
        let kemPair = KEMKeyPair.generate()
        let sig = identity.privateKey.generateSignature(message: kemPair.publicKey.serialize())
        let record = try KyberPreKeyRecord(
            id: UInt32(id), timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            keyPair: kemPair, signature: sig
        )
        try store.storeKyberPreKey(record, id: UInt32(id), context: ctx)
        if isLastResort {
            try store.markKyberLastResort(UInt32(id))   // чтобы markKyberPreKeyUsed его не удалял
        }
        return KyberPreKeyDTO(
            keyId: id,
            publicKey: Data(kemPair.publicKey.serialize()).base64EncodedString(),
            signature: Data(sig).base64EncodedString(),
            isLastResort: isLastResort
        )
    }
}
