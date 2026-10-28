import UIKit
import SwiftUI
import AVFoundation

// PhotosPicker отдаёт видео только как файл. Копируем его во временную папку: URL из
// представления живёт лишь на время вызова, а перекодирование занимает секунды.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("picked-\(UUID().uuidString).mov")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)

            return PickedMovie(url: copy)
        }
    }
}

// Подготовка медиа к отправке НА УСТРОЙСТВЕ. Сервер не может ни сжать, ни даже посмотреть файл —
// он получает уже зашифрованный блоб. Поэтому вся обработка здесь, до шифрования.
//
// Смысл не только в трафике: несжатое видео с современного iPhone — это десятки мегабайт за секунды
// съёмки, и без перекодирования лимит вложения выбивался бы постоянно.
enum MediaProcessor {

    // Порог, после которого отправка бессмысленна: должен совпадать с MEDIA_MAX_BYTES на сервере
    // (25 МБ). Проверяем на клиенте, чтобы не гонять байты впустую и дать понятную ошибку.
    static let maxBytes = 25 * 1024 * 1024

    static let maxImageDimension: CGFloat = 1600   // длинная сторона фото
    static let thumbDimension: CGFloat = 200       // миниатюра в payload

    // Потолок длительности видео. Взят из арифметики: 720p H.264 даёт ~2.5–4 Мбит/с, то есть
    // 0.3–0.5 МБ/с, и в 25 МБ гарантированно укладывается около минуты. Проверяется ДО обработки.
    static let maxVideoSeconds: Double = 60

    struct Prepared {
        let data: Data
        let mime: String
        let width: Int
        let height: Int
        let durationMs: Int?
        let thumbBase64: String?
    }

    // ---- фото ----

    static func prepareImage(_ image: UIImage) throws -> Prepared {
        let scaled = downscale(image, maxDimension: maxImageDimension)
        guard let jpeg = scaled.jpegData(compressionQuality: 0.8) else { throw MediaError.unsupported }
        guard jpeg.count <= maxBytes else { throw MediaError.tooLarge }

        return Prepared(
            data: jpeg,
            mime: "image/jpeg",
            width: Int(scaled.size.width),
            height: Int(scaled.size.height),
            durationMs: nil,
            thumbBase64: thumbnail(from: scaled))
    }

    // ---- видео ----

    // Перекодируем в 720p H.264/AAC. AVAssetExportSession сам решает битрейт под пресет —
    // ручная настройка потребовала бы AVAssetWriter и заметно больше кода ради малого выигрыша.
    static func prepareVideo(at source: URL) async throws -> Prepared {
        let asset = AVURLAsset(url: source)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString).mp4")

        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else {
            throw MediaError.unsupported
        }

