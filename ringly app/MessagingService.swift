import Foundation
import CryptoKit
import Combine

// Видимая на экране диагностика (баннер в ChatView). Временно, для отладки.
@MainActor
final class MessagingDebug: ObservableObject {
    static let shared = MessagingDebug()
    @Published var last: String?
}

// гейт single-flight: один sync за раз + один «догоняющий» проход, если просили во время работы
actor SyncGate {
    private var running = false
    private var again = false
    func begin() -> Bool {
        if running { again = true; return false }
        running = true
        return true
    }
    func endAndRepeat() -> Bool {
        if again { again = false; return true }
        running = false
        return false
    }
}

final class MessagingService {

    private let gate = SyncGate()

    // ===== ОТПРАВКА =====
    // conversationId опционален: при первом сообщении из поиска его ещё нет — шлём recipientUserId.
    // replyTo — цитата (реплай): едет внутри шифртекста (Signal-style quote), сервер о ней не знает.
    // Возвращает conversationId (с сервера) — экран чата его запоминает.
    @discardableResult
    func sendText(_ text: String, recipientUserId: String, conversationId: String?,
                  replyTo: ReplyRef? = nil, forwardFrom: String? = nil) async throws -> String {
        let myUserId = AuthState.myUserId ?? ""
        let localId = UUID().uuidString
        let sentAt = Int64(Date().timeIntervalSince1970 * 1000)

        // оптимистично показываем своё сообщение сразу (status: sending) — если беседа уже известна
        if let cid = conversationId {
            ChatStore.add(LocalMessage(id: localId, conversationId: cid, senderUserId: myUserId,
                                       isMine: true, text: text, sentAt: sentAt, status: .sending, serverMessageId: nil,
                                       replyToId: replyTo?.messageId,
                                       replyAuthorUserId: replyTo?.authorUserId,
                                       replyText: replyTo?.text,
                                       forwardFromUserId: forwardFrom))
        }

        var payload = MessagePayload(type: "text", sentAt: sentAt, text: text)
        payload.reply = replyTo
        payload.forward = forwardFrom.map { ForwardRef(authorUserId: $0) }
        if let myKey = ProfileKeyStore.shared.rawKey() {   // Profile Key — в каждом сообщении (надёжно)
            payload.profileKey = myKey.base64EncodedString()
        }
        let plaintext = try JSONEncoder().encode(payload)

        // Беседа известна → в очередь, дальше ведёт OutboxWorker. Возврат мгновенный и без ошибки:
        // сообщение уже сохранено и будет дослано, даже если сети сейчас нет совсем.
        if let cid = conversationId {
            OutboxStore.enqueue(localId: localId, conversationId: cid,
                                recipientUserId: recipientUserId, plaintext: plaintext)
            OutboxWorker.shared.kick()

            return cid
        }

        // Беседы ещё нет (первое сообщение из поиска): её создаёт сервер в ответ на ЭТОТ запрос,
        // а вызывающему conversationId нужен немедленно — очередь тут не помогает. Единственный
        // путь, оставшийся одноразовой попыткой.
        do {
            let res = try await deliver(plaintext: plaintext, recipientUserId: recipientUserId,
                                        conversationId: nil, silent: false)

            // беседы не было до ответа → вставляем уже с серверным id
            ChatStore.add(LocalMessage(id: localId, conversationId: res.conversationId, senderUserId: myUserId,
                                       isMine: true, text: text, sentAt: res.serverTimeMs ?? sentAt, status: .sent, serverMessageId: res.messageId,
                                       replyToId: replyTo?.messageId,
                                       replyAuthorUserId: replyTo?.authorUserId,
                                       replyText: replyTo?.text,
                                       forwardFromUserId: forwardFrom))
            return res.conversationId
        } catch {
            // Логируем ОБЯЗАТЕЛЬНО: без этой строки «не отправлено» — единственный симптом, а причина
            // (409 со списком несошедшихся устройств, провал шифрования, сеть) не видна нигде.
            // Разбор такого молчания однажды занял несколько заходов вместо одного взгляда в консоль.
            print("✉️ отправка не удалась:", error)
            // Строки в ленте тут ещё нет (беседа неизвестна — вставляем её только по ответу),
            // поэтому помечать нечего. Ошибку показывает вызывающий экран.
            throw error
        }
    }

