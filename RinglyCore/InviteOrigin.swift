import Foundation

// Кто пригласил: ник из инвайт-ссылки, по которой пришёл новый пользователь.
//
// Зачем хранить, а не отправить сразу: ссылку открывают ДО входа в аккаунт (приложение ставят
// именно по ней), а передать ник можно только вместе с профилем — в `PUT /me` на последнем шаге
// онбординга. Между этими двумя моментами — вход через Google/Apple и два экрана регистрации.
//
// Сервер принимает ребро графа доверия ровно один раз, при первом прохождении онбординга
// (MeService.resolveInviter, relay-daemon.md §6а). Поэтому после успешной отправки значение гасим:
// иначе при следующем редактировании профиля клиент слал бы уже бессмысленный ник.
//
// Хранится в обычном UserDefaults, а не в App Group: расширению уведомлений это не нужно.
public enum InviteOrigin {
    private static let key = "invite.origin.username"

    // Побеждает ПОСЛЕДНЯЯ ссылка: если до регистрации открыли несколько приглашений, пригласившим
    // считаем того, с чьей ссылки пользователь в итоге пришёл регистрироваться.
    public static func remember(_ username: String) {
        UserDefaults.standard.set(username, forKey: key)
    }

    public static var pending: String? {
        UserDefaults.standard.string(forKey: key)
    }

    public static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
