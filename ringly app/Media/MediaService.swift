import Foundation
import UIKit

// Отправка и получение медиа. Крипта — MediaCrypto (одноразовый ключ), хранение — MediaStore.
//
// Инвариант: НА СЕРВЕР УХОДИТ ТОЛЬКО ШИФРТЕКСТ. Ключ генерируется здесь, кладётся в MediaRef и
// уезжает внутри E2EE-сообщения. Сервер, у которого лежит блоб, расшифровать его не может —
// гарантия ровно та же, что у текстового сообщения.
final class MediaService {

    // ---- отправка ----

    // Готовит файл (сжатие/перекодирование), шифрует, заливает. Возвращает описание для payload.
    func upload(_ prepared: MediaProcessor.Prepared) async throws -> MediaRef {
        let sealed = try MediaCrypto.seal(prepared.data)

        let resp: MediaUploadResponse = try await APIClient.shared.upload(
            "media", fileField: "file", blobs: [sealed.blob])

        // Кладём СВОЙ файл в локальное хранилище сразу: отправитель не должен качать обратно то,
        // что только что отправил, а после серверного TTL это стало бы и невозможно.
        _ = try? MediaStore.write(prepared.data, attachmentId: resp.attachmentId,
                                  ext: prepared.mime.hasPrefix("video/") ? "mp4" : "jpg")

        return MediaRef(
            attachmentId: resp.attachmentId,
            key: sealed.keyBase64,
            sha256: sealed.sha256Base64,
            mime: prepared.mime,
            width: prepared.width,
            height: prepared.height,
            bytes: prepared.data.count,
            durationMs: prepared.durationMs,
            thumb: prepared.thumbBase64)
    }

    // ---- получение ----

    // Локальный файл: из хранилища мгновенно, иначе скачать → проверить → расшифровать → сохранить.
    // nil = получить не удалось (нет сети, или серверный TTL истёк и блоба больше нет).
    @discardableResult
    func localFile(for ref: MediaRef) async -> URL? {
        let ext = ref.fileExtension
        if MediaStore.exists(ref.attachmentId, ext: ext) {
            return MediaStore.file(ref.attachmentId, ext: ext)
        }

        do {
            let signed: MediaUrlResponse = try await APIClient.shared.request("media/\(ref.attachmentId)/url")
            guard let url = URL(string: signed.url) else { return nil }

            let (blob, resp) = try await URLSession.shared.data(from: url)   // прямой GET на storage
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }

            let plain = try MediaCrypto.open(blob: blob, keyBase64: ref.key, sha256Base64: ref.sha256)

            return try MediaStore.write(plain, attachmentId: ref.attachmentId, ext: ext)
        } catch {
            print("🖼 медиа не получено (\(ref.attachmentId.prefix(8))):", error)

            return nil
        }
    }

    // Миниатюра из payload — доступна всегда, без сети и без скачивания оригинала
    // ⚠️ С кешем: миниатюра — base64-JPEG внутри payload, и без кеша её декодировали заново на КАЖДОЙ
    // перерисовке ленты (у каждого видимого медиа и у каждой цитаты на медиа). Это одна из причин
    // рывков анимаций в чате. Ключ — attachmentId: у заготовки во время заливки он пустой, а
    // миниатюра ещё может появиться, поэтому такие не кешируем.
    static func thumbnail(_ ref: MediaRef) -> UIImage? {
        guard let raw = ref.thumb else { return nil }
        let key = ref.attachmentId as NSString
        if !ref.attachmentId.isEmpty, let hit = thumbCache.object(forKey: key) { return hit }
        guard let data = Data(base64Encoded: raw), let image = UIImage(data: data) else { return nil }
        if !ref.attachmentId.isEmpty { thumbCache.setObject(image, forKey: key) }

        return image
    }

    private static let thumbCache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 300
        return c
    }()
}