    // Отправка медиа. Файл уже подготовлен (сжат/перекодирован) и залит ЗАШИФРОВАННЫМ до вызова;
    // здесь только обычное сообщение, у которого вместо текста — MediaRef с ключом и миниатюрой.
    //
    // localId передаётся снаружи: бабл с превью и крутилкой ставится в ленту СРАЗУ после выбора файла
    // (телеграм-стиль), ещё до обработки и заливки. Здесь мы лишь дописываем в него настоящий ref.
    @discardableResult
    func sendMedia(_ refs: [MediaRef], caption: String? = nil, recipientUserId: String,
                   conversationId: String?, localId: String,
                   replyTo: ReplyRef? = nil, forwardFrom: String? = nil) async throws -> String {
        let myUserId = AuthState.myUserId ?? ""
        let sentAt = Int64(Date().timeIntervalSince1970 * 1000)
        let json = MediaRef.encodeList(refs)

        // заготовка уже в ленте — подменяем payload на настоящий (id/ключ/размер)
        if conversationId != nil { ChatStore.updateMediaPayload(localId: localId, json: json) }

        var payload = MessagePayload(type: "media", sentAt: sentAt)
        // подпись — в обычном `text`: сервер и так видит только шифртекст, а получателю
        // не нужно отдельное поле, чтобы отличить подпись от текста сообщения
        payload.text = caption
        payload.reply = replyTo
        payload.forward = forwardFrom.map { ForwardRef(authorUserId: $0) }
        // Одиночное шлём в `media`, альбом — в `mediaGroup`. Дублировать первый элемент в оба
        // поля нельзя: миниатюра весит килобайты, и в альбоме из десяти файлов это заметно
        // раздуло бы payload, который идёт через очередь доставки.
        if refs.count == 1 { payload.media = refs[0] } else { payload.mediaGroup = refs }
        if let myKey = ProfileKeyStore.shared.rawKey() {
            payload.profileKey = myKey.base64EncodedString()
        }
        let plaintext = try JSONEncoder().encode(payload)

        // Файл уже залит — осталось доставить само сообщение, и вот это как раз имеет смысл
        // повторять: обидно потерять отправку после успешной заливки видео.
        if let cid = conversationId {
            OutboxStore.enqueue(localId: localId, conversationId: cid,
                                recipientUserId: recipientUserId, plaintext: plaintext)
            OutboxWorker.shared.kick()

            return cid
        }

        do {
            let res = try await deliver(plaintext: plaintext, recipientUserId: recipientUserId,
                                        conversationId: nil, silent: false)

            ChatStore.add(LocalMessage(id: localId, conversationId: res.conversationId, senderUserId: myUserId,
                                       isMine: true, text: json, sentAt: res.serverTimeMs ?? sentAt, status: .sent,
                                       serverMessageId: res.messageId, kind: "media",
                                       replyToId: replyTo?.messageId,
                                       replyAuthorUserId: replyTo?.authorUserId,
                                       replyText: replyTo?.text,
                                       forwardFromUserId: forwardFrom,
                                       caption: caption))

            return res.conversationId
        } catch {
            print("✉️ отправка медиа не удалась:", error)
            throw error
        }
    }

    // read-квитанция «прочитано до upToMessageId» отправителю (E2EE, silent — без пуша/бейджа)
    func sendReadReceipt(conversationId: String, recipientUserId: String, upToMessageId: String) async {
        var payload = MessagePayload(type: "receipt", sentAt: Int64(Date().timeIntervalSince1970 * 1000))
        payload.receipt = Receipt(upToMessageId: upToMessageId, state: "read", at: payload.sentAt)
        do {
            let plaintext = try JSONEncoder().encode(payload)
            _ = try await deliver(plaintext: plaintext, recipientUserId: recipientUserId,
                                  conversationId: conversationId, silent: true)
        } catch {
            print("sendReadReceipt error:", error)
        }
    }

