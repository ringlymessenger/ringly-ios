import Foundation
import Network

// Фоновая отправка сообщений из очереди (network-optimization.md, этап 1б).
//
// До него отправка была одноразовой попыткой: не ушло — крестик и ожидание, пока человек сам нажмёт
// повтор. Теперь сообщение лежит в `outbox` и дошлётся само, как только появится связь.
//
// Повторы безопасны благодаря `clientMessageId` (= localId): сервер дедуплицирует по нему и на
// повтор отдаёт тот же messageId вместо второго сообщения. Без серверной половины этот воркер
// плодил бы дубликаты при каждом «запрос дошёл, ответ потерялся».
//
// @MainActor, а не actor: хранилища (ChatStore/OutboxStore) и MessagingService в этом проекте
// изолированы главным актором, и свой актор означал бы хоп на каждое обращение к базе.
// Главный поток это не держит — единственная долгая операция здесь под await.
@MainActor
final class OutboxWorker {
    static let shared = OutboxWorker()

    // Пауза перед следующей попыткой по номеру попытки. Дальше потолок — последний элемент.
    // Первые шаги короткие (обрыв связи обычно короткий), дальше редеем, чтобы не греть радио.
    private static let backoff: [TimeInterval] = [2, 5, 15, 30, 60, 120, 300, 600, 900, 1800]

    // Сколько всего пытаемся. Сутки — осознанно много: цель очереди в том, чтобы сообщение ушло
    // после поездки в метро или ночи без связи, а не «ещё разок через минуту».
    private static let giveUpAfter: TimeInterval = 24 * 3600

    private let messaging = MessagingService()
    private var pass: Task<Void, Never>?        // текущий проход
    private var wakeTimer: Task<Void, Never>?   // сон до ближайшего срока
    private var monitor: NWPathMonitor?

    private init() {}

    // Зовётся из bootstrap — то есть и на старте, и на каждый foreground.
    func start() {
        if monitor == nil {
            let m = NWPathMonitor()
            m.pathUpdateHandler = { path in
                // Возврат связи — главный повод не ждать backoff, а попробовать немедленно.
                guard path.status == .satisfied else { return }
                Task { @MainActor in OutboxWorker.shared.kick() }
            }
            m.start(queue: DispatchQueue(label: "ringly.outbox.path"))
            monitor = m
        }

        // Пинаем на КАЖДЫЙ вызов, а не только при первом: foreground — бесплатный повод
        // проверить очередь.
        kick()
    }

    // «Попробуй сейчас». Безопасно звать сколько угодно: пока идёт проход, лишние вызовы
    // схлопываются, второго параллельного не будет.
    func kick() {
        guard pass == nil else { return }

        pass = Task { [weak self] in
            await self?.runPass()
            self?.pass = nil
            self?.scheduleWake()
        }
    }

    private func runPass() async {
        // Головы очередей: по одной самой старой строке на беседу. Порядок внутри беседы обязан
        // сохраняться, иначе получатель увидит сообщения переставленными; а разные беседы
        // независимы — застрявшая переписка не задерживает остальные.
        //
        // Цикл, а не рекурсия: после удачной отправки головой становится следующее сообщение той же
        // беседы, и длинная накопленная очередь уходила бы в стек глубиной во всю себя.
        while !Task.isCancelled {
            let heads = OutboxStore.dueHeads()
            if heads.isEmpty { return }

            for item in heads {
                if Task.isCancelled { return }

                do {
                    let res = try await messaging.sendQueued(item)
                    ChatStore.markSent(localId: item.localId, serverMessageId: res.messageId,
                                       serverSentAt: res.serverTimeMs)
                    OutboxStore.remove(localId: item.localId)
                    print("📤 очередь: отправлено \(item.localId.prefix(8))")
                } catch {
                    if Self.isAuthFailure(error) {
                        // Сессия протухла или аккаунт вышел — пытаться дальше бессмысленно, и попытку
                        // засчитывать нельзя: иначе один разлогин сожжёт весь лимит попыток и
                        // сообщения «сдадутся», хотя сеть была в порядке.
                        print("📤 очередь: нет авторизации, пауза")

                        return
                    }

                    handleFailure(item, error)
                }
            }
        }
    }

    private func handleFailure(_ item: OutboxItem, _ error: Error) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let ageSeconds = TimeInterval(now - item.createdAt) / 1000

        if ageSeconds >= Self.giveUpAfter {
            // Сдаёмся: возвращаем прежнее поведение — крестик и ручной повтор. Честнее показать,
            // что не вышло, чем бесконечно крутить «отправляется».
            ChatStore.markFailed(localId: item.localId)
            OutboxStore.remove(localId: item.localId)
            print("📤 очередь: сдались по \(item.localId.prefix(8)) после суток — \(error)")

            return
        }

        let attempts = item.attempts + 1
        let delay = Self.backoff[min(attempts - 1, Self.backoff.count - 1)]
        OutboxStore.reschedule(localId: item.localId, attempts: attempts,
                               nextAttemptAt: now + Int64(delay * 1000))
        print("📤 очередь: попытка \(attempts) для \(item.localId.prefix(8)) не прошла, через \(Int(delay))с — \(error)")
    }

    // Сон до ближайшего срока. Без него очередь двигалась бы только на внешние события
    // (сеть, foreground), и backoff в 30 секунд ждал бы следующего запуска приложения.
    private func scheduleWake() {
        wakeTimer?.cancel()
        wakeTimer = nil

        guard let next = OutboxStore.earliestNextAttempt() else { return }

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let delay = max(0.5, TimeInterval(next - now) / 1000)

        wakeTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.kick()
        }
    }

    // Тот же набор признаков, что у AppViewModel.isAuthFailure — списки должны совпадать,
    // иначе очередь будет жечь попытки там, где приложение уже знает, что токен недействителен.
    private static func isAuthFailure(_ error: Error) -> Bool {
        if case APIError.server(let msg) = error {
            return msg.contains("Invalid token") || msg.contains("Missing bearer token")
        }
        if case APIError.http(let code) = error { return code == 401 }

        return false
    }
}
