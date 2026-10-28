import UserNotifications

// Уведомления в шторке о чатах, которые уже прочитаны, — убираем, как Telegram и iMessage.
// Иначе человек открыл приложение, всё прочитал, а в шторке и на экране блокировки висят
// баннеры о сообщениях, которые он уже видел.
//
// Чат уведомления узнаём по conversationId, который проставляет NSE (userInfo и threadIdentifier).
// Неатрибутированные «New message» (NSE не успел расшифровать) к чату не привязать — их не трогаем.
enum DeliveredNotifications {
    static func clear(conversationId: String) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let ids = delivered
                .filter {
                    let content = $0.request.content
                    return content.threadIdentifier == conversationId
                        || content.userInfo["conversationId"] as? String == conversationId
                }
                .map(\.request.identifier)
            guard !ids.isEmpty else { return }
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }
}
