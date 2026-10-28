import UIKit

final class ProfileService {
    private let avatarSizes: [CGFloat] = [64, 256, 1024]   // small, medium, large

    // картинка → 3 ужатых, зашифрованных размера → upload → массив id (small,medium,large)
    func uploadAvatar(_ image: UIImage) async throws -> [String] {
        let blobs: [Data] = try avatarSizes.map { dimension in
            // бэк лимитит файл в 2 МБ — держим запас 1.5 МБ на КАЖДЫЙ размер
            guard let jpeg = image.jpegData(maxDimension: dimension, maxBytes: 1_500_000) else {
                throw ProfileCryptoError.badData
            }
            return try ProfileCrypto.encryptBlob(jpeg)
        }
        let res: UploadResponse = try await APIClient.shared.upload(
            "attachments", fileField: "files", blobs: blobs
        )
        return res.ids
    }

    // шифруем профиль + сохраняем одним PUT /me.
    // Один и тот же вызов обслуживает и онбординг (там же выставляется onboardingState=COMPLETED),
    // и последующее редактирование профиля — сервер просто перезаписывает поля.
    // avatarIds передаём ВСЕГДА полностью: сервер трактует их как новое значение массива,
    // а не как добавление, и по ним же чистит осиротевшие аватары.
    func saveProfile(firstName: String, lastName: String,
                     username: String, avatarIds: [String],
                     invitedByUsername: String? = nil) async throws {
        let profile = ProfileData(firstName: firstName, lastName: lastName)
        let encrypted = try ProfileCrypto.encrypt(profile)
        let body = CompleteProfileRequest(
            username: username,
            encryptedProfile: encrypted,
            avatarAttachmentIds: avatarIds.isEmpty ? nil : avatarIds,
            invitedByUsername: invitedByUsername
        )
        let _: CompleteProfileResponse = try await APIClient.shared.request(
            "me", method: "PUT", body: body
        )
    }
    
    func loadAvatar(from urlString: String) async throws -> UIImage {
        guard let url = URL(string: urlString) else { throw ProfileCryptoError.badData }
        let (encrypted, _) = try await URLSession.shared.data(from: url)  // прямой GET на MinIO
        let plain = try ProfileCrypto.decryptBlob(encrypted)
        guard let image = UIImage(data: plain) else { throw ProfileCryptoError.badData }
        return image
    }
}
