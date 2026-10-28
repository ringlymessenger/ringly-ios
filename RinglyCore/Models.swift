import Foundation

// onboardingState с сервера: "PENDING_PROFILE" | "COMPLETED"
enum OnboardingState: String, Codable {
    case pendingProfile = "PENDING_PROFILE"
    case completed = "COMPLETED"
}

// ответ POST /auth/oauth → { token, onboardingState, userId }
struct OAuthResponse: Decodable {
    let token: String
    let onboardingState: OnboardingState
    let userId: String
}

// ответ GET /me (поля по разделу 5 дока: username?, encryptedProfile?, avatarAttachmentIds, onboardingState)
struct MeResponse: Decodable {
    let id: String
    let username: String?
    let encryptedProfile: String?          // base64, сервер не читает; расшифровываем на клиенте
    let avatarAttachmentIds: [String]
    let avatars: [AvatarItem]
    let onboardingState: OnboardingState
    let devices: [DeviceItem]?
}

struct DeviceItem: Decodable {
    let id: String                          // uuid (== senderDeviceId/requestingDeviceId)
    let protocolDeviceId: Int
    // ниже — только для экрана «Устройства» (GET /me отдаёт, остальные потребители не используют).
    // Даты — СТРОКАМИ намеренно: APIClient использует JSONDecoder() без dateDecodingStrategy,
    // и объявление их как Date уронило бы разбор ВСЕГО ответа /me (ошибка глотается через try?,
    // приложение осталось бы без профиля). Разбор ISO-8601 — на месте использования.
    let platform: String?                   // "IOS" | "ANDROID"
    let deviceName: String?
    let lastSeenAt: String?
    let createdAt: String?
    let isCurrent: Bool?
}

struct OAuthRequest: Encodable {
    let provider: String          // "google" | "apple"
    let idToken: String
    let device: DeviceInfo

    struct DeviceInfo: Encodable {
        let platform: String      // "IOS"
        let deviceName: String?
        let registrationId: Int
        let protocolDeviceId: Int
    }
}

// POST /auth/demo — вход в демо-аккаунт для App Review (логин и пароль из .env сервера).
// Ответ тот же, что у /auth/oauth.
struct DemoLoginRequest: Encodable {
    let username: String
    let password: String
    let device: OAuthRequest.DeviceInfo
}

// GET /auth/demo — открыт ли сейчас демо-вход (включается на сервере только на время ревью)
struct DemoStatus: Decodable { let enabled: Bool }

// ответ POST /attachments → { ids: [...] }
struct UploadResponse: Decodable {
    let ids: [String]
}

// тело PUT /me
struct CompleteProfileRequest: Encodable {
    let username: String
    let encryptedProfile: String                 // base64 шифрованного профиля
    let avatarAttachmentIds: [String]?           // nil, если без аватара
    // Ник из инвайт-ссылки, по которой пришли (см. InviteOrigin). nil при редактировании профиля —
    // синтезированный Encodable опускает nil-поля, так что сервер их просто не увидит.
    let invitedByUsername: String?
}

// ответ PUT /me → { username, onboardingState }
struct CompleteProfileResponse: Decodable {
    let username: String?
    let onboardingState: OnboardingState
}

struct AvatarItem: Codable {
    let id: String
    let url: String
}

struct RegisterKeysRequest: Encodable {
    let identityKey: String                 // base64 публичного identity-ключа
    let signedPreKey: SignedPreKeyDTO
    let kyberPreKeys: [KyberPreKeyDTO]
    let oneTimePreKeys: [OneTimePreKeyDTO]
}
struct SignedPreKeyDTO: Encodable {
    let keyId: Int
    let publicKey: String                   // base64
    let signature: String                   // base64
}
struct KyberPreKeyDTO: Encodable {
    let keyId: Int
    let publicKey: String
    let signature: String
    let isLastResort: Bool
}
struct OneTimePreKeyDTO: Encodable {
    let keyId: Int
    let publicKey: String
}

// тело POST /keys/one-time
struct TopUpKeysRequest: Encodable {
    let oneTimePreKeys: [OneTimePreKeyDTO]
    let kyberPreKeys: [KyberPreKeyDTO]
}

