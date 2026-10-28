import Foundation
import AVFoundation

// Кастомный гудок (Ringback): мелодия ВЫЗЫВАЕМОГО, которую звонящий играет локально во время
// дозвона вместо стандартных гудков. Метаданные (attachmentId + presigned URL) приходят в
// call_initiated; блоб — plaintext AAC ≤45с (обработан клиентом владельца), кэшируется по
// attachmentId (сменил мелодию → сменился id → кэш сам инвалидировался).
//
// ⚠️ Аудио-инварианты звонков (ios-calls.md): как и CallSounds, играем через AVAudioPlayer поверх
// УЖЕ сконфигурированной сессии звонка; категорию/isAudioEnabled НЕ трогаем. Оркестрацией
// (когда стартовать/стопать, гонки callId/phase) занимается CallManager.
@MainActor
final class RingbackPlayer {
    static let shared = RingbackPlayer()
    private init() {}

    private var player: AVAudioPlayer?
    private var fetchTask: Task<URL?, Never>?

    private static let maxCached = 20                    // LRU-потолок кэша мелодий
    private static let downloadTimeout: TimeInterval = 8 // дольше качать нет смысла — дозвон ограничен 45с

    // == кэш ==

    private static var cacheDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ringbacks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cacheFile(_ attachmentId: String) -> URL {
        // attachmentId — серверный uuid; на всякий случай не даём ему стать путём
        cacheDir.appendingPathComponent(attachmentId.replacingOccurrences(of: "/", with: "_") + ".m4a")
    }

    // Вернуть локальный файл мелодии: из кэша мгновенно, иначе скачать (таймаут 8с).
    // nil = не получилось (звонящий остаётся на обычных гудках).
    func fetch(attachmentId: String, urlString: String) async -> URL? {
        let file = Self.cacheFile(attachmentId)
        if FileManager.default.fileExists(atPath: file.path) {
            // touch для LRU
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            return file
        }

        guard let url = URL(string: urlString) else { return nil }
        fetchTask?.cancel()
        let task = Task<URL?, Never> {
            var req = URLRequest(url: url)
            req.timeoutInterval = Self.downloadTimeout
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  !data.isEmpty, !Task.isCancelled else { return nil }
            do {
                try data.write(to: file, options: .atomic)
            } catch {
                CallDiag.log("🎵 ringback: не записался кэш — \(error.localizedDescription)")
                return nil
            }
            Self.pruneCache()
            return file
        }
        fetchTask = task
        return await task.value
    }

    // == плеер ==

    // играть мелодию лупом (файл ≤45с = длине дозвона; короткий — по кругу). false → вызывающий оставляет гудки
    @discardableResult
    func play(_ file: URL) -> Bool {
        stop()
        do {
            let p = try AVAudioPlayer(contentsOf: file)
            p.numberOfLoops = -1
            p.volume = 1.0
            guard p.play() else { return false }
            player = p
            return true
        } catch {
            // битый/неигр/имый файл (злонамеренный аплоад владельца) — чистим кэш, играем гудки
            CallDiag.log("🎵 ringback: файл не играется — \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: file)
            return false
        }
    }

    var isPlaying: Bool { player?.isPlaying == true }

    func stop() {
        fetchTask?.cancel()
        fetchTask = nil
        player?.stop()
        player = nil
    }

    // LRU-чистка кэша (без обращения к сети/серверу)
    private static func pruneCache() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        guard files.count > maxCached else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
        for f in sorted.prefix(files.count - maxCached) { try? fm.removeItem(at: f) }
    }
}
