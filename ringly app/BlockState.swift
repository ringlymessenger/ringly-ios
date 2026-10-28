import Foundation
import Combine

// Реактивная обёртка над локальным BlockStore (RinglyCore, SQLite) — для SwiftUI.
// Сам блок-лист НЕ уходит на сервер (Signal-style, приватность соц-графа). Синк между СВОИМИ
// устройствами — через E2EE type:"block" (MessagingService.sendBlockSync → MessageIngest.applyRemote).
struct BlockedContact: Identifiable {
    let userId: String
    let username: String?
    var id: String { userId }
}

@MainActor
final class BlockState: ObservableObject {
    static let shared = BlockState()
    private init() { reload() }

    @Published private(set) var blockedIds: Set<String> = []

    var list: [BlockedContact] {
        BlockStore.all().map { BlockedContact(userId: $0.userId, username: $0.username) }
    }

    func isBlocked(_ userId: String) -> Bool { blockedIds.contains(userId) }

    func reload() { blockedIds = Set(BlockStore.all().map { $0.userId }) }

    // блок/разблок с этого устройства: локально + синк на свои другие устройства
    func setBlocked(_ userId: String, username: String?, _ blocked: Bool) {
        BlockStore.setBlocked(userId, username: username, blocked: blocked)
        reload()
        Task { await MessagingService().sendBlockSync(userId: userId, username: username, blocked: blocked) }
    }

    // применить синк, пришедший с другого моего устройства (без повторной рассылки)
    func applyRemote(userId: String, username: String?, blocked: Bool) {
        BlockStore.setBlocked(userId, username: username, blocked: blocked)
        reload()
    }
}
