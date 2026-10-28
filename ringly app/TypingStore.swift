import Foundation
import Combine

// «Печатает…» собеседника. Приходит E2EE silent+ephemeral-сигналом (type:"typing"), сервер смысла не видит.
// Ключ — conversationId (DIRECT → один собеседник). Авто-сброс, если "start" не обновляется.
@MainActor
final class TypingStore: ObservableObject {
    static let shared = TypingStore()
    private init() {}

    @Published private(set) var typing: [String: Bool] = [:]     // conversationId → печатает ли собеседник
    private var expiries: [String: Task<Void, Never>] = [:]

    private let freshnessMs: Int64 = 6_000       // typing старше 6с (доставлен поздно) — игнор
    private let autoStopSec: UInt64 = 6          // нет обновления "start" 6с → сбрасываем

    func apply(conversationId: String, state: String, sentAt: Int64) {
        // протухший сигнал (например, собеседник был офлайн и typing доставился с задержкой) — игнор
        let age = Int64(Date().timeIntervalSince1970 * 1000) - sentAt
        guard age < freshnessMs else { return }

        if state == "stop" { clear(conversationId); return }

        typing[conversationId] = true
        expiries[conversationId]?.cancel()
        expiries[conversationId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: (self?.autoStopSec ?? 6) * 1_000_000_000)
            if !Task.isCancelled { self?.clear(conversationId) }
        }
    }

    private func clear(_ conversationId: String) {
        typing[conversationId] = nil
        expiries[conversationId]?.cancel()
        expiries[conversationId] = nil
    }
}
