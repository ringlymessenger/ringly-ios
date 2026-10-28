import UIKit

final class UserService {
    func findByUsername(_ username: String) async throws -> UserLookupResponse {
        let clean = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return try await APIClient.shared.request("users/by-username/\(clean)")
    }

    func card(_ userId: String) async throws -> UserCardResponse {
        try await APIClient.shared.request("users/\(userId)")
    }

    // имя контакта (если есть его Profile Key) — иначе nil → UI покажет @username
    func contactName(_ card: UserCardResponse) -> String? {
        guard let enc = card.encryptedProfile, let key = ContactKeyStore.key(for: card.userId),
              let p = ContactCrypto.decryptProfile(enc, key: key) else { return nil }
        let full = "\(p.firstName) \(p.lastName)".trimmingCharacters(in: .whitespaces)
        return full.isEmpty ? nil : full
    }

    // аватар контакта: скачать зашифрованный блоб по presigned-ссылке → расшифровать его ключом.
    // largest=false → small (64px, быстро для списков); largest=true → large (1024px, чёткая для профиля).
    func contactAvatar(_ card: UserCardResponse, largest: Bool = false) async -> UIImage? {
        let item = largest ? card.avatars.last : card.avatars.first
        guard let item, let key = ContactKeyStore.key(for: card.userId),
              let url = URL(string: item.url) else { return nil }
        guard let (enc, _) = try? await URLSession.shared.data(from: url),
              let plain = ContactCrypto.decryptBlob(enc, key: key),
              let img = UIImage(data: plain) else { return nil }
        return img
    }
}
