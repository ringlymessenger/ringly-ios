import SwiftUI
import Combine

// Лёгкий общий стор баланса Rings для пилюли на главном экране. RingsViewModel пушит сюда
// свежий баланс (после load / покупки / награды), а ChatListView просто отображает и рефрешит
// на появлении — так пилюля остаётся актуальной без дублирования сетевой логики.
@MainActor
final class RingsBalanceStore: ObservableObject {
    static let shared = RingsBalanceStore()
    private init() {}

    @Published private(set) var balance: Int?      // nil = ещё не загружали (пилюлю не показываем)

    private let service = RingsService()

    func refresh() async {
        if let s = try? await service.status() { balance = s.balance }
    }

    // вызывается из RingsViewModel, когда он уже знает актуальный баланс
    func set(_ value: Int) { balance = value }

    // сбросить на logout (в wipeAccountLocalData / logout)
    func clear() { balance = nil }
}
