import Photos

// Сохранение медиа из переписки в системную медиатеку.
//
// Запрашиваем режим .addOnly, а не полный доступ: приложению нужно только положить файл, читать
// чужую библиотеку незачем. iOS показывает для этого более мягкий запрос, и Apple прямо рекомендует
// узкий режим там, где чтение не требуется.
enum MediaSaver {
    enum Result { case saved, denied, failed }

    static func saveToPhotos(url: URL, isVideo: Bool) async -> Result {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            Task { @MainActor in CallDiag.log("💾 сохранение в «Фото»: нет доступа (status=\(status.rawValue))") }
            return .denied
        }

        // ⚠️ Отдаём медиатеке не наш файл, а данные (фото) или КОПИЮ во временной папке (видео).
        // Медиатеку ведёт отдельный системный процесс, и файл из Application Support приложения
        // он читал не всегда — сохранение молча проваливалось. Временная папка и байты в памяти
        // работают надёжно.
        var tempCopy: URL?
        defer { if let tempCopy { try? FileManager.default.removeItem(at: tempCopy) } }

        do {
            if isVideo {
                let copy = FileManager.default.temporaryDirectory
                    .appendingPathComponent("save-\(UUID().uuidString).mp4")
                try FileManager.default.copyItem(at: url, to: copy)
                tempCopy = copy
            }
            let photoData = isVideo ? nil : try Data(contentsOf: url)

            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                // ⚠️ Дата — «сейчас», как у любого только что сохранённого. Видео при отправке
                // перекодируется С метаданными оригинала, включая дату съёмки, и медиатека ставила его
                // на ту дату — глубоко в ленту: «Сохранено», а в конце медиатеки видео нет. У фото
                // метаданные теряются при пересжатии, поэтому они и так вставали в конец.
                request.creationDate = Date()
                if let tempCopy {
                    request.addResource(with: .video, fileURL: tempCopy, options: nil)
                } else if let photoData {
                    request.addResource(with: .photo, data: photoData, options: nil)
                }
            }

            return .saved
        } catch {
            // Пишем в журнал (служебное меню → «Журнал звонков»): на телефоне видео не сохранялось, а в
            // симуляторе то же видео сохраняется — причину видно только по коду ошибки с устройства.
            let ns = error as NSError
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
            let head = (try? FileHandle(forReadingFrom: url)).flatMap { try? $0.read(upToCount: 12) }
                .map { $0.map { String(format: "%02x", $0) }.joined() } ?? "?"
            let line = "💾 сохранение в «Фото» не удалось: video=\(isVideo) \(ns.domain) \(ns.code) "
                + "\(ns.localizedDescription) | файл \(url.pathExtension) \(size) байт, начало \(head)"
            print(line)
            Task { @MainActor in CallDiag.log(line) }

            return .failed
        }
    }
}