// GET /keys/count
struct KeyCountResponse: Decodable {
    let oneTimePreKeys: Int
    let kyberOneTimePreKeys: Int
}

// GET /keys/:deviceId/bundle
struct PreKeyBundleResponse: Decodable {
    let registrationId: Int
    let deviceId: String                    // uuid целевого устройства
    let protocolDeviceId: Int               // Signal device number (для ProtocolAddress)
    let identityKey: String                 // base64
    let signedPreKey: SignedPreKeyDTOOut
    let oneTimePreKey: OneTimePreKeyDTOOut?  // может быть null (пул опустошён)
    let kyberPreKey: KyberPreKeyDTOOut
}
struct SignedPreKeyDTOOut: Decodable { let keyId: Int; let publicKey: String; let signature: String }
struct OneTimePreKeyDTOOut: Decodable { let keyId: Int; let publicKey: String }
struct KyberPreKeyDTOOut: Decodable { let keyId: Int; let publicKey: String; let signature: String }

struct OkResponse: Decodable { let ok: Bool }

// POST /me/push-token { pushToken } — регистрация APNs device token устройства
struct PushTokenRequest: Encodable { let pushToken: String }
// POST /me/voip-token { voipToken } — PushKit VoIP token (для CallKit-входящих)
struct VoipTokenRequest: Encodable { let voipToken: String }

// ---- Этап 1: device-to-device sync ----

// POST /sync/profile-key/requests → { id, createdAt }
struct CreateSyncRequestResponse: Decodable { let id: String }

// GET /sync/profile-key/requests → { requests: [...] }
struct SyncRequestsResponse: Decodable { let requests: [SyncRequestItem] }
struct SyncRequestItem: Decodable {
    let id: String
    let requestingDeviceId: String          // uuid устройства B (его и шлём в /keys/:id/bundle)
}

// тело POST /sync/profile-key/envelopes
struct DeliverEnvelopeRequest: Encodable {
    let recipientDeviceId: String           // uuid устройства B
    let requestId: String?
    let envelopeType: Int                   // CiphertextMessage.messageType.rawValue (3=prekey,2=whisper)
    let ciphertext: String                  // base64 PQXDH-шифртекста ProfileKey
}

// GET /sync/profile-key/envelopes → { envelopes: [...] }
struct EnvelopesResponse: Decodable { let envelopes: [EnvelopeItem] }
struct EnvelopeItem: Decodable {
    let id: String
    let senderDeviceId: String              // uuid устройства A
    let envelopeType: Int
    let ciphertext: String                  // base64
}

// ---- Синхронизация истории переписки (Signal linked-device history sync) ----
// Донор шифрует архив истории свежим ключом → блоб на сервер (непрозрачный) → ключ+указатель
// PQXDH-конвертом. Сервер видит только шифртексты. Полная схема: docs/history-sync.md.

// POST /sync/history/archive (multipart, поле file) → { attachmentId }
struct HistoryArchiveUploadResponse: Decodable { let attachmentId: String }

// тело POST /sync/history/envelopes
struct DeliverHistoryEnvelopeRequest: Encodable {
    let recipientDeviceId: String
    let requestId: String?
    let envelopeType: Int
    let ciphertext: String                  // base64 PQXDH(HistoryEnvelopePayload)
    let attachmentId: String
}

// GET /sync/history/envelopes → { envelopes: [...] }
struct HistoryEnvelopesResponse: Decodable { let envelopes: [HistoryEnvelopeItem] }
struct HistoryEnvelopeItem: Decodable {
    let id: String
    let senderDeviceId: String
    let envelopeType: Int
    let ciphertext: String                  // base64
    let archiveUrl: String?                 // presigned; nil = блоб уже вычищен → ack + пере-запрос
}

// открытый текст PQXDH-конверта (сервер не видит)
struct HistoryEnvelopePayload: Codable {
    var v: Int = 1
    var attachmentId: String
    var key: String                         // base64 32 байта — одноразовый AES-GCM ключ архива
    var sha256: String                      // base64 SHA-256 ОТКРЫТОГО архива (целостность)
    var count: Int                          // сообщений в архиве (сверка после импорта)
}

