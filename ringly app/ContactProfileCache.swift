import SwiftUI
import Combine

// name — то, что показываем (своё имя, если задано, иначе из профиля); realName — из профиля как есть;
// alias — своё имя, если задано.
struct ResolvedContact {
    var name: String?
    var avatar: UIImage?
    var realName: String? = nil
    var alias: String? = nil
}

@MainActor
final class ContactProfileCache: ObservableObject {
    static let shared = ContactProfileCache()
    @Published private(set) var byUser: [String: ResolvedContact] = [:]

    private let users = UserService()
    private var inFlight: Set<String> = []
    private var resolved: Set<String> = []   // userId, для которых профиль реально получен (есть имя/аватар)
    private var hiResInFlight: Set<String> = []
    private var hiResDone: Set<String> = []   // userId, для которых уже догрузили крупную (large) аватарку

    // показать профиль контакта: мгновенно из БД, затем (если есть ключ и ещё не получили) — фоновый фетч с ретраем
    func ensure(_ userId: String) {
        // 1. мгновенно из SQLCipher (в т.ч. после рестарта)
        if byUser[userId] == nil, let p = ContactProfileStore.load(userId) {
            byUser[userId] = contact(userId, name: p.realName, avatar: p.avatar.flatMap(UIImage.init(data:)))
            if p.realName != nil || p.avatar != nil { resolved.insert(userId) }
        }
        // 2. фетч, только если ещё не получили и знаем Profile Key контакта.
        //    НЕ кешируем пустоту: при отсутствии ключа/ошибке — просто выходим, повторим на следующем триггере.
        guard !resolved.contains(userId), !inFlight.contains(userId), ContactKeyStore.has(userId) else { return }
        inFlight.insert(userId)
        Task {
            defer { inFlight.remove(userId) }
            guard let card = try? await users.card(userId) else { return }   // сетевой сбой → ретрай позже
            let name = users.contactName(card)
            let avatar = await users.contactAvatar(card)
            guard name != nil || avatar != nil else { return }              // ключа/профиля ещё нет → ретрай позже
            ContactProfileStore.save(userId: userId, name: name, avatar: avatar?.pngData())
            byUser[userId] = contact(userId, name: name, avatar: avatar)
            resolved.insert(userId)
        }
    }

    // для экрана профиля: догрузить КРУПНУЮ (large, 1024px) аватарку, даже если small уже закеширована.
    // Списки показывают small мгновенно; профиль заменяет её на чёткую, когда докачается.
    func ensureHighRes(_ userId: String) {
        guard !hiResDone.contains(userId), !hiResInFlight.contains(userId), ContactKeyStore.has(userId) else { return }
        hiResInFlight.insert(userId)
        Task {
            defer { hiResInFlight.remove(userId) }
            guard let card = try? await users.card(userId), card.avatars.count > 1,
                  let large = await users.contactAvatar(card, largest: true) else { return }
            hiResDone.insert(userId)
            // ⚠️ realName, а не name: name может быть своим именем, и оно записалось бы в профиль как настоящее
            let name = byUser[userId]?.realName ?? users.contactName(card)
            ContactProfileStore.save(userId: userId, name: name, avatar: large.pngData())
            byUser[userId] = contact(userId, name: name, avatar: large)
        }
    }

    // Своё имя контакта (локально). nil/пусто — вернуть имя из профиля. Сразу видно на всех экранах.
    func setAlias(_ userId: String, _ name: String?) {
        ContactProfileStore.setAlias(userId, name)
        let current = byUser[userId]
        byUser[userId] = contact(userId, name: current?.realName, avatar: current?.avatar)
    }

    private func contact(_ userId: String, name realName: String?, avatar: UIImage?) -> ResolvedContact {
        let alias = ContactProfileStore.alias(userId)

        return ResolvedContact(name: alias ?? realName, avatar: avatar, realName: realName, alias: alias)
    }

    // перезагрузить (после прихода/смены Profile Key контакта)
    func refresh(_ userId: String) {
        resolved.remove(userId)
        inFlight.remove(userId)
        hiResDone.remove(userId)
        hiResInFlight.remove(userId)
        ensure(userId)
    }
}
