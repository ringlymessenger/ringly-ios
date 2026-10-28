import SwiftUI
import Combine

// Объявление администратора: баннер вверху списка чатов (docs/announcements.md). Одно на всех,
// живёт сутки (срок ставит сервер). Закрытие помнится по id: следующее объявление — новый id, и
// баннер появится снова. Что человек закрыл, сервер не узнаёт.
@MainActor
final class AnnouncementStore: ObservableObject {
    static let shared = AnnouncementStore()
    private init() {}

    private static let dismissedKey = "announcement.dismissedId"

    @Published private(set) var current: Announcement?
    @Published private var dismissedId: String? = UserDefaults.standard.string(forKey: dismissedKey)

    // что показывать: есть, не закрыто и не истекло (вдруг телефон долго был без сети)
    var visible: Announcement? {
        guard let a = current, a.id != dismissedId else { return nil }
        if let until = ServerTime.ms(a.expiresAt), until <= Int64(Date().timeIntervalSince1970 * 1000) { return nil }
        return a
    }

    // Список чатов и каждый возврат в приложение. Сбой сети — оставляем, что было.
    func refresh() async {
        guard AuthState.myUserId != nil else { return }   // не вошли — спрашивать не с чем (эндпоинт под авторизацией)
        guard let r: AnnouncementResponse = try? await APIClient.shared.request("announcements/current") else { return }
        current = r.announcement
    }

    func dismiss() {
        guard let id = current?.id else { return }
        dismissedId = id
        UserDefaults.standard.set(id, forKey: Self.dismissedKey)
    }

    // выход из аккаунта: следующему аккаунту на этом телефоне закрытое прежним не прячем
    func clear() {
        current = nil
        dismissedId = nil
        UserDefaults.standard.removeObject(forKey: Self.dismissedKey)
    }
}