// сам архив (внутри AES-GCM; сервер не видит)
struct HistoryArchive: Codable {
    var v: Int = 1
    var messages: [LocalMessage]
    var contactKeys: [String: String]       // userId → base64 Profile Key контакта (иначе на новом
                                            // устройстве не расшифровать имена/аватары до их следующего сообщения)
    var blocked: [ArchivedBlock]?           // локальный блок-лист (opt — совместимость со старыми архивами)
}

// запись блок-листа в архиве history-sync (чтобы новое устройство унаследовало блокировки)
struct ArchivedBlock: Codable {
    var userId: String
    var username: String?
}

// ---- Этап 2: PIN-бэкап ----

struct SaveBackupRequest: Encodable {
    let salt: String                        // base64
    let accessKeyHash: String               // base64 SHA-256(accessKey)
    let ciphertext: String                  // base64 AES-GCM(ProfileKey)
    let kdf: KdfParams
}
struct KdfParams: Codable { let algo: String; let v: Int }

struct BackupParamsResponse: Decodable {
    let salt: String
    let kdf: KdfParams
}
struct RestoreBackupRequest: Encodable { let accessKey: String }   // base64
struct RestoreBackupResponse: Decodable {
    let ciphertext: String
    let salt: String
    let kdf: KdfParams
}

// ---- Поиск / карточка / устройства ----

struct UserLookupResponse: Decodable {     // GET /users/by-username/:username
    let userId: String
    let username: String
}

struct UserCardResponse: Decodable {       // GET /users/:userId
    let userId: String
    let username: String
    let encryptedProfile: String?          // base64; расшифровать можно только Profile Key владельца
    let avatars: [AvatarItem]
}

struct MediaUploadResponse: Decodable { let attachmentId: String }   // POST /media
struct MediaUrlResponse: Decodable { let url: String }               // GET /media/:id/url

struct UserDevicesResponse: Decodable {    // GET /users/:userId/devices
    let devices: [RecipientDevice]
}
struct RecipientDevice: Decodable {
    let deviceId: String                   // uuid (== senderDeviceId/recipientDeviceId)
    let protocolDeviceId: Int
    let registrationId: Int
}

// ---- Беседы ----

struct CreateConversationRequest: Encodable { let recipientUserId: String }
struct CreateConversationResponse: Decodable { let conversationId: String }

struct ConversationsResponse: Decodable { let conversations: [ConversationItem] }
struct ConversationItem: Decodable {
    let conversationId: String
    let otherUser: OtherUser?
    let lastMessageAt: String?
}
struct OtherUser: Decodable { let userId: String; let username: String }

// ---- Сообщения ----

struct SendMessageRequest: Encodable {
    let recipientUserId: String?
    let conversationId: String?
    let deliveries: [DeliveryInput]
    var silent: Bool? = nil                 // true → сервер не пушит/не бейджит (для квитанций); nil → не шлём поле
    var ephemeral: Bool? = nil              // true → сервер не двигает беседу (lastMessageAt) — для typing
    // Ключ идемпотентности — localId сообщения. Повтор с тем же значением вернёт уже созданное
    // сообщение вместо второго, поэтому автоповторы очереди безопасны. Шлём только там, где повтор
    // реально бывает (текст и медиа); у квитанций и typing повторов нет и поле не нужно.
    var clientMessageId: String? = nil
}
struct DeliveryInput: Encodable {
    let recipientDeviceId: String
    let envelopeType: Int
    let ciphertext: String                 // base64
}
struct SendMessageResponse: Decodable {
    let messageId: String
    let conversationId: String
    let createdAt: String
}

struct MessagesSyncResponse: Decodable { let deliveries: [IncomingDelivery] }
struct IncomingDelivery: Decodable {
    let deliveryId: String
    let messageId: String
    let conversationId: String
    let senderUserId: String
    let senderDeviceId: String             // uuid отправителя → резолвим в protocolDeviceId
    let envelopeType: Int
    let ciphertext: String                 // base64
    let createdAt: String
}

