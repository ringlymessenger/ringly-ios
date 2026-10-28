import UserNotifications

// Notification Service Extension: будится content-free пушем (mutable-content),
// локально расшифровывает входящие и подменяет баннер реальным именем/текстом.
// Вся крипта/дедуп — в общем RinglyCore (тот же конвейер, что у приложения).
class NotificationService: UNNotificationServiceExtension {

    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttempt: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        bestAttempt = request.content.mutableCopy() as? UNMutableNotificationContent

        Task {
            switch await drainAndDecrypt() {
            case .message(let preview):
                bestAttempt?.title = preview.title
                bestAttempt?.body = preview.body
                // атрибуция чата: threadIdentifier группирует баннеры по беседе, а conversationId в
                // userInfo читает willPresent приложения — чтобы гасить баннер про ОТКРЫТЫЙ чат.
                // Неатрибутированный (generic) баннер = NSE не нашёл ничего нового для показа.
                bestAttempt?.threadIdentifier = preview.conversationId
                var info = bestAttempt?.userInfo ?? [:]
                info["conversationId"] = preview.conversationId
                info["senderUserId"] = preview.senderUserId
                bestAttempt?.userInfo = info
            case .hiddenOnly:
                #if RINGLY_NOTIFICATION_FILTERING
                // Право usernotifications.filtering выдано Apple → уведомление не показываем вовсе
                // (Signal-way): пустой контент с этим правом = «не отображать». Без права тот же вызов
                // показал бы ПУСТОЙ баннер, поэтому ветка — только под флагом, который включается
                // вместе с правом (mute-notification-suppression.md «После гранта»).
                self.contentHandler = nil
                contentHandler(UNNotificationContent())
                return
                #else
                // Без права ОТМЕНИТЬ показ нельзя, но можно понизить до «тихого»: passive не
                // показывает баннер, не зажигает экран и не играет звук — остаётся только молчаливая
                // generic-строка в Notification Center (без имени/текста).
                bestAttempt?.sound = nil
                bestAttempt?.interruptionLevel = .passive
                #endif
            case .none:
                break   // ничего нового не расшифровали → исходный generic-баннер (фолбэк)
            }
            // бейдж иконки = локальное число непрочитанных (от не-замьюченных). NSE только что дописала
            // входящие в общую БД, поэтому счётчик уже актуален. Сервер бейдж не знает (E2EE).
            if TokenStore.shared.token != nil {
                bestAttempt?.badge = NSNumber(value: ReadStore.totalUnreadBadge())
            }
            deliver()
        }
    }

    // iOS вот-вот убьёт расширение → отдаём что есть (в худшем случае generic «New message»).
    override func serviceExtensionTimeWillExpire() {
        deliver()
    }

    private func deliver() {
        guard let contentHandler, let bestAttempt else { return }
        self.contentHandler = nil
        contentHandler(bestAttempt)
    }

    // Итог дренажа для баннера: показать превью / скрыть (все новые — от замьюченных или
    // заблокированных) / оставить исходный generic (ничего нового не расшифровали).
    private enum Drained {
        case message((title: String, body: String, conversationId: String, senderUserId: String))
        case hiddenOnly
        case none
    }

    // Дренит очередь, расшифровывает через общий конвейер (дедуп защищает от двойного ратчета),
    // акает обработанное и возвращает заголовок/текст (+ атрибуцию чата) по последнему текстовому сообщению.
    private func drainAndDecrypt() async -> Drained {
        guard TokenStore.shared.token != nil else { return .none }   // не авторизованы — нечего показывать
        do {
            let resp: MessagesSyncResponse = try await APIClient.shared.request("messages")
            guard !resp.deliveries.isEmpty else { return .none }

            var ackIds: [String] = []
            var lastText: IngestedMessage?
            var sawHidden = false
            for d in resp.deliveries {
                switch await MessageIngest.process(d) {
                case .retry:
                    break                                  // не резолвится устройство — не акаем, приложение добёрет
                case .processed(let m):
                    ackIds.append(d.deliveryId)
                    // Заблокированный: ingest молча выбросил сообщение (m == nil). Раньше это давало
                    // .none → ГРОМКИЙ generic «Новое сообщение» от того, кого человек заблокировал.
                    if BlockStore.isBlocked(d.senderUserId) {
                        sawHidden = true
                        continue
                    }
                    // замьюченный: сообщение уже сохранено в чат, но в баннер его НЕ берём —
                    // если ВСЕ новые от замьюченных/заблокированных, уведомление скрывается (см. didReceive)
                    if let m, !m.isReceipt, m.text != nil {
                        if MuteStore.isMuted(m.senderUserId) { sawHidden = true } else { lastText = m }
                    }
                }
            }

            if !ackIds.isEmpty {
                let _: AckResponse = try await APIClient.shared.request(
                    "messages/ack", method: "POST", body: AckRequest(deliveryIds: ackIds))
                CrossProcessNotifier.shared.postNewMessage()   // разбудить приложение перечитать БД
            }

            guard let last = lastText, let text = last.text else { return sawHidden ? .hiddenOnly : .none }
            // имя берём из локального кэша профиля контакта (расшифровывается приложением заранее);
            // если ещё не знаем — generic-заголовок, но текст уже реальный.
            let title = ContactProfileStore.load(last.senderUserId)?.name ?? L("Новое сообщение")
            return .message((title, text, last.conversationId, last.senderUserId))
        } catch {
            return .none
        }
    }
}
