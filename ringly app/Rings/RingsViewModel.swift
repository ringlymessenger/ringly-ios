import SwiftUI
import Combine

// Состояние раздела Rings: баланс, экономика (с сервера), услуга кастомного гудка.
@MainActor
final class RingsViewModel: ObservableObject {
    @Published var status: RingsStatus?
    @Published var loading = false
    @Published var busy = false               // покупка / загрузка / удаление в процессе
    @Published var errorMessage: String?
    @Published var toast: String?             // короткое уведомление об успехе

    private let service = RingsService()

    var balance: Int { status?.balance ?? 0 }
    var active: Bool { status?.ringback?.active == true }
    var adsLeftToday: Int {
        guard let s = status else { return 0 }
        return max(0, s.adDailyLimit - s.adsWatchedToday)
    }

    // дата истечения услуги (парсим ISO строку — в проекте даты строками)
    var expiresAtText: String? {
        guard let iso = status?.ringback?.expiresAt, let date = Self.parseISO(iso) else { return nil }
        return Self.dateText(date)
    }

    // До какой даты будет работать гудок после покупки `days`: сервер продлевает от максимума
    // (текущий срок, если он ещё не истёк, иначе — сейчас), докупка не сгорает. Для подтверждения.
    func expiryText(afterBuying days: Int) -> String {
        let current = status?.ringback?.expiresAt.flatMap(Self.parseISO)
        let base = current.map { max($0, Date()) } ?? Date()
        return Self.dateText(base.addingTimeInterval(TimeInterval(days) * 86_400))
    }

    private static func dateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM yyyy"
        return f.string(from: date)
    }

    func load() async {
        loading = status == nil
        defer { loading = false }
        do {
            status = try await service.status()
            RingsBalanceStore.shared.set(status!.balance)   // держим пилюлю на главной свежей
        }
        catch { errorMessage = error.localizedDescription }
    }

    func purchase(plan: String) async {
        busy = true; defer { busy = false }
        do {
            _ = try await service.purchase(plan: plan)
            await load()
            showToast(L("Услуга активирована"))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func uploadProcessed(_ data: Data) async {
        busy = true; defer { busy = false }
        CallDiag.log("🎵 мелодия: после обработки \(data.count / 1024) КБ, загружаем")
        do {
            _ = try await service.uploadAudio(data)
            await load()
            showToast(L("Мелодия загружена"))
        } catch {
            CallDiag.log("🎵 мелодия: сервер не принял — \(error)")
            errorMessage = error.localizedDescription
        }
    }

    func deleteAudio() async {
        busy = true; defer { busy = false }
        do {
            try await service.deleteAudio()
            await load()
            showToast(L("Мелодия удалена"))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // после досмотра рекламы SSV начисляет асинхронно — поллим баланс несколько секунд
    func pollAfterAd() async {
        let before = balance
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await load()
            if balance > before { showToast("Начислено \(balance - before) Rings"); return }
        }
        showToast(L("Начисление скоро появится"))
    }

    private func showToast(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if toast == text { toast = nil }
        }
    }

    private static func parseISO(_ s: String) -> Date? {
        let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter(); f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }
}
