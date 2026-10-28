import Foundation

// Межпроцессное уведомление (Darwin notification): NSE записал сообщение в общую БД →
// будит приложение перечитать базу. Нужно потому, что GRDB ValueObservation НЕ видит
// записи из другого процесса (NSE), и UI не обновляется до собственной записи приложения.
// Так же это решает Signal.
final class CrossProcessNotifier {
    static let shared = CrossProcessNotifier()
    private static let darwinName = "com.reguzov.ringly.newMessage" as CFString

    var onNewMessage: (() -> Void)?

    // приложение: начать слушать (Darwin доходит только до живого процесса —
    // для разбуженного из suspend используем ещё и перечитку на foreground).
    func startObserving() {
        let me = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), me,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let notifier = Unmanaged<CrossProcessNotifier>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { notifier.onNewMessage?() }
            },
            Self.darwinName, nil, .deliverImmediately)
    }

    // NSE: дёрнуть после записи новых сообщений в общую БД
    func postNewMessage() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(Self.darwinName), nil, nil, true)
    }
}
