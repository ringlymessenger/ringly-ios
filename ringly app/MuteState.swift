import Foundation
import Combine

// Реактивная обёртка над MuteStore для SwiftUI. Мьют локальный (на этом устройстве): от замьюченного
// собеседника сообщения приходят в чат, но без пуш-уведомлений (NSE их не показывает).
@MainActor
final class MuteState: ObservableObject {
    static let shared = MuteState()
    private init() { reload() }

    @Published private(set) var mutedIds: Set<String> = []

    func isMuted(_ userId: String) -> Bool { mutedIds.contains(userId) }
    func reload() { mutedIds = Set(MuteStore.all()) }

    func setMuted(_ userId: String, _ muted: Bool) {
        MuteStore.setMuted(userId, muted: muted)
        reload()
    }
}
