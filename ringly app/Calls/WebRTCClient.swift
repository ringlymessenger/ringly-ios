import Foundation
import AVFoundation
import WebRTC

// Обёртка над RTCPeerConnection: локальные audio/video дорожки, offer/answer, ICE, mute/speaker.
// Медиа идёт P2P — здесь только установка соединения и дорожек.
final class WebRTCClient: NSObject {

    // одна фабрика на процесс
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    let isVideo: Bool
    private var pc: RTCPeerConnection?
    private var localAudioTrack: RTCAudioTrack?
    private(set) var localVideoTrack: RTCVideoTrack?
    private(set) var remoteVideoTrack: RTCVideoTrack?
    private var videoCapturer: RTCCameraVideoCapturer?

    var onLocalIce: ((RTCIceCandidate) -> Void)?
    var onRemoteVideoTrack: ((RTCVideoTrack) -> Void)?
    var onStateChange: ((RTCIceConnectionState) -> Void)?

    init(iceServers: [RTCIceServer], isVideo: Bool, relayOnly: Bool = false) {
        self.isVideo = isVideo
        super.init()

        let config = RTCConfiguration()
        config.iceServers = iceServers
        config.sdpSemantics = .unifiedPlan
        // relayOnly → в наш SDP попадают ТОЛЬКО relay-кандидаты, host/srflx не публикуются,
        // поэтому собеседник не узнаёт наш IP (см. CallSettings.relayOnly)
        config.iceTransportPolicy = relayOnly ? .relay : .all
        config.continualGatheringPolicy = .gatherContinually
        // держим пул заранее собранных кандидатов: ускоряет первый коннект и ICE-рестарт
        config.iceCandidatePoolSize = 1
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        pc = WebRTCClient.factory.peerConnection(with: config, constraints: constraints, delegate: self)

        createMediaSenders()
    }

    // ---- медиа-дорожки ----
    private func createMediaSenders() {
        let streamId = "ringly0"

        let audioSource = WebRTCClient.factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let audio = WebRTCClient.factory.audioTrack(with: audioSource, trackId: "audio0")
        pc?.add(audio, streamIds: [streamId])
        localAudioTrack = audio

        if isVideo {
            let videoSource = WebRTCClient.factory.videoSource()
            videoCapturer = RTCCameraVideoCapturer(delegate: videoSource)
            allowCameraInBackground()
            let video = WebRTCClient.factory.videoTrack(with: videoSource, trackId: "video0")
            pc?.add(video, streamIds: [streamId])
            localVideoTrack = video
            startCapture()
        }

        applyBitratePolicy()
    }

    // Приоритет аудио над видео. WebRTC сам душит битрейт при заторе (GCC/transport-cc), но БЕЗ
    // явных приоритетов видео выедает весь бюджет узкого канала и разговор начинает рваться —
    // это и есть «лагает при плохом интернете». Здесь задаём, чем жертвовать первым.
    // Вызывается и после setLocalDescription: до согласования у sender'а может не быть encodings.
    private func applyBitratePolicy() {
        guard let pc else { return }
        for sender in pc.senders {
            guard let kind = sender.track?.kind else { continue }
            let params = sender.parameters
            guard !params.encodings.isEmpty else { continue }

            if kind == "audio" {
                for e in params.encodings {
                    e.networkPriority = .high      // DSCP-маркировка: голос вперёд в очередях сети
                    e.bitratePriority = 4.0        // вчетверо больший вес при делёжке полосы (дефолт 1.0)
                }
            } else {
                for e in params.encodings {
                    e.networkPriority = .low
                    e.maxBitrateBps = NSNumber(value: Self.videoMaxBitrate)   // потолок: 640x480 больше не нужно
                }
                // при нехватке полосы роняем разрешение, но держим плавность:
                // дёрганая картинка читается как «лагает», мыльная — терпимо
                params.degradationPreference = NSNumber(value: RTCDegradationPreference.maintainFramerate.rawValue)
            }
            sender.parameters = params
        }
    }

    private static let videoMaxBitrate = 800_000   // бит/с

