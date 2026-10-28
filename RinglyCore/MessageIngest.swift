import Foundation

// Результат обработки входящей доставки (для баннера NSE / диагностики приложения).
struct IngestedMessage {
    let senderUserId: String
    let conversationId: String
    let text: String?          // текст сообщения (nil для служебных, напр. квитанций)
    let isReceipt: Bool        // read-квитанция (показывать в баннере нечего)
    let gotProfileKey: Bool    // пришёл Profile Key отправителя (UI может обновить имя/аватар)
    var senderDeviceId: String? = nil   // uuid устройства отправителя (для адресации ответа звонка)
    var callSignal: CallSignal? = nil    // type:"call" — offer/answer/ICE для CallManager
    var typingState: String? = nil       // type:"typing" — "start"/"stop" (для TypingStore)
    var typingSentAt: Int64? = nil       // sentAt typing-сигнала — для отсева протухших (доставлен поздно)
    var blockChanged: Bool = false       // type:"block" — синк блок-листа применён (UI: обновить BlockState)
    var conversationDeleted: Bool = false // type:"deleteConversation" — беседа стёрта локально (UI: обновить список)
}

// Единый конвейер приёма для приложения И для NSE. Гарантирует Signal-style инвариант:
// каждая доставка расшифровывается РОВНО один раз (дедуп через processed_delivery + межпроцессный lock),
// поэтому два процесса не ломают ратчет.
enum MessageIngest {
    private static let lock = CrossProcessLock(name: "ingest.lock")

    // Счётчик неудачных расшифровок. Живёт в памяти процесса намеренно: перезапуск приложения
    // (или новый запуск NSE) — как раз тот момент, когда сессия могла восстановиться, и попытку
    // разумно повторить. Персистить счётчик значило бы хоронить конверт навсегда.
    // Отправка retry receipt. Хук, а не прямой вызов: MessageIngest общий с NSE, а расширению нельзя
    // затевать сетевую работу — у него секунды на баннер. Ставит его основное приложение (AppViewModel);
    // в NSE остаётся nil, и запрос уйдёт, когда приложение разберёт ту же очередь.
    nonisolated(unsafe) public static var requestRetry: ((_ senderUserId: String, _ senderDeviceId: String,
                                                          _ messageId: String, _ conversationId: String) async -> Void)?

    // Реакция на ЧУЖОЙ retry receipt (мы — отправитель): сбросить сессию и переотправить. Тоже хук,
    // по той же причине: NSE не должен ничего переотправлять.
    nonisolated(unsafe) public static var handleRetry: ((_ req: RetryRequest, _ fromUserId: String,
                                                         _ fromDeviceId: String, _ conversationId: String) async -> Void)?

    private static let maxDecryptAttempts = 5
    private static let failuresLock = NSLock()
    nonisolated(unsafe) private static var decryptFailures: [String: Int] = [:]

    private static func bumpFailure(_ deliveryId: String) -> Int {
        failuresLock.lock()
        defer { failuresLock.unlock() }
        let n = (decryptFailures[deliveryId] ?? 0) + 1
        decryptFailures[deliveryId] = n

        return n
    }

    // duplicate = конверт уже потреблён ратчетом. libsignal не даёт стабильного типа в публичном
    // API Swift-обёртки, поэтому опознаём по тексту — как и остальной матчинг ошибок в проекте.
    private static func isDuplicate(_ error: Error) -> Bool {
        let text = String(describing: error).lowercased()

        return text.contains("duplicate")
    }

    // Обработать одну доставку. Возвращает:
    //  - .processed(IngestedMessage?) — успешно (или уже было обработано/служебное); доставку можно ack-ать;
    //  - .retry — временная ошибка (не резолвится устройство и т.п.), НЕ ack-аем, попробуем позже.
    enum Result { case processed(IngestedMessage?); case retry }

