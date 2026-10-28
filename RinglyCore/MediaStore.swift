import Foundation
import CryptoKit

// Локальное хранилище медиа сообщений — ОСНОВНАЯ и единственная долговременная копия.
//
// Модель как у Signal: сервер держит зашифрованный блоб только до доставки (TTL), потом удаляет.
// Расшифрованный файл живёт здесь, у получателя на устройстве. Отсюда два следствия, которые надо
// держать в голове при любых правках:
//   1. Удалил файл отсюда после истечения серверного TTL — он потерян навсегда.
//   2. Потерял устройство без бэкапа — потеряно всё медиа. Осознанный размен, см. docs/media.md
//
// Каталог в Application Support, а НЕ в Caches: система вправе вычистить Caches под давлением места,
// а для нас это не кеш, а первоисточник.
enum MediaStore {
    static var dir: URL {
        var base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("media", isDirectory: true)
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

            // ИСКЛЮЧАЕМ ИЗ БЭКАПА iCloud — осознанно, как делает Signal.
            // Здесь лежат РАСШИФРОВАННЫЕ файлы. Резервная копия iCloud шифруется ключами Apple
            // (если у пользователя не включена Advanced Data Protection), то есть попадание туда
            // означало бы, что копия медиа доступна Apple — а обещано «защищено как текст».
            // Цена решения: при восстановлении телефона из бэкапа медиа не вернётся. См. docs/media.md
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? base.setResourceValues(values)
        }

        return base
    }

    // attachmentId — серверный uuid; подстраховываемся, чтобы он не смог стать путём
    static func file(_ attachmentId: String, ext: String) -> URL {
        let safe = attachmentId.replacingOccurrences(of: "/", with: "_")

        return dir.appendingPathComponent("\(safe).\(ext)")
    }

    static func exists(_ attachmentId: String, ext: String) -> Bool {
        FileManager.default.fileExists(atPath: file(attachmentId, ext: ext).path)
    }

    static func write(_ data: Data, attachmentId: String, ext: String) throws -> URL {
        let url = file(attachmentId, ext: ext)
        try data.write(to: url, options: .atomic)

        return url
    }

    static func remove(_ attachmentId: String, ext: String) {
        try? FileManager.default.removeItem(at: file(attachmentId, ext: ext))
    }

    // Суммарный размер — для экрана «Хранилище»
    static func totalBytes() -> Int64 {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }

        return items.reduce(Int64(0)) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

            return sum + Int64(size)
        }
    }

    static func wipe() {
        try? FileManager.default.removeItem(at: dir)
    }
}

// Шифрование вложения ОДНОРАЗОВЫМ ключом. Не Profile Key: тот привязан к владельцу, а вложение
// должен прочитать собеседник. Ровно та же схема, что уже работает в history-sync для архива.
enum MediaCrypto {
    struct Sealed {
        let blob: Data          // то, что уходит на сервер (непрозрачно для него)
        let keyBase64: String   // едет ВНУТРИ E2EE-сообщения
        let sha256Base64: String
    }

    static func seal(_ plaintext: Data) throws -> Sealed {
        let key = SymmetricKey(size: .bits256)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let blob = sealed.combined else { throw MediaError.encryptionFailed }

        return Sealed(
            blob: blob,
            keyBase64: key.withUnsafeBytes { Data($0) }.base64EncodedString(),
            sha256Base64: Data(SHA256.hash(data: plaintext)).base64EncodedString())
    }

    // Возвращает расшифрованные байты. sha256 сверяем ДО отдачи наружу: подменённый на сервере блоб
    // не должен доехать до UI, даже если он корректно расшифровался.
    static func open(blob: Data, keyBase64: String, sha256Base64: String) throws -> Data {
        guard let keyData = Data(base64Encoded: keyBase64) else { throw MediaError.badKey }
        let box = try AES.GCM.SealedBox(combined: blob)
        let plain = try AES.GCM.open(box, using: SymmetricKey(data: keyData))

        guard Data(SHA256.hash(data: plain)).base64EncodedString() == sha256Base64 else {
            throw MediaError.checksumMismatch
        }

        return plain
    }
}

enum MediaError: Error {
    case encryptionFailed
    case badKey
    case checksumMismatch
    case tooLarge
    case videoTooLong(seconds: Int)
    case unsupported
}