    // итог звонка → запись «был звонок» в чат обеих сторон (шлёт ТОЛЬКО звонивший, см. CallManager).
    // Обычный fan-out (все устройства обеих сторон получают запись в историю, как синк у Signal).
    // silent для answered/declined (обе стороны и так в курсе); unanswered — НЕ silent, чтобы офлайн-
    // абонент получил пуш и NSE показал «Пропущенный звонок».
    func sendCallLog(_ log: CallLog, recipientUserId: String, conversationId: String) async {
        let myUserId = AuthState.myUserId ?? ""
        var payload = MessagePayload(type: "callLog", sentAt: Int64(Date().timeIntervalSince1970 * 1000))
        payload.callLog = log
        if let myKey = ProfileKeyStore.shared.rawKey() {
            payload.profileKey = myKey.base64EncodedString()
        }
        do {
            let plaintext = try JSONEncoder().encode(payload)
            let silent = log.outcome != "unanswered"
            let res = try await deliver(plaintext: plaintext, recipientUserId: recipientUserId,
                                        conversationId: conversationId, silent: silent)
            // своя запись — сразу в локальную историю (text — JSON CallLog, как при приёме)
            let json = (try? JSONEncoder().encode(log)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            ChatStore.add(LocalMessage(id: UUID().uuidString, conversationId: res.conversationId,
                                       senderUserId: myUserId, isMine: true, text: json, sentAt: res.serverTimeMs ?? payload.sentAt,
                                       status: .sent, serverMessageId: res.messageId, kind: "call"))
        } catch {
            print("sendCallLog error:", error)   // best-effort: запись о звонке не критичнее самого звонка
        }
    }

    // сигналинг звонка (offer/answer/ICE) КОНКРЕТНОМУ устройству пира, E2EE, silent (без пуша/чата)
    //
    // ⚠️ Исход пишем в журнал звонка, а не в консоль. `CallManager.sendSignal` логирует «отправлен»
    // ДО сетевой работы, то есть доказывает только постановку в очередь; провал же уходил в обычный
    // print и в журнале не виден. Разбор «собеседник не узнал, что я положил трубку» на таком
    // журнале невозможен: непонятно, сигнал не ушёл или не дошёл.
    func sendCallSignal(_ signal: CallSignal, toUserId: String, toDeviceId: String, conversationId: String) async {
        guard let pid = await DeviceResolver.shared.protocolDeviceId(userId: toUserId, deviceId: toDeviceId) else {
            CallDiag.log("📤 сигнал \(signal.kind) ПРОВАЛ: не найдено устройство собеседника")
            return
        }
        do {
            var payload = MessagePayload(type: "call", sentAt: Int64(Date().timeIntervalSince1970 * 1000))
            payload.call = signal
            let plaintext = try JSONEncoder().encode(payload)
            try await SignalSession.shared.ensureSession(userId: toUserId, deviceId: toDeviceId, protocolDeviceId: pid)
            let (type, cipher) = try await SignalSession.shared.encrypt(plaintext, userId: toUserId, protocolDeviceId: pid)
            let body = SendMessageRequest(recipientUserId: nil, conversationId: conversationId,
                                          deliveries: [.init(recipientDeviceId: toDeviceId, envelopeType: type, ciphertext: cipher)],
                                          silent: true)
            let _: SendMessageResponse = try await APIClient.shared.request("messages", method: "POST", body: body)
            CallDiag.log("📤 сигнал \(signal.kind) доставлен серверу")
        } catch {
            CallDiag.log("📤 сигнал \(signal.kind) ПРОВАЛ: \(error.localizedDescription)")
        }
    }

    // ---- retry receipts (самовосстановление сессий) ----

    // Мы НЕ смогли расшифровать конверт → просим отправителя выбросить сессию и переотправить.
    // Адресуется КОНКРЕТНОМУ устройству, silent + ephemeral (без пуша, чата и движения списка бесед).
    func sendRetryRequest(toUserId: String, toDeviceId: String, messageId: String, conversationId: String) async {
        guard let pid = await DeviceResolver.shared.protocolDeviceId(userId: toUserId, deviceId: toDeviceId) else { return }
        do {
            var payload = MessagePayload(type: "retryRequest", sentAt: Int64(Date().timeIntervalSince1970 * 1000))
            payload.retry = RetryRequest(messageId: messageId)
            let plaintext = try JSONEncoder().encode(payload)
            // сессию с ним мы только что выбросили → ensureSession возьмёт свежий bundle
            try await SignalSession.shared.ensureSession(userId: toUserId, deviceId: toDeviceId, protocolDeviceId: pid)
            let (type, cipher) = try await SignalSession.shared.encrypt(plaintext, userId: toUserId, protocolDeviceId: pid)
            let body = SendMessageRequest(recipientUserId: nil, conversationId: conversationId,
                                          deliveries: [.init(recipientDeviceId: toDeviceId, envelopeType: type, ciphertext: cipher)],
                                          silent: true, ephemeral: true)
            let _: SendMessageResponse = try await APIClient.shared.request("messages", method: "POST", body: body)
            print("♻️ retry receipt отправлен для \(messageId.prefix(8)) → \(toDeviceId.prefix(8))")
        } catch {
            print("sendRetryRequest error:", error)
        }
    }

    // НАМ прислали retry receipt: собеседник не смог расшифровать наше сообщение.
    // Выбрасываем свою половину сессии и переотправляем содержимое через новую.
    // Guard от лавины: на один messageId отвечаем ровно один раз за запуск приложения — иначе две
    // стороны могли бы перекидываться запросами бесконечно, если проблема не в сессии.
    private static var retriedMessageIds = Set<String>()

    func handleRetryRequest(_ req: RetryRequest, fromUserId: String, fromDeviceId: String, conversationId: String) async {
        guard let pid = await DeviceResolver.shared.protocolDeviceId(userId: fromUserId, deviceId: fromDeviceId) else { return }
        try? await SignalSession.shared.resetSession(userId: fromUserId, protocolDeviceId: pid)

        let key = "\(req.messageId)|\(fromDeviceId)"
        guard !Self.retriedMessageIds.contains(key) else {
            print("♻️ retry для \(req.messageId.prefix(8)) уже выполнялся — только сброс сессии")
            return
        }
        Self.retriedMessageIds.insert(key)

        // Переотправляем ТОЛЬКО текст: служебные (квитанции, typing, сигналинг звонка) переотправлять
        // бессмысленно — они давно протухли. Если исходника уже нет локально (удалили), ограничиваемся
        // сбросом сессии: следующее сообщение уйдёт по новой и дойдёт.
        guard let original = ChatStore.findByServerMessageId(req.messageId),
              original.isMine, original.kind == "text", !original.text.isEmpty else {
            print("♻️ retry: исходник \(req.messageId.prefix(8)) не найден локально — только сброс сессии")
            return
        }

        do {
            var payload = MessagePayload(type: "text", sentAt: original.sentAt)
            payload.text = original.text
            let plaintext = try JSONEncoder().encode(payload)
            try await SignalSession.shared.ensureSession(userId: fromUserId, deviceId: fromDeviceId, protocolDeviceId: pid)
            let (type, cipher) = try await SignalSession.shared.encrypt(plaintext, userId: fromUserId, protocolDeviceId: pid)
            let body = SendMessageRequest(recipientUserId: nil, conversationId: conversationId,
                                          deliveries: [.init(recipientDeviceId: fromDeviceId, envelopeType: type, ciphertext: cipher)],
                                          silent: true)
            let _: SendMessageResponse = try await APIClient.shared.request("messages", method: "POST", body: body)
            print("♻️ переотправлено \(req.messageId.prefix(8)) → \(fromDeviceId.prefix(8))")
        } catch {
            print("♻️ переотправка не удалась:", error)
        }
    }

    // «печатает…» — E2EE, silent + ephemeral (сервер не видит смысл, не пушит, не двигает беседу).
    // Только устройства получателя (свои не нужны), best-effort: ошибки глотаем, ретраев нет.
    func sendTyping(state: String, recipientUserId: String, conversationId: String) async {
        var payload = MessagePayload(type: "typing", sentAt: Int64(Date().timeIntervalSince1970 * 1000))
        payload.typing = TypingSignal(state: state)
        guard let plaintext = try? JSONEncoder().encode(payload) else { return }

        var deliveries: [DeliveryInput] = []
        for d in await DeviceResolver.shared.devices(userId: recipientUserId) {
            do {
                try await SignalSession.shared.ensureSession(userId: recipientUserId, deviceId: d.deviceId,
                                                             protocolDeviceId: d.protocolDeviceId)
                let (type, cipher) = try await SignalSession.shared.encrypt(plaintext, userId: recipientUserId,
                                                                            protocolDeviceId: d.protocolDeviceId)
                deliveries.append(.init(recipientDeviceId: d.deviceId, envelopeType: type, ciphertext: cipher))
            } catch { /* одно устройство не валит остальные; typing — best-effort */ }
        }
        guard !deliveries.isEmpty else { return }
        let body = SendMessageRequest(recipientUserId: nil, conversationId: conversationId,
                                      deliveries: deliveries, silent: true, ephemeral: true)
        do { let _: SendMessageResponse = try await APIClient.shared.request("messages", method: "POST", body: body) }
        catch { /* best-effort */ }
    }

    // синк блок-листа на СВОИ другие устройства (E2EE type:"block", silent+ephemeral). Сервер смысла не
    // видит. recipientUserId = заблокированный — так сервер найдёт/создаст беседу, а мои устройства её
    // участники; шлём ТОЛЬКО им (не заблокированному).
    func sendBlockSync(userId: String, username: String?, blocked: Bool) async {
        let myUserId = AuthState.myUserId ?? ""
        guard !myUserId.isEmpty else { return }
        var payload = MessagePayload(type: "block", sentAt: Int64(Date().timeIntervalSince1970 * 1000))
        payload.block = BlockSignal(userId: userId, username: username, blocked: blocked)
        guard let plaintext = try? JSONEncoder().encode(payload) else { return }

        var deliveries: [DeliveryInput] = []
        for d in await DeviceResolver.shared.devices(userId: myUserId)
        where d.protocolDeviceId != DeviceIdentity.protocolDeviceId {
            do {
                try await SignalSession.shared.ensureSession(userId: myUserId, deviceId: d.deviceId,
                                                             protocolDeviceId: d.protocolDeviceId)
                let (type, cipher) = try await SignalSession.shared.encrypt(plaintext, userId: myUserId,
                                                                            protocolDeviceId: d.protocolDeviceId)
                deliveries.append(.init(recipientDeviceId: d.deviceId, envelopeType: type, ciphertext: cipher))
            } catch { }
        }
        guard !deliveries.isEmpty else { return }   // одно устройство — синкать некуда
        let body = SendMessageRequest(recipientUserId: userId, conversationId: nil,
                                      deliveries: deliveries, silent: true, ephemeral: true)
        do { let _: SendMessageResponse = try await APIClient.shared.request("messages", method: "POST", body: body) }
        catch { }
    }

    // «Удалить контакт»: стереть беседу целиком (для ОБОИХ). 1) сигнал type:"deleteConversation" собеседнику
    // и своим устройствам (best-effort, пока беседа жива) — их клиенты сотрут локальную историю; 2) удалить
    // беседу на сервере (каскад — исчезает из списков обоих); 3) стереть локально у себя.
    func deleteContact(conversationId: String, recipientUserId: String) async {
        let payload = MessagePayload(type: "deleteConversation", sentAt: Int64(Date().timeIntervalSince1970 * 1000))
        if let plaintext = try? JSONEncoder().encode(payload) {
            _ = try? await deliver(plaintext: plaintext, recipientUserId: recipientUserId,
                                   conversationId: conversationId, silent: true)   // → собеседник + свои устройства
        }
        let _: DeletedResponse? = try? await APIClient.shared.request("conversations/\(conversationId)", method: "DELETE")
        ChatStore.deleteConversation(conversationId)
    }

    // редактирование своего сообщения (type:"edit", Signal-style: сервер не знает о правке).
    // silent + ephemeral — без пуша и без поднятия беседы (как в Telegram). Локально правим сразу
    // (оптимистично), собеседник и свои устройства применят из fan-out.
    func sendEdit(targetServerMessageId: String, newText: String,
                  recipientUserId: String, conversationId: String) async {
        let sentAt = Int64(Date().timeIntervalSince1970 * 1000)
        ChatStore.applyEdit(targetId: targetServerMessageId, newText: newText,
                            editedAt: sentAt, authorUserId: AuthState.myUserId ?? "")
        var payload = MessagePayload(type: "edit", sentAt: sentAt)
        payload.edit = EditRef(targetMessageId: targetServerMessageId, text: newText)
        do {
            let plaintext = try JSONEncoder().encode(payload)
            _ = try await deliver(plaintext: plaintext, recipientUserId: recipientUserId,
                                  conversationId: conversationId, silent: true, ephemeral: true)
        } catch {
            print("sendEdit error:", error)   // best-effort: локально уже применили
        }
    }

    // полное удаление у всех (type:"delete", Signal-style remoteDelete): без пуша и поднятия беседы.
    // Локально удаляем сразу; собеседник и свои устройства удалят из fan-out. Без tombstone.
    func sendDelete(targetServerMessageId: String, recipientUserId: String, conversationId: String) async {
        ChatStore.applyDelete(targetId: targetServerMessageId, authorUserId: AuthState.myUserId ?? "")
        var payload = MessagePayload(type: "delete", sentAt: Int64(Date().timeIntervalSince1970 * 1000))
        payload.delete = DeleteRef(targetMessageId: targetServerMessageId)
        do {
            let plaintext = try JSONEncoder().encode(payload)
            _ = try await deliver(plaintext: plaintext, recipientUserId: recipientUserId,
                                  conversationId: conversationId, silent: true, ephemeral: true)
        } catch {
            print("sendDelete error:", error)   // best-effort: локально уже удалили
        }
    }

    // реакция на сообщение (type:"reaction"): как правка — silent + ephemeral, без пуша и без поднятия
    // беседы. Локально применяем сразу; собеседник и свои устройства применят из fan-out.
    // emoji == nil — снять свою реакцию.
    func sendReaction(targetServerMessageId: String, emoji: String?,
                      recipientUserId: String, conversationId: String) async {
        let sentAt = Int64(Date().timeIntervalSince1970 * 1000)
        ChatStore.applyReaction(targetId: targetServerMessageId, conversationId: conversationId,
                                userId: AuthState.myUserId ?? "", emoji: emoji, at: sentAt)
        var payload = MessagePayload(type: "reaction", sentAt: sentAt)
        payload.reaction = ReactionRef(targetMessageId: targetServerMessageId, emoji: emoji)
        do {
            let plaintext = try JSONEncoder().encode(payload)
            _ = try await deliver(plaintext: plaintext, recipientUserId: recipientUserId,
                                  conversationId: conversationId, silent: true, ephemeral: true)
        } catch {
            print("sendReaction error:", error)   // best-effort: локально уже применили
        }
    }

    // reconcile статусов delivered (на открытие чата / foreground): добираем из Postgres то, что мог потерять WS
    func reconcileStatuses(conversationId: String) async {
        do {
            let resp: StatusesResponse = try await APIClient.shared.request(
                "messages/statuses", query: ["conversationId": conversationId])
            for s in resp.statuses where s.deliveredAt != nil {
                ChatStore.applyStatus(serverMessageId: s.messageId, .delivered)
            }
        } catch {
            print("reconcileStatuses error:", error)
        }
    }

    // общий fan-out: шифруем под устройства получателя + свои остальные, шлём POST /messages.
    // Горячий путь: девайс-листы из кэша DeviceResolver (обычно 0 лишних запросов, только POST).
    // Если кэш разошёлся с сервером (устройство удалили/добавили) — invalidate + ОДИН повтор.
    private func deliver(plaintext: Data, recipientUserId: String,
                         conversationId: String?, silent: Bool, ephemeral: Bool = false,
                         clientMessageId: String? = nil) async throws -> SendMessageResponse {
        do {
            return try await attemptDeliver(plaintext: plaintext, recipientUserId: recipientUserId,
                                            conversationId: conversationId, silent: silent, ephemeral: ephemeral,
                                            clientMessageId: clientMessageId)
        } catch let error where Self.isStaleDeviceListError(error) {
            await DeviceResolver.shared.invalidate(userId: recipientUserId)
            if let my = AuthState.myUserId { await DeviceResolver.shared.invalidate(userId: my) }
            return try await attemptDeliver(plaintext: plaintext, recipientUserId: recipientUserId,
                                            conversationId: conversationId, silent: silent, ephemeral: ephemeral,
                                            clientMessageId: clientMessageId)
        }
    }

    // Отправка строки очереди. Вызывает только OutboxWorker.
    //
    // ⚠️ Шифрование происходит ЗДЕСЬ, а не при постановке в очередь: Double Ratchet двигает цепочку
    // на каждом шифровании, и заранее зашифрованное отложенное сообщение ломало бы её при повторах.
    func sendQueued(_ item: OutboxItem) async throws -> SendMessageResponse {
        try await deliver(plaintext: item.plaintext, recipientUserId: item.recipientUserId,
                          conversationId: item.conversationId, silent: false,
                          clientMessageId: item.localId)
    }

    // ошибки, означающие «наш девайс-лист протух» (или его не удалось собрать) — после
    // invalidate имеет смысл повторить. Сетевые ошибки POST сюда НЕ входят: запрос мог
    // успеть закоммититься на сервере, повтор создал бы дубль сообщения.
    private static func isStaleDeviceListError(_ error: Error) -> Bool {
        guard case APIError.server(let msg) = error else { return false }
        return msg.contains("Stale device list")               // 409: сервер сверил полноту девайс-листа (Signal-style)
            || msg.contains("Invalid recipient device")        // 403: чужое устройство (совместимость со старым бэком)
            || msg.contains("No deliverable devices")          // 422: старый бэк, пропал ключевой материал
            || msg == "Нет устройств получателя"               // локально: пустой/протухший список
            || msg == "Не удалось зашифровать сообщение"       // локально: все bundle-фетчи упали (напр. девайс удалён)
    }

    private func attemptDeliver(plaintext: Data, recipientUserId: String,
                                conversationId: String?, silent: Bool, ephemeral: Bool = false,
                                clientMessageId: String? = nil) async throws -> SendMessageResponse {
        let myUserId = AuthState.myUserId ?? ""

        var targets: [(userId: String, deviceId: String, protocolDeviceId: Int)] = []
        for d in await DeviceResolver.shared.devices(userId: recipientUserId) {
            targets.append((recipientUserId, d.deviceId, d.protocolDeviceId))
        }
        // свои остальные устройства — через тот же кэш (/users/:id/devices отдаёт и себя),
        // вместо GET /me на каждом сообщении
        if !myUserId.isEmpty {
            for d in await DeviceResolver.shared.devices(userId: myUserId)
            where d.protocolDeviceId != DeviceIdentity.protocolDeviceId {
                targets.append((myUserId, d.deviceId, d.protocolDeviceId))
            }
        }
        guard !targets.isEmpty else { throw APIError.server("Нет устройств получателя") }

        var encrypted: [(deviceId: String, envelopeType: Int, ciphertext: Data)] = []
        for t in targets {
            do {
                try await SignalSession.shared.ensureSession(userId: t.userId, deviceId: t.deviceId,
                                                             protocolDeviceId: t.protocolDeviceId)
                let (type, cipher) = try await SignalSession.shared.encryptRaw(plaintext, userId: t.userId,
                                                                               protocolDeviceId: t.protocolDeviceId)
                encrypted.append((t.deviceId, type, cipher))
            } catch {
                print("🔒 не зашифровал для \(t.deviceId):", error)   // одно устройство не валит остальные
            }
        }
        guard !encrypted.isEmpty else { throw APIError.server("Не удалось зашифровать сообщение") }

        let recipient = conversationId == nil ? recipientUserId : nil

        // Бинарный путь: шифртексты уходят байтами, без base64 (минус треть на самой тяжёлой части).
        if Self.binarySendAvailable {
            do {
                let raw = Self.binaryBody(recipientUserId: recipient, conversationId: conversationId,
                                          clientMessageId: clientMessageId, silent: silent,
                                          ephemeral: ephemeral, encrypted: encrypted)
                return try await APIClient.shared.request("messages/binary", method: "POST", rawBody: raw)
            } catch let error where Self.isBinaryUnsupported(error) {
                // Бэкенд старше клиента — на нём такого маршрута нет. Один раз выясняем и дальше
                // работаем по JSON: иначе каждое сообщение платило бы лишним неудачным запросом.
                Self.binarySendAvailable = false
                print("✉️ бинарная отправка не поддержана сервером, переходим на JSON")
            }
        }

        let body = SendMessageRequest(recipientUserId: recipient,
                                      conversationId: conversationId,
                                      deliveries: encrypted.map {
                                          .init(recipientDeviceId: $0.deviceId, envelopeType: $0.envelopeType,
                                                ciphertext: $0.ciphertext.base64EncodedString())
                                      },
                                      silent: silent ? true : nil,
                                      ephemeral: ephemeral ? true : nil,
                                      clientMessageId: clientMessageId)
        return try await APIClient.shared.request("messages", method: "POST", body: body)
    }

    // ===== БИНАРНОЕ ТЕЛО ОТПРАВКИ (network-optimization.md, этап 4) =====

    // Выяснено на первом же запросе и дальше не перепроверяется: деплой бэкенда и выкладка клиента
    // идут врозь, и клиент может оказаться новее сервера.
    private static var binarySendAvailable = true

    private struct BinaryHeader: Encodable {
        struct Item: Encodable {
            let recipientDeviceId: String
            let envelopeType: Int
            let len: Int
        }
        let recipientUserId: String?
        let conversationId: String?
        let clientMessageId: String?
        let silent: Bool?
        let ephemeral: Bool?
        let deliveries: [Item]
    }

    // [версия:1][длина заголовка:4 BE][JSON-заголовок][шифртексты подряд]
    private static func binaryBody(recipientUserId: String?, conversationId: String?,
                                   clientMessageId: String?, silent: Bool, ephemeral: Bool,
                                   encrypted: [(deviceId: String, envelopeType: Int, ciphertext: Data)]) -> Data {
        let header = BinaryHeader(
            recipientUserId: recipientUserId,
            conversationId: conversationId,
            clientMessageId: clientMessageId,
            silent: silent ? true : nil,
            ephemeral: ephemeral ? true : nil,
            deliveries: encrypted.map {
                .init(recipientDeviceId: $0.deviceId, envelopeType: $0.envelopeType, len: $0.ciphertext.count)
            }
        )
        let headerJSON = (try? JSONEncoder().encode(header)) ?? Data()

        var body = Data([1])
        var length = UInt32(headerJSON.count).bigEndian
        withUnsafeBytes(of: &length) { body.append(contentsOf: $0) }
        body.append(headerJSON)
        // Порядок шифртекстов обязан совпадать с порядком deliveries в заголовке — сервер режет
        // хвост буфера именно по этим длинам и по этому порядку.
        for e in encrypted { body.append(e.ciphertext) }

        return body
    }

    // «Такого маршрута нет» от старого бэкенда. 404 Nest отдаёт в конверте с текстом Cannot POST,
    // поэтому ловим обе формы; 415 — на случай, если тело не распознали как бинарное.
    private static func isBinaryUnsupported(_ error: Error) -> Bool {
        if case APIError.http(let code) = error { return code == 404 || code == 415 }
        if case APIError.server(let msg) = error { return msg.contains("Cannot POST") }

        return false
    }

    // ===== ПРИЁМ (дёргается на WS-пинг / периодический опрос / foreground / коннект) =====
    // single-flight: параллельные вызовы не пересекаются (иначе конкурентная расшифровка по одной сессии)

    // Конверты, пришедшие прямо по вебсокету: их расшифровка идёт через ТОТ ЖЕ гейт, что и синк.
    // Мимо гейта нельзя — две параллельные расшифровки по одной сессии ломают Double Ratchet.
    private var inlineBuffer: [IncomingDelivery] = []
    // Нужен ли сетевой GET /messages в ближайшем проходе. Конверт по сокету его НЕ требует —
    // в этом и экономия: получателю остаётся один запрос (ack) вместо двух.
    private var needsFullSync = false

    func sync() async {
        needsFullSync = true
        await runSync()
    }

    // Конверт пришёл целиком по сокету (этап 2 network-optimization.md).
    func ingest(_ delivery: IncomingDelivery) async {
        inlineBuffer.append(delivery)
        await runSync()
    }

    private func runSync() async {
        guard await gate.begin() else { return }    // уже идёт — выходим, текущий проход догонит
        repeat {
            await doSync()
        } while await gate.endAndRepeat()
    }

    private func doSync() async {
        await drainInline()

        // Пришёл только конверт по сокету — ходить в сеть незачем.
        guard needsFullSync else { return }
        needsFullSync = false

        do {
            let resp: MessagesSyncResponse = try await APIClient.shared.request("messages")
            guard !resp.deliveries.isEmpty else { return }
            var ackIds: [String] = []
            for d in resp.deliveries {
                if await handle(d) { ackIds.append(d.deliveryId) }
            }
            if !ackIds.isEmpty {
                let _: AckResponse = try await APIClient.shared.request(
                    "messages/ack", method: "POST", body: AckRequest(deliveryIds: ackIds))
            }
        } catch {
            print("sync error:", error)
            // Флаг возвращаем: иначе один сетевой сбой означал бы «синк уже сделали»,
            // и пропущенное ждало бы следующего внешнего повода.
            needsFullSync = true
        }
    }

    // Расшифровка конвертов, пришедших по сокету. Дедуп по deliveryId живёт внутри MessageIngest,
    // поэтому гонка «конверт по сокету + тот же конверт в ответе GET /messages» безопасна:
    // обработается один раз, а повторный ack сервер просто не найдёт неподтверждённым.
    private func drainInline() async {
        guard !inlineBuffer.isEmpty else { return }

        let batch = inlineBuffer
        inlineBuffer.removeAll()

        var ackIds: [String] = []
        for d in batch {
            if await handle(d) { ackIds.append(d.deliveryId) }
        }
        guard !ackIds.isEmpty else { return }

        do {
            let _: AckResponse = try await APIClient.shared.request(
                "messages/ack", method: "POST", body: AckRequest(deliveryIds: ackIds))
        } catch {
            // Сообщение уже расшифровано и записано — терять нечего. Не подтверждённую доставку
            // сервер дошлёт пушем-фолбэком, а дубликат отсечёт дедуп по deliveryId.
            print("inline ack error:", error)
        }
    }

    // расшифровать один конверт через общий конвейер (тот же, что у NSE); true → можно ack-ать.
    // Дедуп/расшифровка/запись — внутри MessageIngest. Здесь только UI-побочки.
    private func handle(_ d: IncomingDelivery) async -> Bool {
        switch await MessageIngest.process(d) {
        case .retry:
            return false                        // не резолвится устройство и т.п. — попробуем позже, не ack-аем
        case .processed(let ingested):
            if let ingested {
                if ingested.gotProfileKey {
                    await MainActor.run { ContactProfileCache.shared.refresh(ingested.senderUserId) }
                }
                if let sig = ingested.callSignal, let dev = ingested.senderDeviceId {
                    await CallManager.shared.handleSignal(sig, fromUserId: ingested.senderUserId,
                                                          fromDeviceId: dev, conversationId: ingested.conversationId)
                }
                if let state = ingested.typingState {
                    await TypingStore.shared.apply(conversationId: ingested.conversationId,
                                                   state: state, sentAt: ingested.typingSentAt ?? 0)
                }
                if ingested.blockChanged {                       // синк блока с другого устройства → обновить UI
                    await BlockState.shared.reload()
                }
                if ingested.conversationDeleted {                // «удалить контакт» — обновить открытый чат/список
                    await MainActor.run { NotificationCenter.default.post(name: .pushNewMessage, object: nil) }
                }
            }
            return true
        }
    }
}
