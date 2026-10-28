import Foundation
import AVFoundation

// Обработка мелодии кастомного гудка НА КЛИЕНТЕ (до аплоада): трим до 45с, пик-нормализация
// громкости, кодирование в AAC (ровно 128 kbps, .m4a). Сервер хранит блоб как есть (plaintext, §2а)
// и валидирует только размер — вся обработка здесь.
enum RingbackStudio {

    enum StudioError: LocalizedError {
        case noAudioTrack, exportFailed(String), empty
        var errorDescription: String? {
            switch self {
            case .noAudioTrack:        return L("В файле нет аудиодорожки")
            case .exportFailed(let m): return "Не удалось обработать аудио: \(m)"
            case .empty:               return L("Пустой результат обработки")
            }
        }
    }

    // Файл берём любой длины, но храним первые 45 с — ровно столько длится дозвон
    // (CALL_RING_TIMEOUT_SECONDS на сервере): дальше звонящий всё равно не услышит, а лишние
    // мегабайты не успели бы скачаться за 8 с ожидания в RingbackPlayer. 45 с × 128 кбит/с ≈ 720 КБ.
    static let maxDuration: Double = 45.0
    private static let targetPeak: Float = 0.89   // ≈ −1 dBFS headroom (не клипует)
    private static let maxGain: Float = 12.0      // не разгонять почти-тишину в шум

    // Вход — локальный URL mp3 (View уже скопировал файл из пикера в tmp под security-scope).
    // Выход — байты .m4a, готовые к uploadAudio.
    // `start` — начало фрагмента, выбранное в редакторе (RingbackTrimView); по умолчанию — с начала.
    static func process(inputURL: URL, start: Double = 0) async throws -> Data {
        let asset = AVURLAsset(url: inputURL)

        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw StudioError.noAudioTrack }