    // Камера не гаснет, когда приложение свёрнуто в «картинку в картинке» (CallPiP): иначе iOS
    // останавливает захват при уходе в фон, и собеседник видел бы застывший кадр.
    // На iOS 18+ это разрешено приложениям для звонков с фоновым режимом `voip` (он у нас есть).
    // На iOS 16–17 для iPhone нужен entitlement com.apple.developer.avfoundation.multitasking-camera-access,
    // который выдаёт Apple по запросу; без него `isMultitaskingCameraAccessSupported` == false и камера
    // в фоне просто останавливается, как раньше.
    private func allowCameraInBackground() {
        guard let session = videoCapturer?.captureSession else { return }
        if #available(iOS 16.0, *), session.isMultitaskingCameraAccessSupported {
            session.beginConfiguration()
            session.isMultitaskingCameraAccessEnabled = true
            session.commitConfiguration()
        }
    }

    // переключить фронтальную ↔ основную камеру во время видеозвонка (локально; трек тот же, пир видит новую картинку)
    private(set) var usingFrontCamera = true
    func switchCamera() {
        usingFrontCamera.toggle()
        startCapture()   // перезапуск захвата с камерой новой позиции (RTCCameraVideoCapturer сам остановит прежнюю)
    }

    private func startCapture() {
        guard let capturer = videoCapturer else { return }
        let position: AVCaptureDevice.Position = usingFrontCamera ? .front : .back
        guard let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == position })
                ?? RTCCameraVideoCapturer.captureDevices().first else { return }
        // формат ~640x480 и максимально доступный fps (до 30)
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let format = formats.min(by: { f1, f2 in
            let d1 = CMVideoFormatDescriptionGetDimensions(f1.formatDescription)
            let d2 = CMVideoFormatDescriptionGetDimensions(f2.formatDescription)
            return abs(Int(d1.width) - 640) < abs(Int(d2.width) - 640)
        }) ?? formats.first
        guard let format else { return }
        let fps = format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 30
        capturer.startCapture(with: device, format: format, fps: Int(min(fps, 30)))
    }

    // ---- offer / answer ----
    // ⚠️ SDP правим ДО setLocalDescription и отдаём наружу уже правленый: пир должен получить ровно
    // то, что мы себе установили. Параметры Opus (ptime/DTX/FEC) описывают, что мы хотим ПОЛУЧАТЬ,
    // то есть управляют кодировщиком собеседника — см. AudioSdp.
    func offer() async throws -> RTCSessionDescription {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let sdp = AudioSdp.tuned(try await pc!.offer(for: constraints))
        try await pc!.setLocalDescription(sdp)
        applyBitratePolicy()
        return sdp
    }

    func answer() async throws -> RTCSessionDescription {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let sdp = AudioSdp.tuned(try await pc!.answer(for: constraints))
        try await pc!.setLocalDescription(sdp)
        applyBitratePolicy()
        return sdp
    }

    // ICE-рестарт: свежие ICE-креды (ufrag/pwd) + пересбор кандидатов с нуля.
    // Ключевое свойство: медиа продолжает идти по СТАРОМУ пути, пока новый не поднимется, —
    // при удачном исходе пользователь разрыва не слышит вообще.
    // Отдаём offer наружу: он уезжает пиру по обычному E2EE-каналу сигналинга, как первичный.
    func offerWithIceRestart() async throws -> RTCSessionDescription {
        pc?.restartIce()
        return try await offer()
    }

    func setRemote(_ sdp: RTCSessionDescription) async throws {
        try await pc!.setRemoteDescription(sdp)
    }

    func add(remoteCandidate: RTCIceCandidate) {
        pc?.add(remoteCandidate) { _ in }
    }

    // ---- управление ----
    func setMuted(_ muted: Bool) {
        localAudioTrack?.isEnabled = !muted
    }

    func setSpeaker(_ on: Bool) { Self.applySpeaker(on) }

    // static: громкая связь нужна и ДО появления клиента — во время гудков у звонящего клиента ещё
    // нет (создаётся после ответа), а гудки играют через ту же общую аудиосессию
    static func applySpeaker(_ on: Bool) {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        do { try session.overrideOutputAudioPort(on ? .speaker : .none) }
        catch { CallDiag.log("❌ динамик \(on ? "вкл" : "выкл"): \(error.localizedDescription)") }
        session.unlockForConfiguration()
        CallDiag.logAudio("динамик \(on ? "вкл" : "выкл")")   // куда реально пошёл звук (out=[…])
    }

    // явная активация аудиосессии (для стороны БЕЗ CallKit — иначе бывает «соединились, но звука нет»).
    // На стороне CallKit аудио включает CXProvider didActivate, тут не трогаем.
    func activateAudioSession() {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        // видео → .videoChat (громкий динамик по умолчанию); аудио → .voiceChat (разговорный «у уха»)
        do {
            try session.setCategory(.playAndRecord,
                                    mode: isVideo ? .videoChat : .voiceChat,
                                    options: isVideo ? [.allowBluetooth, .defaultToSpeaker] : [.allowBluetooth])
        } catch { CallDiag.log("❌ setCategory: \(error.localizedDescription)") }
        do { try session.setActive(true) } catch { CallDiag.log("❌ setActive(true): \(error.localizedDescription)") }
        if isVideo { try? session.overrideOutputAudioPort(.speaker) }
        session.isAudioEnabled = true     // useManualAudio=true → включаем аудиоюнит сами
        session.unlockForConfiguration()
        CallDiag.logAudio("activateAudioSession (после)")
    }

    func close() {
        videoCapturer?.stopCapture()
        pc?.close()
        pc = nil
        RTCAudioSession.sharedInstance().isAudioEnabled = false   // заглушить аудиоюнит
        CallDiag.logAudio("WebRTCClient.close (после)")
    }

    // ---- метрики качества ----

    // Снимок состояния канала. Потери считаем ДЕЛЬТОЙ между замерами: кумулятивные packetsLost
    // за весь звонок показывают «среднюю температуру» и скрывают текущий провал.
    struct Quality {
        var rttMs: Double?             // круговая задержка выбранной пары кандидатов
        var lossPercent: Double?       // потери входящего аудио за интервал между замерами
        var jitterMs: Double?          // разброс времени прихода пакетов
        var availableOutgoingKbps: Double?   // оценка доступной полосы (то, чем рулит GCC)
        var relayed: Bool?             // идём через TURN или напрямую

        // грубая градация для UI/логов
        var label: String {
            let loss = lossPercent ?? 0
            let rtt = rttMs ?? 0
            if loss >= 10 || rtt >= 500 { return L("плохо") }
            if loss >= 3 || rtt >= 250 { return L("средне") }
            return L("хорошо")
        }
    }

    private var lastAudioPacketsLost: Int64?
    private var lastAudioPacketsReceived: Int64?

    func quality() async -> Quality {
        guard let pc else { return Quality() }
        let report: RTCStatisticsReport = await withCheckedContinuation { cont in
            pc.statistics { cont.resume(returning: $0) }
        }

        var q = Quality()

        for (_, s) in report.statistics {
            switch s.type {
            case "candidate-pair":
                // интересует только реально выбранная пара, остальные — кандидаты-неудачники
                guard (s.values["state"] as? String) == "succeeded",
                      (s.values["nominated"] as? NSNumber)?.boolValue == true else { continue }
                if let rtt = (s.values["currentRoundTripTime"] as? NSNumber)?.doubleValue {
                    q.rttMs = rtt * 1000
                }
                if let bw = (s.values["availableOutgoingBitrate"] as? NSNumber)?.doubleValue {
                    q.availableOutgoingKbps = bw / 1000
                }
            case "local-candidate":
                if (s.values["candidateType"] as? String) == "relay" { q.relayed = true }
            case "inbound-rtp":
                let kind = (s.values["kind"] as? String) ?? (s.values["mediaType"] as? String)
                guard kind == "audio" else { continue }
                if let j = (s.values["jitter"] as? NSNumber)?.doubleValue { q.jitterMs = j * 1000 }

                let lost = (s.values["packetsLost"] as? NSNumber)?.int64Value ?? 0
                let recv = (s.values["packetsReceived"] as? NSNumber)?.int64Value ?? 0
                if let pLost = lastAudioPacketsLost, let pRecv = lastAudioPacketsReceived {
                    let dLost = max(0, lost - pLost)
                    let dRecv = max(0, recv - pRecv)
                    let total = dLost + dRecv
                    if total > 0 { q.lossPercent = Double(dLost) / Double(total) * 100 }
                }
                lastAudioPacketsLost = lost
                lastAudioPacketsReceived = recv
            default:
                break
            }
        }

        return q
    }

    // Накопленное число принятых аудиопакетов. Нужно, чтобы отличить «ICE развалился» от
    // «ICE жалуется, а звук идёт»: состояние ICE — это про доставку consent-проверок, а не про медиа,
    // и на узком рваном канале одно расходится с другим.
    func inboundAudioPackets() async -> Int64? {
        guard let pc else { return nil }
        let report: RTCStatisticsReport = await withCheckedContinuation { cont in
            pc.statistics { cont.resume(returning: $0) }
        }
        for (_, s) in report.statistics where s.type == "inbound-rtp" {
            let kind = (s.values["kind"] as? String) ?? (s.values["mediaType"] as? String)
            guard kind == "audio" else { continue }

            return (s.values["packetsReceived"] as? NSNumber)?.int64Value
        }

        return nil
    }

    // диагностика: реально ли текут медиабайты (снимается через 3с и 10с после ICE-коннекта).
    // «ICE connected, а байты не растут/нулевые» = мёртвый аудиоюнит или DTLS/SRTP не завершился.
    func logStats(_ label: String) async {
        guard let pc else { CallDiag.log("📊 RTP \(label): pc уже закрыт"); return }
        let report: RTCStatisticsReport = await withCheckedContinuation { cont in
            pc.statistics { cont.resume(returning: $0) }
        }
        var parts: [String] = []
        for (_, s) in report.statistics where s.type == "outbound-rtp" || s.type == "inbound-rtp" {
            let kind = (s.values["kind"] as? String) ?? (s.values["mediaType"] as? String) ?? "?"
            let out = s.type == "outbound-rtp"
            let bytes = (s.values[out ? "bytesSent" : "bytesReceived"] as? NSNumber)?.int64Value ?? -1
            parts.append("\(kind).\(out ? "out" : "in")=\(bytes)")
        }
        CallDiag.log("📊 RTP \(label): \(parts.isEmpty ? "потоков нет" : parts.sorted().joined(separator: " "))")
    }
}

extension WebRTCClient: RTCPeerConnectionDelegate {
    func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onLocalIce?(candidate)
    }
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        DispatchQueue.main.async { self.onStateChange?(newState) }
    }
    func peerConnection(_ pc: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        CallDiag.log("🎞 didAdd remote track: \(rtpReceiver.track?.kind ?? "?")")
        if let track = rtpReceiver.track as? RTCVideoTrack {
            remoteVideoTrack = track
            DispatchQueue.main.async { self.onRemoteVideoTrack?(track) }
        }
    }
    // обязательные пустые
    func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