// Время сообщения в ленте — СЕРВЕРНОЕ (как в Telegram), а не `sentAt` из payload: тот ставят часы
// отправителя, и человек с переведённым вперёд временем присылал сообщения «из послезавтра» — они
// вставали в конец ленты под чужой датой. Серверное время от часов телефонов не зависит.
// nil — сервер прислал что-то нераспознаваемое; тогда вызывающий берёт прежнее значение.
enum ServerTime {
    nonisolated(unsafe) private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    // ISO-строка сервера → миллисекунды (единицы `LocalMessage.sentAt`)
    nonisolated static func ms(_ iso: String) -> Int64? {
        guard let date = withFraction.date(from: iso) ?? plain.date(from: iso) else { return nil }
        return Int64(date.timeIntervalSince1970 * 1000)
    }
}

extension IncomingDelivery {
    nonisolated var serverTimeMs: Int64? { ServerTime.ms(createdAt) }
}

extension SendMessageResponse {
    nonisolated var serverTimeMs: Int64? { ServerTime.ms(createdAt) }
}

// GET /announcements/current — объявление администратора (баннер вверху списка чатов)
struct AnnouncementResponse: Decodable { let announcement: Announcement? }
struct Announcement: Decodable, Equatable {
    let id: String
    let name: String
    let text: String          // ссылки — разметкой [текст](https://…)
    let expiresAt: String     // ISO; даты в проекте — строки
}

struct AckRequest: Encodable { let deliveryIds: [String] }
struct AckResponse: Decodable { let acked: Int }
struct DeletedResponse: Decodable { let deleted: Bool }   // DELETE /conversations/:id

// GET /messages/statuses → агрегированный delivered моих отправленных сообщений
struct StatusesResponse: Decodable { let statuses: [DeliveredStatus] }
struct DeliveredStatus: Decodable { let messageId: String; let deliveredAt: String? }

// ---- Payload сообщения (внутри шифртекста; сервер не видит) ----

struct MessagePayload: Codable {
    var v: Int = 1
    var type: String                       // "text" | "profileKey" | "receipt" | "call" | "callLog"
    var sentAt: Int64
    var text: String?
    var profileKey: String?                // base64 32 байта — Profile Key ОТПРАВИТЕЛЯ (раздел 9 бэка)
    var receipt: Receipt?                   // для type:"receipt"
    var call: CallSignal?                   // для type:"call" — offer/answer/ICE WebRTC
    var callLog: CallLog?                   // для type:"callLog" — итог звонка (запись в чат)
    var typing: TypingSignal?               // для type:"typing" — «печатает…» (E2EE, эфемерное)
    var reply: ReplyRef?                    // для type:"text" — ответ на конкретное сообщение (цитата)
    var edit: EditRef?                      // для type:"edit" — редактирование своего сообщения
    var delete: DeleteRef?                  // для type:"delete" — полное удаление у всех
    var reaction: ReactionRef?              // для type:"reaction" — эмодзи-реакция на сообщение
    var forward: ForwardRef?                // для type:"text" — пересланное сообщение (подпись «Переслано»)
    var block: BlockSignal?                 // для type:"block" — синк блок-листа на СВОИ устройства
    var retry: RetryRequest?                // для type:"retryRequest" — «не смог расшифровать, начни сессию заново»
    var media: MediaRef?                    // для type:"media" — одиночное фото/видео
    var mediaGroup: [MediaRef]?             // для type:"media" — альбом (несколько файлов одним сообщением)
}

// type:"media" — фото или видео. Сам файл лежит на сервере ЗАШИФРОВАННЫМ отдельным блобом,
// а здесь — всё, что нужно для его получения и проверки. Ключ едет внутри шифртекста, поэтому
// сервер, держащий блоб, расшифровать его не может: гарантия ровно та же, что у текста.
//
// thumb — крошечный JPEG прямо в payload. Благодаря ему бабл рисуется сразу после расшифровки
// сообщения, ДО скачивания файла: превью видно даже при выключенной автозагрузке, в офлайне и
// после того, как серверный TTL истёк и оригинал утрачен.
struct MediaRef: Codable {
    var attachmentId: String
    var key: String                         // base64, AES-GCM 256, одноразовый на этот файл
    var sha256: String                      // base64, проверяется ДО отдачи в UI
    var mime: String                        // "image/jpeg" | "video/mp4"
    var width: Int
    var height: Int
    var bytes: Int                          // размер оригинала — показываем до скачивания
    var durationMs: Int?                    // только видео
    var thumb: String?                      // base64 JPEG ~200px

