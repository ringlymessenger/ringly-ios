import Foundation
import LibSignalClient

// Единая точка ВСЕХ libsignal-операций. actor → они исполняются строго по очереди,
// конкурентного доступа к сессиям/стору не существует по построению (как StoreContext-транзакция в Signal).
// Через него идут и messaging, и profile-key-sync — никаких прямых вызовов крипты в обход.
actor SignalSession {
    static let shared = SignalSession()

    private let store = SignalProtocolStore.shared
    private let ctx = NullContext()

    private func myAddress() throws -> ProtocolAddress {
        let myUserId = AuthState.myUserId ?? ""
        return try ProtocolAddress(name: myUserId, deviceId: UInt32(DeviceIdentity.protocolDeviceId))
    }

    private func address(userId: String, protocolDeviceId: Int) throws -> ProtocolAddress {
        try ProtocolAddress(name: userId, deviceId: UInt32(protocolDeviceId))
    }

    // messaging: гарантировать сессию (сама тянет PreKeyBundle, если сессии ещё нет)
    func ensureSession(userId: String, deviceId: String, protocolDeviceId: Int) async throws {
        let addr = try address(userId: userId, protocolDeviceId: protocolDeviceId)
        if try store.loadSession(for: addr, context: ctx) != nil { return }   // уже есть
        let dto: PreKeyBundleResponse = try await APIClient.shared.request("keys/\(deviceId)/bundle")
        try processPreKeyBundle(buildBundle(dto), for: addr, ourAddress: myAddress(),
                                sessionStore: store, identityStore: store, context: ctx)
    }

    // Сбросить сессию с устройством: следующая отправка возьмёт свежий PreKeyBundle и начнёт заново.
    // Единственный способ починить рассинхронизированную сессию — заменить её (Signal делает то же
    // самое, архивируя состояние при получении retry receipt).
    func resetSession(userId: String, protocolDeviceId: Int) throws {
        store.deleteSession(for: try address(userId: userId, protocolDeviceId: protocolDeviceId))
    }

    // profile-key-sync: установить сессию по УЖЕ полученному bundle (без повторного fetch)
    func establish(bundle dto: PreKeyBundleResponse, userId: String, protocolDeviceId: Int) throws {
        let addr = try address(userId: userId, protocolDeviceId: protocolDeviceId)
        try processPreKeyBundle(buildBundle(dto), for: addr, ourAddress: myAddress(),
                                sessionStore: store, identityStore: store, context: ctx)
    }

    // зашифровать payload для устройства → (envelopeType, ciphertext)
    func encryptRaw(_ plaintext: Data, userId: String, protocolDeviceId: Int) throws -> (Int, Data) {
        let addr = try address(userId: userId, protocolDeviceId: protocolDeviceId)
        let cipher = try signalEncrypt(message: plaintext, for: addr, localAddress: myAddress(),
                                       sessionStore: store, identityStore: store, context: ctx)
        return (Int(cipher.messageType.rawValue), Data(cipher.serialize()))
    }

    // то же самое, но base64 — для путей, которые кладут шифртекст в JSON
    func encrypt(_ plaintext: Data, userId: String, protocolDeviceId: Int) throws -> (Int, String) {
        let (type, cipher) = try encryptRaw(plaintext, userId: userId, protocolDeviceId: protocolDeviceId)
        return (type, cipher.base64EncodedString())
    }

    // расшифровать входящий конверт
    func decrypt(envelopeType: Int, ciphertextBase64: String,
                 userId: String, protocolDeviceId: Int) throws -> Data {
        let addr = try address(userId: userId, protocolDeviceId: protocolDeviceId)
        let bytes = Array(Data(base64Encoded: ciphertextBase64) ?? Data())
        if envelopeType == 3 {                                   // prekey message (новая сессия)
            let msg = try PreKeySignalMessage(bytes: bytes)
            return try signalDecryptPreKey(message: msg, from: addr, localAddress: myAddress(),
                                           sessionStore: store, identityStore: store,
                                           preKeyStore: store, signedPreKeyStore: store,
                                           kyberPreKeyStore: store, context: ctx)
        } else {                                                 // обычное сообщение
            let msg = try SignalMessage(bytes: bytes)
            return try signalDecrypt(message: msg, from: addr, to: myAddress(),
                                     sessionStore: store, identityStore: store, context: ctx)
        }
    }

    // собрать PreKeyBundle из ответа сервера
    private func buildBundle(_ d: PreKeyBundleResponse) throws -> PreKeyBundle {
        let identity = try IdentityKey(bytes: Array(Data(base64Encoded: d.identityKey)!))
        let signedPub = try PublicKey(Array(Data(base64Encoded: d.signedPreKey.publicKey)!))
        let signedSig = Array(Data(base64Encoded: d.signedPreKey.signature)!)
        let kyberPub = try KEMPublicKey(Array(Data(base64Encoded: d.kyberPreKey.publicKey)!))
        let kyberSig = Array(Data(base64Encoded: d.kyberPreKey.signature)!)
        if let ot = d.oneTimePreKey {
            let otPub = try PublicKey(Array(Data(base64Encoded: ot.publicKey)!))
            return try PreKeyBundle(
                registrationId: UInt32(d.registrationId), deviceId: UInt32(d.protocolDeviceId),
                prekeyId: UInt32(ot.keyId), prekey: otPub,
                signedPrekeyId: UInt32(d.signedPreKey.keyId), signedPrekey: signedPub,
                signedPrekeySignature: signedSig, identity: identity,
                kyberPrekeyId: UInt32(d.kyberPreKey.keyId), kyberPrekey: kyberPub, kyberPrekeySignature: kyberSig)
        } else {
            return try PreKeyBundle(
                registrationId: UInt32(d.registrationId), deviceId: UInt32(d.protocolDeviceId),
                signedPrekeyId: UInt32(d.signedPreKey.keyId), signedPrekey: signedPub,
                signedPrekeySignature: signedSig, identity: identity,
                kyberPrekeyId: UInt32(d.kyberPreKey.keyId), kyberPrekey: kyberPub, kyberPrekeySignature: kyberSig)
        }
    }
}

// держатель своего userId, чтобы крипте не таскать его аргументом.
// В App-Group defaults — чтобы NSE (другой процесс) тоже знал, кто мы, для адресации расшифровки.
enum AuthState {
    private static let key = "myUserId"
    static var myUserId: String? {
        get { AppGroup.defaults.string(forKey: key) }
        set { AppGroup.defaults.set(newValue, forKey: key) }   // выставляется в AppViewModel.setMe (me.id)
    }
}