    static func process(_ d: IncomingDelivery) async -> Result {
        // дешёвая проверка до взятия лока: уже обработано другим процессом
        if ChatStore.isProcessed(deliveryId: d.deliveryId) { return .processed(nil) }

        guard let pid = await DeviceResolver.shared.protocolDeviceId(userId: d.senderUserId,
                                                                     deviceId: d.senderDeviceId) else {
            return .retry   // не смогли резолвить устройство отправителя — не помечаем, попробуем позже
        }

        return await lock.withLock {
            // двойная проверка под локом: пока ждали lock, другой процесс мог уже обработать
            if ChatStore.isProcessed(deliveryId: d.deliveryId) { return .processed(nil) }

            do {
                let plain = try await SignalSession.shared.decrypt(
                    envelopeType: d.envelopeType, ciphertextBase64: d.ciphertext,
                    userId: d.senderUserId, protocolDeviceId: pid)
                let payload = try JSONDecoder().decode(MessagePayload.self, from: plain)

                // собеседник не смог расшифровать наше сообщение → чиним сессию и переотправляем.
                // Обрабатывает только приложение (в NSE хук не выставлен) — сетевая работа там неуместна.
                if payload.type == "retryRequest", let r = payload.retry {
                    ChatStore.markProcessed(deliveryId: d.deliveryId)
                    await Self.handleRetry?(r, d.senderUserId, d.senderDeviceId, d.conversationId)

                    return .processed(nil)
                }

                // синк блок-листа с МОЕГО другого устройства → применяем локально, в чат не пишем
                if payload.type == "block", let b = payload.block {
                    BlockStore.setBlocked(b.userId, username: b.username, blocked: b.blocked)
                    ChatStore.markProcessed(deliveryId: d.deliveryId)
                    return .processed(IngestedMessage(senderUserId: d.senderUserId, conversationId: d.conversationId,
                                                      text: nil, isReceipt: false, gotProfileKey: false, blockChanged: true))
                }

                // «Удалить контакт» с другого устройства/от собеседника → стираем локальную историю беседы
                if payload.type == "deleteConversation" {
                    ChatStore.deleteConversation(d.conversationId)
                    ChatStore.markProcessed(deliveryId: d.deliveryId)
                    return .processed(IngestedMessage(senderUserId: d.senderUserId, conversationId: d.conversationId,
                                                      text: nil, isReceipt: false, gotProfileKey: false, conversationDeleted: true))
                }

                // сообщение от ЗАБЛОКИРОВАННОГО — молча отбрасываем (не пишем в чат, не уведомляем).
                // Расшифровали уже (ратчет консистентен), просто не сохраняем. Как в Signal — отправитель
                // о блоке не узнаёт. (Свой type:"block" сюда не попадёт: себя не блокируем.)
                if BlockStore.isBlocked(d.senderUserId) {
                    ChatStore.markProcessed(deliveryId: d.deliveryId)
                    return .processed(nil)
                }

                var gotKey = false
                if let pk = payload.profileKey {                  // Profile Key отправителя — в каждом сообщении
                    ContactKeyStore.save(userId: d.senderUserId, profileKeyBase64: pk)
                    gotKey = true
                }

                switch payload.type {
                case "receipt":
                    if let r = payload.receipt, r.state == "read" {
                        ChatStore.markReadUpTo(conversationId: d.conversationId, upToServerMessageId: r.upToMessageId)
                    }
                    ChatStore.markProcessed(deliveryId: d.deliveryId)
                    return .processed(IngestedMessage(senderUserId: d.senderUserId, conversationId: d.conversationId,
                                                      text: nil, isReceipt: true, gotProfileKey: gotKey))
                case "call":
                    // сигналинг звонка (offer/answer/ICE) — в чат не пишем, отдаём CallManager'у в приложении
                    ChatStore.markProcessed(deliveryId: d.deliveryId)
                    return .processed(IngestedMessage(senderUserId: d.senderUserId, conversationId: d.conversationId,
                                                      text: nil, isReceipt: false, gotProfileKey: gotKey,
                                                      senderDeviceId: d.senderDeviceId, callSignal: payload.call))
                case "typing":
                    // «печатает…» — в чат не пишем, отдаём TypingStore в приложении (staleness проверит он)
                    ChatStore.markProcessed(deliveryId: d.deliveryId)
                    return .processed(IngestedMessage(senderUserId: d.senderUserId, conversationId: d.conversationId,
                                                      text: nil, isReceipt: false, gotProfileKey: gotKey,
                                                      typingState: payload.typing?.state, typingSentAt: payload.sentAt))
                case "media":
                    // Фото/видео. Сам файл НЕ качаем здесь: конвейер общий с NSE, а расширению нельзя
                    // тянуть мегабайты — у него секунды на баннер. В историю кладём MediaRef (там же
                    // миниатюра), поэтому бабл с превью отрисуется сразу; оригинал подтянет UI.
                    // одиночное приходит в `media`, альбом — в `mediaGroup`; локально храним одинаково
                    let refs = payload.mediaGroup ?? payload.media.map { [$0] } ?? []
                    guard let ref = refs.first else {
                        ChatStore.markProcessed(deliveryId: d.deliveryId)

                        return .processed(nil)
                    }
                    let mineMedia = d.senderUserId == AuthState.myUserId
                    let refJson = MediaRef.encodeList(refs)
                    // подпись едет в обычном `text` того же payload — отдельного поля не нужно
                    let caption = payload.text?.isEmpty == false ? payload.text : nil
                    ChatStore.persistIncoming(LocalMessage(
                        id: d.messageId, conversationId: d.conversationId, senderUserId: d.senderUserId,
                        isMine: mineMedia, text: refJson, sentAt: d.serverTimeMs ?? payload.sentAt,
                        status: mineMedia ? .sent : .read, serverMessageId: d.messageId,
                        kind: "media",
                        // цитата и «переслано» работают для медиа так же, как для текста:
                        // поля лежат в том же payload, отдельного формата не потребовалось
                        replyToId: payload.reply?.messageId,
                        replyAuthorUserId: payload.reply?.authorUserId,
                        replyText: payload.reply?.text,
                        forwardFromUserId: payload.forward?.authorUserId,
                        caption: caption), deliveryId: d.deliveryId)

                    // текст баннера NSE: подпись информативнее типа файла (как в Telegram),
                    // для альбома без подписи называем количество, а не тип первого файла
                    let banner = caption
                        ?? (refs.count > 1 ? Plural.files(refs.count) : (ref.isVideo ? L("Видео") : L("Фото")))

                    return .processed(IngestedMessage(
                        senderUserId: d.senderUserId, conversationId: d.conversationId,
                        text: mineMedia ? nil : banner,
                        isReceipt: false, gotProfileKey: gotKey))
                case "text":
                    let mine = d.senderUserId == AuthState.myUserId
                    let msg = LocalMessage(
                        id: d.messageId, conversationId: d.conversationId, senderUserId: d.senderUserId,
                        isMine: mine, text: payload.text ?? "", sentAt: d.serverTimeMs ?? payload.sentAt,
                        status: mine ? .sent : .read, serverMessageId: d.messageId,
                        replyToId: payload.reply?.messageId,
                        replyAuthorUserId: payload.reply?.authorUserId,
                        replyText: payload.reply?.text,
                        forwardFromUserId: payload.forward?.authorUserId)
                    ChatStore.persistIncoming(msg, deliveryId: d.deliveryId)   // вставка + маркер в одной транзакции
                    return .processed(IngestedMessage(senderUserId: d.senderUserId, conversationId: d.conversationId,
                                                      text: payload.text, isReceipt: false, gotProfileKey: gotKey))
                case "edit":
                    // редактирование: применяем к оригиналу; ChatStore.applyEdit сверяет автора
                    // (чужие сообщения править нельзя). Оригинал не найден → правка теряется (MVP).
                    // Окно 48 ч сверяется по серверному времени правки и оригинала — переводом часов не обойти.
                    if let e = payload.edit {
                        ChatStore.applyEdit(targetId: e.targetMessageId, newText: e.text,
                                            editedAt: d.serverTimeMs ?? payload.sentAt, authorUserId: d.senderUserId)
                    }
                    ChatStore.markProcessed(deliveryId: d.deliveryId)
                    return .processed(IngestedMessage(senderUserId: d.senderUserId, conversationId: d.conversationId,
                                                      text: nil, isReceipt: false, gotProfileKey: gotKey))
                case "delete":
                    // полное удаление у всех: физически стираем строку (без tombstone);
                    // ChatStore.applyDelete сверяет автора — чужое сообщение удалить нельзя
                    if let del = payload.delete {
                        ChatStore.applyDelete(targetId: del.targetMessageId, authorUserId: d.senderUserId)
                    }
                    ChatStore.markProcessed(deliveryId: d.deliveryId)
                    return .processed(IngestedMessage(senderUserId: d.senderUserId, conversationId: d.conversationId,
                                                      text: nil, isReceipt: false, gotProfileKey: gotKey))
                case "reaction":
                    // реакция: тихо применяем к сообщению (баннера нет — решение: без пуша);
                    // ChatStore.applyReaction сверяет беседу и отбрасывает опоздавшие обновления
                    if let r = payload.reaction {
                        ChatStore.applyReaction(targetId: r.targetMessageId, conversationId: d.conversationId,
                                                userId: d.senderUserId, emoji: r.emoji, at: payload.sentAt)
                    }
                    ChatStore.markProcessed(deliveryId: d.deliveryId)
                    return .processed(IngestedMessage(senderUserId: d.senderUserId, conversationId: d.conversationId,
                                                      text: nil, isReceipt: false, gotProfileKey: gotKey))
                case "callLog":
                    // итог звонка от звонившего → запись «был звонок» в истории чата (kind: "call").
                    // isMine == true — это синк на моё другое устройство (я звонил с другого девайса).
                    guard let log = payload.callLog else {
                        ChatStore.markProcessed(deliveryId: d.deliveryId)
                        return .processed(nil)
                    }
                    let mine = d.senderUserId == AuthState.myUserId
                    let json = (try? JSONEncoder().encode(log)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    let msg = LocalMessage(
                        id: d.messageId, conversationId: d.conversationId, senderUserId: d.senderUserId,
                        isMine: mine, text: json, sentAt: d.serverTimeMs ?? payload.sentAt,
                        status: mine ? .sent : .read, serverMessageId: d.messageId, kind: "call")
                    ChatStore.persistIncoming(msg, deliveryId: d.deliveryId)
                    // text для баннера NSE: «Пропущенный звонок» и т.п.; для своих (синк) баннер не нужен
                    return .processed(IngestedMessage(senderUserId: d.senderUserId, conversationId: d.conversationId,
                                                      text: mine ? nil : log.displayText(isMine: false),
                                                      isReceipt: false, gotProfileKey: gotKey))
                default:
                    ChatStore.markProcessed(deliveryId: d.deliveryId)
                    return .processed(IngestedMessage(senderUserId: d.senderUserId, conversationId: d.conversationId,
                                                      text: nil, isReceipt: false, gotProfileKey: gotKey))
                }
            } catch {
                print("MessageIngest decrypt error (\(d.senderUserId), type=\(d.envelopeType)):", error)

                // Раньше ЛЮБАЯ ошибка вела к markProcessed + ack. Для duplicate это верно, но для
                // «не расшифровалось» — это потеря данных с ложным подтверждением: ack означает
                // «доставлено», сервер удаляет конверт, переспросить нечего, а ОТПРАВИТЕЛЬ видит две
                // галочки. Именно так сообщения молча исчезали при рассогласовании ключей.
                //
                // duplicate — единственный случай, когда ack корректен: message key уже потреблён
                // ратчетом, повторная попытка не даст ничего и только продлит зацикливание.
                if Self.isDuplicate(error) {
                    ChatStore.markProcessed(deliveryId: d.deliveryId)

                    return .processed(nil)
                }

                // Сессия рассинхронизировалась — повторять расшифровку бессмысленно, результат будет
                // тот же. Единственный способ починить — заменить сессию, поэтому выбрасываем свою
                // половину и просим отправителя сделать то же самое и переотправить (retry receipt).
                // Один запрос на конверт: иначе получилась бы лавина при разборе очереди.
                let attempt = Self.bumpFailure(d.deliveryId)
                if attempt == 1 {
                    try? await SignalSession.shared.resetSession(userId: d.senderUserId, protocolDeviceId: pid)
                    await Self.requestRetry?(d.senderUserId, d.senderDeviceId, d.messageId, d.conversationId)
                }

                // не ack-аем: конверт остаётся на сервере, вдруг переотправка/новая сессия его вытянут
                if attempt < Self.maxDecryptAttempts {
                    return .retry
                }

                print("⚠️ доставка \(d.deliveryId) сдаётся после \(Self.maxDecryptAttempts) попыток расшифровки")
                ChatStore.markProcessed(deliveryId: d.deliveryId)

                return .processed(nil)
            }
        }
    }
}