        let assetDuration = CMTimeGetSeconds(try await asset.load(.duration))
        let from = max(0, min(start, assetDuration - maxDuration))   // фрагмент не вылезает за конец
        let durSec = min(maxDuration, assetDuration - from)
        let timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 44100),
                                    duration: CMTime(seconds: durSec, preferredTimescale: 44100))

        // 1) пик по первым ≤45с → коэффициент нормализации
        let peak = try await measurePeak(asset: asset, track: track, timeRange: timeRange)
        let gain: Float = peak > 0.0001 ? min(maxGain, targetPeak / peak) : 1.0

        // 2) трим + громкость + AAC с ЯВНЫМ битрейтом. Пресет AppleM4A битрейт не фиксирует: на
        //    настоящей музыке 30 с выходили больше серверного лимита (на тестовом тоне — нет).
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ringback-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: outURL) }

        try await encode(asset: asset, track: track, timeRange: timeRange, gain: gain, to: outURL)

        let data = try Data(contentsOf: outURL)
        guard !data.isEmpty else { throw StudioError.empty }

        return data
    }

    // ===== волна для редактора фрагмента =====

    struct Waveform {
        let duration: Double
        let peaks: [Float]          // 0…1, громкость на каждые `1 / perSecond` секунды
        static let perSecond = 8    // с запасом: столбики на экране собираются из нескольких
    }

    // Громкость всего трека — для рисования волны. Читаем моно 8 кГц: точности хватает с запасом,
    // а 5-минутная песня разбирается за доли секунды. nonisolated — в фоне, не на главном.
    // Средняя громкость (RMS), а не пик: пики рисовали частокол острых игл, RMS — «тело» музыки.
    nonisolated static func waveform(of url: URL) async throws -> Waveform {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw StudioError.noAudioTrack }
        let duration = CMTimeGetSeconds(try await asset.load(.duration))

        let reader = try AVAssetReader(asset: asset)
        let rate = 8_000
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        guard reader.canAdd(output) else { throw StudioError.exportFailed("reader не принял выход") }
        reader.add(output)
        guard reader.startReading() else {
            throw StudioError.exportFailed(reader.error?.localizedDescription ?? "startReading")
        }

        let bucket = rate / Waveform.perSecond
        var peaks: [Float] = []
        peaks.reserveCapacity(Int(duration) * Waveform.perSecond + 1)
        var sumSquares: Double = 0
        var filled = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = Data(count: length)
            data.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for s in raw.bindMemory(to: Int16.self) {
                    let v = Double(s) / 32768
                    sumSquares += v * v
                    filled += 1
                    if filled == bucket {
                        peaks.append(Float((sumSquares / Double(filled)).squareRoot()))
                        sumSquares = 0; filled = 0
                    }
                }
            }
            CMSampleBufferInvalidate(sample)
        }
        if filled > 0 { peaks.append(Float((sumSquares / Double(filled)).squareRoot())) }
        if reader.status == .failed {
            throw StudioError.exportFailed(reader.error?.localizedDescription ?? "reader failed")
        }

        // к самому громкому месту трека — иначе тихая запись рисовалась бы ровной ниткой; степень
        // < 1 приподнимает тихие места, чтобы куплет не терялся рядом с громким припевом
        let top = peaks.max() ?? 0
        let normalized = top > 0 ? peaks.map { pow($0 / top, 0.7) } : peaks
        return Waveform(duration: duration, peaks: normalized)
    }

    // 128 кбит/с × 45 с ≈ 720 КБ — с запасом в RINGBACK_MAX_BYTES (1 МБ) на сервере
    private static let bitRate = 128_000
    private static let sampleRate = 44_100

    // PCM из AVAssetReaderAudioMixOutput (он же применяет громкость и приводит к 44.1 кГц / стерео) →
    // AVAssetWriter с AAC. nonisolated: колбэк writer'а крутится на своей очереди, не на главной.
    nonisolated private static func encode(asset: AVAsset, track: AVAssetTrack, timeRange: CMTimeRange,
                                           gain: Float, to outURL: URL) async throws {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = timeRange

        let mix = AVMutableAudioMix()
        let params = AVMutableAudioMixInputParameters(track: track)
        params.setVolume(gain, at: .zero)
        mix.inputParameters = [params]

        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.audioMix = mix
        guard reader.canAdd(output) else { throw StudioError.exportFailed("reader не принял выход") }
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: outURL, fileType: .m4a)
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: bitRate,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw StudioError.exportFailed("writer не принял вход") }
        writer.add(input)

        guard reader.startReading() else {
            throw StudioError.exportFailed(reader.error?.localizedDescription ?? "startReading")
        }
        guard writer.startWriting() else {
            throw StudioError.exportFailed(writer.error?.localizedDescription ?? "startWriting")
        }
        writer.startSession(atSourceTime: timeRange.start)

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "ringback.encode")) {
                while input.isReadyForMoreMediaData {
                    guard let buffer = output.copyNextSampleBuffer(), input.append(buffer) else {
                        // конец данных или сбой записи — причину разберём по статусам ниже
                        input.markAsFinished()
                        done.resume()
                        return
                    }
                }
            }
        }

        if reader.status == .failed {
            writer.cancelWriting()
            throw StudioError.exportFailed(reader.error?.localizedDescription ?? "reader failed")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw StudioError.exportFailed(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
    }

    // Максимальная амплитуда (|sample|/32768) по первым ≤45с — один потоковый проход Int16 PCM.
    private static func measurePeak(asset: AVAsset, track: AVAssetTrack, timeRange: CMTimeRange) async throws -> Float {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = timeRange

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        guard reader.canAdd(output) else { throw StudioError.exportFailed("reader не принял выход") }
        reader.add(output)
        guard reader.startReading() else {
            throw StudioError.exportFailed(reader.error?.localizedDescription ?? "startReading")
        }

        var peak: Int16 = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = Data(count: length)
            data.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                               destination: raw.baseAddress!)
            }
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let samples = raw.bindMemory(to: Int16.self)
                for s in samples {
                    let a = s == Int16.min ? Int16.max : abs(s)   // защита от abs(Int16.min)
                    if a > peak { peak = a }
                }
            }
            CMSampleBufferInvalidate(sample)
        }

        if reader.status == .failed {
            throw StudioError.exportFailed(reader.error?.localizedDescription ?? "reader failed")
        }

        return Float(peak) / 32768.0
    }
}