        // Отсекаем заведомо неподъёмное ДО перекодирования. Иначе пользователь ждёт минуту обработки
        // и только потом узнаёт, что файл не пролезет — худший из возможных порядков.
        //
        // Размер исходника предсказателем НЕ является: перекодирование в 720p уменьшает его в разы.
        // Предсказывает длительность — на выходе получается примерно постоянный битрейт.
        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds > maxVideoSeconds {
                throw MediaError.videoTooLong(seconds: Int(seconds))
            }
        }

        // Уточняющая проверка: система умеет оценить размер до запуска. Она точнее прикидки по
        // длительности, но доступна не всегда — поэтому идёт вторым эшелоном, а не вместо неё.
        if let estimate = try? await export.estimatedOutputFileLengthInBytes, estimate > Int64(maxBytes) {
            throw MediaError.tooLarge
        }
        export.outputURL = output
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true    // moov-атом в начало: видео играется до докачки
        // Метаданные оригинала не отправляем, как Signal и Telegram: по умолчанию экспорт копирует их
        // целиком, а там место съёмки (геолокация), дата, модель телефона. Шифрование прячет их от
        // сервера, но не от получателя. У фото они и так теряются при пересжатии.
        //
        // ⚠️ Проверено экспериментом (экспорт видео с геолокацией, датой и моделью):
        //  • `metadata = []` экспорт молча считает «как у исходника» — уходит ВСЁ, включая место съёмки;
        //  • один `metadataItemFilter = .forSharing()` убирает место, но оставляет дату съёмки;
        //  • непустой список (одна нейтральная запись) + фильтр — на выходе метаданных нет вовсе.
        let placeholder = AVMutableMetadataItem()
        placeholder.keySpace = .quickTimeMetadata
        placeholder.key = "com.apple.quicktime.software" as NSString
        placeholder.value = "Ringly" as NSString
        export.metadata = [placeholder]
        export.metadataItemFilter = .forSharing()

        await export.export()
        guard export.status == .completed else { throw MediaError.unsupported }

        let data = try Data(contentsOf: output)
        try? FileManager.default.removeItem(at: output)
        guard data.count <= maxBytes else { throw MediaError.tooLarge }

        let duration = try? await asset.load(.duration)
        let track = try? await asset.loadTracks(withMediaType: .video).first
        let size = await displaySize(track) ?? .zero

        return Prepared(
            data: data,
            mime: "video/mp4",
            width: Int(abs(size.width)),
            height: Int(abs(size.height)),
            durationMs: duration.map { Int(CMTimeGetSeconds($0) * 1000) },
            thumbBase64: await videoThumbnail(asset: asset))
    }

    // ---- быстрые превью для оптимистичного бабла ----
    // Считаются ДО тяжёлой обработки, чтобы сообщение появилось в ленте сразу. Возвращают заготовку
    // MediaRef без серверных полей — она живёт только локально до окончания заливки.

    static func quickImagePreview(_ image: UIImage) -> MediaRef {
        let scaled = downscale(image, maxDimension: maxImageDimension)

        return .pending(mime: "image/jpeg",
                        width: Int(scaled.size.width), height: Int(scaled.size.height),
                        thumb: thumbnail(from: scaled))
    }

    static func quickVideoPreview(at url: URL) async -> MediaRef {
        let asset = AVURLAsset(url: url)
        let track = try? await asset.loadTracks(withMediaType: .video).first
        let size = await displaySize(track) ?? CGSize(width: 1280, height: 720)

        return .pending(mime: "video/mp4",
                        width: Int(abs(size.width)), height: Int(abs(size.height)),
                        thumb: await videoThumbnail(asset: asset))
    }

    // ---- вспомогательное ----

    private static func downscale(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        return UIGraphicsImageRenderer(size: target).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    // Миниатюра едет ВНУТРИ сообщения, поэтому она должна быть по-настоящему маленькой:
    // качество 0.5 при 200px даёт ~5 КБ. Раздувать payload нельзя — он идёт через очередь доставки.
    private static func thumbnail(from image: UIImage) -> String? {
        downscale(image, maxDimension: thumbDimension)
            .jpegData(compressionQuality: 0.5)?
            .base64EncodedString()
    }

    // Размер кадра таким, каким его видит зритель. ⚠️ `naturalSize` — размер ДО поворота: iPhone
    // пишет вертикальное видео как 1920×1080 с пометкой «повернуть на 90°». Без учёта поворота
    // вертикальное видео считалось горизонтальным — широкий бабл в чате и рамки по бокам в просмотрщике.
    private static func displaySize(_ track: AVAssetTrack?) async -> CGSize? {
        guard let track,
              let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
        let r = CGRect(origin: .zero, size: size).applying(transform)

        return CGSize(width: abs(r.width), height: abs(r.height))
    }

    private static func videoThumbnail(asset: AVAsset) async -> String? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true      // иначе кадр приедет повёрнутым
        generator.maximumSize = CGSize(width: thumbDimension * 2, height: thumbDimension * 2)

        guard let cg = try? await generator.image(at: .zero).image else { return nil }

        return thumbnail(from: UIImage(cgImage: cg))
    }
}
