import Foundation
import CallKit
import AVFoundation
import WebRTC

// Обёртка CallKit: нативный экран входящего звонка (по VoIP-пушу), управление аудиосессией.
// Используется только на реальном девайсе (PushKit/VoIP). На симуляторе путь — внутренний оверлей.
final class CallProvider: NSObject {
    static let shared = CallProvider()

    private let provider: CXProvider
    private let controller = CXCallController()

    // мост к CallManager (выставляется в CallManager.init)
    var onAnswer: ((UUID) -> Void)?
    var onEnd: ((UUID) -> Void)?
    var onMuted: ((Bool) -> Void)?

    override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)

        // конфигурация аудиосессии для WebRTC (без неё «коннект есть, звука нет»).
        // по умолчанию режим аудиозвонка; для видео переключаем на .videoChat (громкий динамик) — см. configureAudioSession.
        CallProvider.configureAudioSession(video: false)

        // CallKit сам активирует аудиосессию → WebRTC не должен делать это автоматически.
        // Аудиоюнит включаем вручную (isAudioEnabled) в didActivate / на стороне без CallKit.
        RTCAudioSession.sharedInstance().useManualAudio = true
    }

    // настроить режим аудиосессии под тип звонка: видео → .videoChat (громкий динамик по умолчанию),
    // аудио → .voiceChat (разговорный динамик «у уха»). Вызывать ДО активации сессии.
    static func configureAudioSession(video: Bool) {
        let cfg = RTCAudioSessionConfiguration.webRTC()
        cfg.category = AVAudioSession.Category.playAndRecord.rawValue
        cfg.mode = (video ? AVAudioSession.Mode.videoChat : AVAudioSession.Mode.voiceChat).rawValue
        cfg.categoryOptions = video
            ? [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
            : [.allowBluetooth, .allowBluetoothA2DP, .duckOthers]
        RTCAudioSessionConfiguration.setWebRTC(cfg)
    }

    // немедленно показать нативный входящий (обязательно сразу после VoIP-пуша, иначе iOS убьёт апп)
    func reportIncoming(uuid: UUID, caller: String, hasVideo: Bool, completion: @escaping () -> Void) {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: caller)
        update.localizedCallerName = caller
        update.hasVideo = hasVideo
        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            // ошибка здесь критична: iOS требует успешный report на КАЖДЫЙ VoIP-пуш,
            // систематические сбои → троттлинг VoIP на устройстве (и «ломается после N звонков»)
            if let error {
                CallDiag.log("❌ CallKit reportNewIncomingCall \(uuid.uuidString.prefix(8)): \(error.localizedDescription)")
            } else {
                CallDiag.log("📞 CallKit report ok \(uuid.uuidString.prefix(8))")
            }
            completion()
        }
    }

    // звонок завершён удалённой стороной/нами — убрать нативный UI
    func reportEnded(uuid: UUID, reason: CXCallEndedReason) {
        CallDiag.log("📞 CallKit reportEnded \(uuid.uuidString.prefix(8)) reason=\(reason.rawValue)")
        provider.reportCall(with: uuid, endedAt: nil, reason: reason)
    }
}

extension CallProvider: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {}

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        onAnswer?(action.callUUID)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        onEnd?(action.callUUID)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        onMuted?(action.isMuted)
        action.fulfill()
    }

    // CallKit активировал аудиосессию → сообщаем WebRTC и включаем аудиоюнит (иначе звука нет)
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        CallDiag.logAudio("CallKit didActivate (до)")
        let s = RTCAudioSession.sharedInstance()
        s.audioSessionDidActivate(audioSession)
        s.isAudioEnabled = true               // реальный переход false→true → старт аудиоюнита
        CallDiag.logAudio("CallKit didActivate (после)")
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        CallDiag.logAudio("CallKit didDeactivate (до)")
        RTCAudioSession.sharedInstance().audioSessionDidDeactivate(audioSession)
        RTCAudioSession.sharedInstance().isAudioEnabled = false
        CallDiag.logAudio("CallKit didDeactivate (после)")
    }
}
