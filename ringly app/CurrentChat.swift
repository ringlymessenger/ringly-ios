import Foundation

// Какой чат сейчас на экране. Два потребителя:
//  - AppDelegate.willPresent — гасит баннер уведомления про открытый чат (Signal-style: сообщение
//    уже на экране, пуш — гоночный дубль);
//  - WebSocketClient (heartbeat) — периодически переподписывается на presence собеседника открытого
//    чата (самокоррекция, если сервер молча потерял подписку).
// Потокобезопасно через NSLock: willPresent вызывается не на main.
final class CurrentChat: @unchecked Sendable {
    static let shared = CurrentChat()
    private init() {}

    private let lock = NSLock()
    private var _conversationId: String?
    private var _peerUserId: String?

    var openConversationId: String? {
        lock.lock(); defer { lock.unlock() }
        return _conversationId
    }

    var openPeerUserId: String? {
        lock.lock(); defer { lock.unlock() }
        return _peerUserId
    }

    // conversationId может быть nil (новый чат из поиска — беседы ещё нет)
    func opened(peerUserId: String, conversationId: String?) {
        lock.lock(); defer { lock.unlock() }
        _peerUserId = peerUserId
        _conversationId = conversationId
    }

    // Закрыть только «свой» чат: при переходе чат→чат onDisappear старого экрана может прийти
    // ПОСЛЕ onAppear нового — безусловный сброс затирал бы актуальное значение.
    func closed(peerUserId: String) {
        lock.lock(); defer { lock.unlock() }
        guard _peerUserId == peerUserId else { return }
        _peerUserId = nil
        _conversationId = nil
    }
}