    var isVideo: Bool { mime.hasPrefix("video/") }
    var fileExtension: String { isVideo ? "mp4" : "jpg" }

    // Локальная заготовка: бабл уже показан, но файл ещё готовится/заливается и серверного id нет.
    // Такой ref никогда не покидает устройство — в payload уходит только заполненный.
    var isPending: Bool { attachmentId.isEmpty }

    static func pending(mime: String, width: Int, height: Int, thumb: String?) -> MediaRef {
        MediaRef(attachmentId: "", key: "", sha256: "", mime: mime,
                 width: width, height: height, bytes: 0, durationMs: nil, thumb: thumb)
    }

    // Локально альбом и одиночное медиа хранятся ОДИНАКОВО — массивом в LocalMessage.text.
    // Декодирование терпимо к обеим формам: строки, записанные до появления альбомов, содержат
    // одиночный объект, и без этого фолбэка они перестали бы открываться.
    static func decodeList(_ json: String) -> [MediaRef] {
        guard let data = json.data(using: .utf8) else { return [] }
        if let list = try? JSONDecoder().decode([MediaRef].self, from: data) { return list }
        if let one = try? JSONDecoder().decode(MediaRef.self, from: data) { return [one] }

        return []
    }

    static func encodeList(_ refs: [MediaRef]) -> String {
        (try? JSONEncoder().encode(refs)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}

// type:"retryRequest" — аналог DecryptionErrorMessage (retry receipt) у Signal.
// Получатель, не сумевший расшифровать конверт, говорит об этом ОТПРАВИТЕЛЮ. Обе стороны выбрасывают
// сломанную сессию, отправитель переотправляет содержимое через новую. Без этого рассинхрон сессии
// не лечится ничем: сколько ни повторяй расшифровку, результат один и тот же.
// Едет silent + ephemeral: ни пуша, ни строки в чате, ни движения списка бесед.
struct RetryRequest: Codable {
    var messageId: String                   // серверный id конверта, который не расшифровался
}

// type:"block" — синк локального блок-листа между СВОИМИ устройствами (сервер смысла не видит).
struct BlockSignal: Codable {
    var userId: String
    var username: String?
    var blocked: Bool                       // true — заблокировать, false — разблокировать
}

// Пересылка (Telegram-style, с атрибуцией автора). Осознанное отступление от Signal (он пересылает
// без пометки): authorUserId третьей стороны виден ТОЛЬКО получателю (внутри шифртекста), не серверу.
// При пересылке пересланного атрибуция сохраняется исходная.
struct ForwardRef: Codable {
    var authorUserId: String                // автор ОРИГИНАЛА
}

// Редактирование (type:"edit") — внутри шифртекста, как editMessage у Signal: сервер не знает,
// что сообщение правилось. Применяется ТОЛЬКО если отправитель edit == автор оригинала
// и правка уложилась в окно 48 часов (проверяется и на приёмнике).
struct EditRef: Codable {
    var targetMessageId: String             // серверный id редактируемого сообщения
    var text: String                        // новый текст целиком
}

// Полное удаление у всех (type:"delete") — как remoteDelete у Signal: строка удаляется физически,
// без tombstone/подписи («как будто не было»). Применяется ТОЛЬКО если отправитель == автор.
struct DeleteRef: Codable {
    var targetMessageId: String             // серверный id удаляемого сообщения
}

// type:"reaction" — реакция на сообщение (Signal-style: внутри шифртекста, сервер не знает ни кто
// отреагировал, ни на что). У человека одна реакция на сообщение: новая заменяет прежнюю.
// emoji == nil — реакцию сняли. Едет silent + ephemeral: без пуша и без поднятия беседы в списке.
struct ReactionRef: Codable {
    var targetMessageId: String             // серверный id сообщения, на которое реагируют
    var emoji: String?                      // nil — снять свою реакцию
}

// Цитата (реплай) — внутри шифртекста, как quote у Signal: сервер о реплаях не знает.
// Несём СНАПШОТ текста, а не только ссылку: цитата рендерится даже там, где оригинала нет
// (устройство без этого куска истории), и не меняется задним числом.
struct ReplyRef: Codable {
    var messageId: String                   // серверный id цитируемого сообщения
    var authorUserId: String                // автор цитируемого
    var text: String                        // снапшот текста (обрезан при отправке)
}

// type:"typing" — статус набора текста. Едет E2EE silent+ephemeral, в чат не пишется.
struct TypingSignal: Codable {
    var state: String                       // "start" | "stop"
}

struct Receipt: Codable {
    var upToMessageId: String
    var state: String                       // "read"
    var at: Int64
}

// Итог звонка внутри E2EE-сообщения type:"callLog" — запись «был звонок» в чате (как в Signal/Telegram).
// Пишет ТОЛЬКО звонивший (одна каноническая запись на звонок, обе стороны рендерят её со своей точки
// зрения через isMine). Сервер не отличает от текста; та же строка хранится JSON'ом в message.text
// (kind == "call") в локальной БД.
struct CallLog: Codable {
    var callId: String
    var media: String                       // "audio" | "video"
    var outcome: String                     // "answered" | "unanswered" | "declined"
    var durationSec: Int?                   // для answered — длительность от ICE-коннекта

    var isVideo: Bool { media == "video" }

    // подпись записи с точки зрения смотрящего (isMine == «я звонил»)
    // Каждая комбинация — отдельная фраза целиком, без склейки «прилагательное + существительное».
    // Склейка ломается при переводе: род и порядок слов в языках разные, и подставлять существительное
    // в готовое предложение можно только там, где грамматика это позволяет.
    func displayText(isMine: Bool) -> String {
        if isMine {
            switch outcome {
            case "answered": return isVideo ? L("Исходящий видеозвонок") : L("Исходящий звонок")
            case "declined": return isVideo ? L("Видеозвонок отклонён") : L("Звонок отклонён")
            default:         return isVideo ? L("Неотвеченный видеозвонок") : L("Неотвеченный звонок")
            }
        } else {
            switch outcome {
            case "answered": return isVideo ? L("Входящий видеозвонок") : L("Входящий звонок")
            case "declined": return isVideo ? L("Отклонённый видеозвонок") : L("Отклонённый звонок")
            default:         return isVideo ? L("Пропущенный видеозвонок") : L("Пропущенный звонок")
            }
        }
    }

    static func formatDuration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// Сигналинг звонка внутри E2EE-сообщения type:"call" (offer/answer/ICE). Сервер не отличает от текста.
struct CallSignal: Codable {
    var callId: String
    var kind: String                        // "offer" | "answer" | "ice"
    var sdp: String?                        // для offer/answer
    var candidate: String?                  // для ice
    var sdpMid: String?
    var sdpMLineIndex: Int32?
}

// GET /calls/ice-servers → { iceServers: [...] }
struct IceServersResponse: Decodable { let iceServers: [IceServerDTO] }
struct IceServerDTO: Decodable {
    let urls: [String]
    let username: String?
    let credential: String?
}

// ---- Rings (валюта) + Ringback (кастомный гудок) — docs/ringback-rings.md ----

// GET /rings — баланс + конфиг экономики + состояние услуги (цены НЕ хардкодим — берём отсюда)
struct RingsStatus: Decodable {
    let balance: Int
    let adReward: Int
    let adDailyLimit: Int
    let adsWatchedToday: Int
    let prices: RingbackPrices
    let ringback: RingbackState?          // null, если услуга ни разу не покупалась
}
struct RingbackPrices: Decodable {
    let d7: Int, d30: Int, d90: Int
    enum CodingKeys: String, CodingKey { case d7 = "7d", d30 = "30d", d90 = "90d" }
}
struct RingbackState: Decodable {
    let expiresAt: String?                 // ISO8601 (даты в проекте — строки, парсим в UI)
    let active: Bool
    let attachmentId: String?
}

// POST /ringback/purchase
struct PurchaseRingbackRequest: Encodable { let plan: String }   // "7d" | "30d" | "90d"
struct PurchaseRingbackResponse: Decodable {
    let balance: Int
    let expiresAt: String?
}

// POST /ringback/audio
struct RingbackAudioResponse: Decodable { let attachmentId: String }
