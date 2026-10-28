import Foundation
import AVFoundation
import WebRTC

// Звуковое сопровождение звонка (как в Telegram): гудки исходящего, «занято», звук завершения,
// «переподключение…», короткий «пип» соединения. Файлы — ringly app/Sounds/*.mp3|m4a
// (синхронизированная папка → ресурсы бандла).
//
// ВАЖНО (инварианты аудио, см. ios-calls.md «Аудиосессия»): играем через AVAudioPlayer поверх УЖЕ
// сконфигурированной сессии звонка и категорию/`isAudioEnabled` здесь НЕ трогаем. Единственное
// исключение — prepareSessionForOutgoing(): на стороне звонящего CallKit не участвует, сессию всё
// равно поднимаем мы сами (та же категория/режим, что выставит activateAudioSession при ответе),
// иначе гудки уйдут в громкий динамик с категорией по умолчанию вместо разговорного «у уха».
@MainActor
final class CallSounds {
    static let shared = CallSounds()

    enum Sound: String {
        case outgoing = "call_outgoing"   // гудки (loop, пока собеседник не ответил)
        case busy = "call_busy"           // занято / отклонил / не ответил
        case end = "call_end"             // завершение разговора
        case reconnecting = "reconnecting" // ICE disconnected (loop, пока не восстановится)
        case connected = "call_connected"  // «пип»: соединение установлено, можно говорить (только звонящему)
    }

    private var player: AVAudioPlayer?

    func play(_ sound: Sound, loop: Bool) {
        stop()
        guard let url = Bundle.main.url(forResource: sound.rawValue, withExtension: "mp3")
                ?? Bundle.main.url(forResource: sound.rawValue, withExtension: "m4a") else {
            CallDiag.log("🔔 звук \(sound.rawValue) не найден в бандле")
            return
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.numberOfLoops = loop ? -1 : 0
            p.volume = 1.0
            p.play()
            player = p
        } catch {
            CallDiag.log("🔔 звук \(sound.rawValue): \(error.localizedDescription)")
        }
    }

    func stop() {
        player?.stop()
        player = nil
    }

    // поднять сессию под гудки исходящего ДО ответа (звонящая сторона — без CallKit).
    // Категория/режим идентичны activateAudioSession → повторная активация при ответе идемпотентна.
    func prepareSessionForOutgoing(video: Bool) {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        do {
            try session.setCategory(.playAndRecord,
                                    mode: video ? .videoChat : .voiceChat,
                                    options: video ? [.allowBluetooth, .defaultToSpeaker] : [.allowBluetooth])
        } catch { CallDiag.log("🔔 setCategory(outgoing): \(error.localizedDescription)") }
        do { try session.setActive(true) } catch { CallDiag.log("🔔 setActive(outgoing): \(error.localizedDescription)") }
        if video { try? session.overrideOutputAudioPort(.speaker) }
        session.unlockForConfiguration()
        CallDiag.logAudio("prepareSessionForOutgoing (после)")
    }
}
