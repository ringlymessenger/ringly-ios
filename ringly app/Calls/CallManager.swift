import Foundation
import Combine
import CallKit
import WebRTC
import UIKit
import Network

@MainActor
final class CallManager: ObservableObject {
    static let shared = CallManager()

    enum Phase { case idle, outgoing, incoming, active, ended }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var peerName: String = ""
    @Published private(set) var isVideo: Bool = false
    @Published private(set) var muted = false
    @Published private(set) var speakerOn = false
    @Published private(set) var remoteVideoTrack: RTCVideoTrack?
    @Published private(set) var localVideoTrack: RTCVideoTrack?
    @Published private(set) var endedReason: String?
    @Published private(set) var callKitIncoming = false    // входящий показан нативным CallKit (не in-app)
    // статусы для UI (этап B): connectedAt == nil при .active → «Соединение…»; reconnecting → «Переподключение…»
    @Published private(set) var connectedAt: Date?         // первый ICE-коннект; таймер разговора идёт от него
    @Published private(set) var reconnecting = false       // ICE ушёл в disconnected, ждём восстановления
    @Published private(set) var peerRingbackPlaying = false // при дозвоне РЕАЛЬНО играет мелодия абонента (не просто пришли метаданные)
    private var endedFromCallKit = false                   // завершение пришло из CallKit → не репортить обратно

    // показывать ли in-app оверлей (для CallKit-входящего во время звонка его не показываем — CallKit нативный)
    var showInAppUI: Bool { phase != .idle && !(phase == .incoming && callKitIncoming) }

    // Экран звонка свёрнут (как в Telegram): звонок идёт, пользователь в чатах. Вместо полноэкранного
    // экрана — полоса «вернуться к звонку» (аудио) или плавающее окошко с собеседником (видео),
    // см. CallMinimizedOverlay. Чисто UI-состояние: на звонок, WS и WebRTC не влияет.
    @Published private(set) var minimized = false
    var showFullScreen: Bool { showInAppUI && !minimized }
    var showMinimized: Bool { showInAppUI && minimized }

    // свернуть можно только то, что не требует ответа: входящий надо принять или отклонить
    var canMinimize: Bool { phase == .outgoing || phase == .active }
    func minimize() { if canMinimize { minimized = true } }
    func restore() { minimized = false }

    // на реальном устройстве входящий показываем нативным CallKit; на симуляторе/Mac — внутренним оверлеем
    private var usesCallKit: Bool { Calls.useCallKit && Platform.supportsCallKit }

    private init() {
        CallProvider.shared.onAnswer = { [weak self] _ in Task { @MainActor in self?.accept() } }
        CallProvider.shared.onEnd    = { [weak self] _ in Task { @MainActor in self?.endFromCallKit() } }
        CallProvider.shared.onMuted  = { [weak self] m in Task { @MainActor in self?.setMutedExternally(m) } }
    }

    // проброшено из AppViewModel. Пока отправка не подключена (холодный старт по VoIP) — копим события.
    var sendWSEvent: ((_ event: String, _ data: [String: Any]) -> Void)? {
        didSet { flushPendingWS() }
    }
    var messaging: MessagingService?
    private var pendingWS: [(String, [String: Any])] = []

    private func emit(_ event: String, _ data: [String: Any]) {
        if let sendWSEvent { sendWSEvent(event, data) }
        else { pendingWS.append((event, data)) }     // отправка ещё не готова — досошлём в flushPendingWS
    }
    private func flushPendingWS() {
        guard let sendWSEvent else { return }
        let items = pendingWS; pendingWS.removeAll()
        for (e, d) in items { sendWSEvent(e, d) }
    }

    private var rtc: WebRTCClient?
    private var callId: String?
    private(set) var peerUserId: String?          // для аватарки на экране звонка
    private var peerDeviceId: String?
    private var conversationId: String?
    private var iceServers: [RTCIceServer]?
    private var iceFetchedAt: Date?               // когда получен iceServers (см. iceIsStale)
    private var iceFetchedSimulated = false       // получен при имитации блокировки звонков?
    private var iceFetchedOnBridge = false        // получен, когда работали через мостик?
    private var iceFetching = false
    private var pendingRemoteIce: [RTCIceCandidate] = []
    private var remoteDescSet = false
    private var isCaller = false
    private var cancelOnInitiated = false        // сброс исходящего ДО прихода callId → отменить, как придёт
    private var iceConnected = false
    private var wasAccepted = false              // звонок дошёл до active (для callLog: answered vs unanswered)
    private var connectWatchdog: Task<Void, Never>?     // не соединились за N сек → завершить

    // ===== переподключение (ICE restart) =====
    // Окно, в течение которого боремся за звонок после потери связи. ДОЛЖНО быть меньше серверного
    // CALL_GONE_GRACE_SECONDS (45с), иначе сервер объявит peer_gone из-под клиента, который как раз
    // восстановился. Хендовер Wi-Fi↔LTE занимает 10–20с, поэтому прежних 8с не хватало никогда.
    private static let reconnectWindow: TimeInterval = 30
    // паузы ПЕРЕД попытками рестарта (сек). Первая = 0 → мгновенно, дальше растём.
    private static let restartBackoff: [UInt64] = [0, 4, 8, 15]
    private var reconnectTask: Task<Void, Never>?
    // поколение: задача обнуляет reconnectTask только если она всё ещё текущая.
    // Без этого завершившаяся старая задача могла бы снести ссылку на уже запущенную новую.
    private var reconnectGeneration = 0
    private var pathMonitor: NWPathMonitor?
    private var lastPathSignature: String?
    private var qualityTask: Task<Void, Never>?
    @Published private(set) var quality: WebRTCClient.Quality?   // для индикатора качества в UI

    // ===== исходящий =====
    func startCall(calleeUserId: String, calleeName: String, video: Bool) {
        guard phase == .idle else { CallDiag.log("▶️ startCall отклонён: phase=\(phase)"); return }
        CallDiag.log("▶️ startCall \(video ? "video" : "audio") → \(calleeName)")
        CallDiag.logAudio("startCall")
        reset()
        cancelOnInitiated = false       // новый звонок — сбрасываем флаг отложенной отмены
        isCaller = true
        isVideo = video
        CallProvider.configureAudioSession(video: video)   // видео → громкий динамик
        peerUserId = calleeUserId
        peerName = calleeName
        phase = .outgoing
        CallSounds.shared.prepareSessionForOutgoing(video: video)   // сессия под гудки (та же, что для звонка)
        updateScreenState()
        // Ранний отказ: если УЖЕ известно, что TURN нет, а relay-only включён — не дёргаем собеседника
        // звонком, который всё равно провалится после того, как он возьмёт трубку.
        // Когда список ICE-серверов ещё не загружен (iceServers == nil), решение откладываем
        // до startAsCaller — к тому моменту прогрев обычно успевает завершиться.
        if CallSettings.mustRelay, iceServers != nil, !hasTurnServers {
            endWithError("no_relay")
            return
        }
        // Устаревший список обновляем сейчас: пока собеседник берёт трубку, он успеет прийти.
        Task { await prefetchIce() }
        emit("call_initiate", ["calleeUserId": calleeUserId, "media": video ? "video" : "audio"])
    }

    // экран во время звонка: аудио у уха → гасим по датчику приближения (как Телефон/Telegram),
    // видео → не даём экрану засыпать; вне звонка — системное поведение
    private func updateScreenState() {
        let inCall = phase == .outgoing || phase == .incoming || phase == .active
        UIDevice.current.isProximityMonitoringEnabled = inCall && !isVideo && !speakerOn
        UIApplication.shared.isIdleTimerDisabled = phase == .active && isVideo
        // Гейт обхода блокировок: во время звонка резолвер не переключает транспорт (медиа идёт по
        // TURN отдельно; дёргать WS при звонке нельзя). Единая точка — здесь phase меняется всегда.
        EndpointResolver.shared.setCallActive(inCall)
    }

    // ===== входящий: действия пользователя =====
    func accept() {
        guard phase == .incoming, let callId else { return }
        CallDiag.log("✅ accept \(callId.prefix(8))")
        // PC обычно уже создан в startIncoming (идемпотентно). Если создать нельзя (relay-only без
        // TURN) — НЕ принимаем: иначе ниже перевели бы в .active уже нежизнеспособный звонок.
        guard ensureRTC() else { endWithError("no_relay"); return }
        emit("call_accept", ["callId": callId])
        phase = .active
        onBecameActive()
    }

    func decline() {
        CallDiag.log("🚫 decline")
        if let callId { emit("call_reject", ["callId": callId]) }
        sendBye()                        // этап D: дублируем завершение по надёжному E2EE-каналу
        finish(reason: "declined")
    }

    func hangup() {
        guard phase != .idle, phase != .ended else { return }
        CallDiag.log("👋 hangup (phase=\(phase))")
        if let callId {
            emit("call_end", ["callId": callId])
        } else {
            cancelOnInitiated = true     // callId ещё не пришёл — отменим, как придёт call_initiated
        }
        sendBye()                        // этап D: дублируем завершение по надёжному E2EE-каналу
        finish(reason: "hangup")         // экран звонка закрываем ВСЕГДА (иначе застреваем)
    }

    func toggleMute() { muted.toggle(); rtc?.setMuted(muted) }
    func toggleSpeaker() {
        speakerOn.toggle()
        // напрямую в сессию, а не через rtc: во время гудков у звонящего rtc ещё nil, и нажатие
        // раньше меняло только подсветку кнопки, а гудки продолжали идти в разговорный динамик
        WebRTCClient.applySpeaker(speakerOn)
        updateScreenState()   // громкая связь → датчик приближения не гасит экран
    }
    func switchCamera() { rtc?.switchCamera() }   // фронтальная ↔ основная (только видеозвонок)

    // ===== входящий из VoIP-пуша (CallKit уже показан в AppDelegate) =====
    // CallKit уже показан в AppDelegate (reportIncoming) до вызова этого метода
    func prepareIncomingFromVoIP(callId: String, callerUserId: String, callerDeviceId: String,
                                 conversationId: String, media: String) {
        CallDiag.log("📲 VoIP incoming \(callId.prefix(8)) media=\(media)")
        if callId == self.callId { CallDiag.log("📲 дубль (WS опередил VoIP) — игнор"); return }
        if phase != .idle {                    // заняты другим звонком → закрыть этот нативный экран
            CallDiag.log("📲 заняты (phase=\(phase)) → reportEnded(.failed)")
            if let uuid = UUID(uuidString: callId) { CallProvider.shared.reportEnded(uuid: uuid, reason: .failed) }
            return
        }
        startIncoming(callId: callId, callerUserId: callerUserId, callerDeviceId: callerDeviceId,
                      conversationId: conversationId, media: media, viaCallKit: true, alreadyReported: true)
    }

    // завершение из нативного CallKit (свайп «отклонить»/«завершить»)
    func endFromCallKit() {
        endedFromCallKit = true                              // не репортить обратно в CallKit
        if let callId {
            emit(phase == .incoming ? "call_reject" : "call_end", ["callId": callId])
        }
        sendBye()                                            // этап D: дублируем по надёжному каналу
        finish(reason: "ended")
    }

    func setMutedExternally(_ m: Bool) { muted = m; rtc?.setMuted(m) }

    private func startIncoming(callId: String?, callerUserId: String?, callerDeviceId: String?,
                               conversationId: String?, media: String, viaCallKit: Bool, alreadyReported: Bool = false) {
        guard phase == .idle,
              let callId, let callerUserId, let callerDeviceId, let conversationId else { return }
        // заблокированный не дозванивается: не звоним и НЕ шлём reject → у него «нет ответа» (о блоке не узнаёт).
        // если это VoIP (CallKit уже показан в AppDelegate) — убираем нативный экран.
        if BlockStore.isBlocked(callerUserId) {
            CallDiag.log("⛔️ входящий от заблокированного — отбой")
            if alreadyReported, let uuid = UUID(uuidString: callId) {
                CallProvider.shared.reportEnded(uuid: uuid, reason: .unanswered)
            }
            return
        }
        reset()
        isCaller = false
        self.callId = callId
        self.peerUserId = callerUserId
        self.peerDeviceId = callerDeviceId
        self.conversationId = conversationId
        self.isVideo = media == "video"
        CallProvider.configureAudioSession(video: self.isVideo)   // видео → громкий динамик (до CallKit didActivate)
        self.peerName = ContactProfileStore.load(callerUserId)?.name ?? L("Входящий звонок")
        self.callKitIncoming = viaCallKit
        self.phase = .incoming
        updateScreenState()
        ensureRTC()   // создаём PeerConnection СРАЗУ (аудио-дорожка готова до ответа/CallKit didActivate)
        // показать нативный CallKit-экран (если пришли по WS — AppDelegate ещё не репортил)
        if viaCallKit && !alreadyReported, let uuid = UUID(uuidString: callId) {
            CallProvider.shared.reportIncoming(uuid: uuid, caller: peerName, hasVideo: isVideo) { }
        }
    }

    // ===== WS call-lifecycle (из AppViewModel → ws.onCallEvent) =====
    func handleEvent(_ type: String, _ p: [String: Any]) {
        CallDiag.log("🌐 WS \(type)\((p["reason"] as? String).map { " reason=\($0)" } ?? "")\((p["code"] as? String).map { " code=\($0)" } ?? "")")
        switch type {
        case "call_initiated":
            callId = p["callId"] as? String
            conversationId = p["conversationId"] as? String
            if cancelOnInitiated {                              // успели нажать «сброс» до прихода callId
                cancelOnInitiated = false
                if let callId { emit("call_end", ["callId": callId]) }
                finish(reason: "hangup")
            } else if phase == .outgoing {
                CallSounds.shared.play(.outgoing, loop: true)   // сервер начал звонить абоненту → гудки
                // кастомный гудок абонента (услуга Ringback): скачиваем/берём из кэша и подменяем
                // гудки мелодией, когда готова. Любой сбой — молча остаёмся на гудках.
                if let rb = p["ringback"] as? [String: Any],
                   let attachmentId = rb["attachmentId"] as? String,
                   let url = rb["url"] as? String {
                    startRingback(attachmentId: attachmentId, url: url)
                }
            }

        case "call_incoming":
            let cid = p["callId"] as? String
            if cid == callId { return }                       // уже обрабатываем (VoIP мог опередить WS)
            // реальное устройство → CallKit (репортим тут же); симулятор/Mac → in-app
            startIncoming(callId: cid, callerUserId: p["callerUserId"] as? String,
                          callerDeviceId: p["callerDeviceId"] as? String,
                          conversationId: p["conversationId"] as? String,
                          media: (p["media"] as? String) ?? "audio", viaCallKit: usesCallKit)

        case "call_accepted":
            CallSounds.shared.stop()                           // абонент ответил → гудки долой
            RingbackPlayer.shared.stop()                       // …и мелодия-гудок тоже, мгновенно
            peerRingbackPlaying = false
            peerDeviceId = p["byDeviceId"] as? String          // теперь знаем устройство собеседника
            Task { await startAsCaller() }

        case "call_rejected":
            finish(reason: "rejected")

        case "call_ended":
            finish(reason: (p["reason"] as? String) ?? "ended")

        case "call_error":
            finish(reason: (p["code"] as? String) == "busy" ? "busy" : "error")

        default:
            break
        }
    }

    // ===== сигналинг (offer/answer/ICE) из E2EE-сообщений type:"call" =====
    func handleSignal(_ s: CallSignal, fromUserId: String, fromDeviceId: String, conversationId: String) {
        guard s.callId == callId else {
            // не наш звонок (например, запоздавший сигнал предыдущего) — игнор, но ФИКСИРУЕМ:
            // частый дроп тут при звонках подряд = сигналинг путается между звонками
            CallDiag.log("📩 сигнал \(s.kind) ЧУЖОГО звонка \(s.callId.prefix(8)) (наш: \(callId?.prefix(8) ?? "nil")) — дроп")
            return
        }
        CallDiag.log("📩 сигнал \(s.kind) принят")
        Task {
            switch s.kind {
            case "offer":
                self.peerDeviceId = fromDeviceId
                ensureRTC()
                guard let rtc, let sdp = s.sdp else { return }
                do {
                    try await rtc.setRemote(RTCSessionDescription(type: .offer, sdp: sdp))
                } catch {
                    CallDiag.log("❌ setRemote(offer): \(error.localizedDescription)")
                    return
                }
                remoteDescSet = true; flushIce()
                do {
                    let answer = try await rtc.answer()
                    sendSignal(CallSignal(callId: s.callId, kind: "answer", sdp: answer.sdp))
                } catch {
                    CallDiag.log("❌ createAnswer: \(error.localizedDescription)")
                }
            case "answer":
                guard let rtc, let sdp = s.sdp else { return }
                do {
                    try await rtc.setRemote(RTCSessionDescription(type: .answer, sdp: sdp))
                    remoteDescSet = true; flushIce()
                } catch {
                    CallDiag.log("❌ setRemote(answer): \(error.localizedDescription)")
                }
            case "ice":
                guard let cand = s.candidate else { return }
                let ice = RTCIceCandidate(sdp: cand, sdpMLineIndex: s.sdpMLineIndex ?? 0, sdpMid: s.sdpMid)
                if remoteDescSet { rtc?.add(remoteCandidate: ice) } else { pendingRemoteIce.append(ice) }
            case "bye":
                // этап D: собеседник завершил звонок (надёжный канал). Если WS call_ended уже пришёл —
                // finish идемпотентен (guard phase). Заодно подчищаем сервер через НАШ сокет:
                // сокет завершившего мог быть полумёртв, и его call_end до сервера не дошёл.
                CallDiag.log("📩 bye — собеседник завершил звонок")
                if let callId { emit("call_end", ["callId": callId]) }
                finish(reason: "ended")
            default:
                break
            }
        }
    }

    // ===== приватное =====

    // кастомный гудок: кэш/скачивание асинхронно; подменяем гудки мелодией, только если это
    // всё ещё ТОТ ЖЕ звонок и мы всё ещё в дозвоне (защита от гонок со следующим звонком)
    private func startRingback(attachmentId: String, url: String) {
        let expectedCallId = callId
        Task { @MainActor in
            guard let file = await RingbackPlayer.shared.fetch(attachmentId: attachmentId, urlString: url) else { return }
            guard self.callId == expectedCallId, self.phase == .outgoing else { return }
            CallSounds.shared.stop()
            if RingbackPlayer.shared.play(file) {
                CallDiag.log("🎵 ringback: играет мелодия абонента")
                self.peerRingbackPlaying = true   // подпись на экране звонка — только когда её правда слышно
            } else {
                CallSounds.shared.play(.outgoing, loop: true)   // файл не заигрался → обратно на гудки
            }
        }
    }

    // вызывающий после call_accepted: создаём offer и шлём принявшему устройству
    private func startAsCaller() async {
        guard ensureRTC(), let rtc else { endWithError("no_relay"); return }
        phase = .active
        onBecameActive()
        do {
            let offer = try await rtc.offer()
            sendSignal(CallSignal(callId: callId ?? "", kind: "offer", sdp: offer.sdp))
        } catch {
            CallDiag.log("❌ createOffer: \(error.localizedDescription)")
        }
    }

    // звонок перешёл в active: активируем аудио + сторож соединения
    private func onBecameActive() {
        CallDiag.logAudio("onBecameActive (до активации)")
        wasAccepted = true
        iceConnected = false
        updateScreenState()
        startPathMonitor()   // ловим смену Wi-Fi↔LTE раньше, чем это заметит ICE
        // Поднимаем аудиосессию ВРУЧНУЮ (useManualAudio=true) в обоих случаях.
        // На холодном старте CallKit НЕ вызывает didActivate (подтверждено логами) → ждать его нельзя.
        // В контексте активного CallKit-звонка системе разрешён playAndRecord даже на локскрине.
        // didActivate (если всё же придёт в тёплом сценарии) просто переподтвердит — безвредно.
        rtc?.activateAudioSession()
        if isVideo { speakerOn = true }           // видеозвонок → звук в громкий динамик
        // activateAudioSession заново ставит категорию, а это сбрасывает выбор динамика — громкую
        // связь, включённую ещё на гудках, возвращаем, иначе после ответа звук уходил к уху
        if speakerOn { rtc?.setSpeaker(true) }
        connectWatchdog?.cancel()
        connectWatchdog = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            if !Task.isCancelled, !iceConnected, phase == .active {
                endWithError("failed")        // нет ICE-коннекта за 20с → завершаем
            }
        }
    }

    // завершить из-за провала соединения + сообщить второй стороне (синхронизация, чтоб не повисла)
    private func endWithError(_ reason: String) {
        if let callId { emit("call_end", ["callId": callId]) }
        sendBye()                                            // этап D: дублируем по надёжному каналу
        finish(reason: reason)
    }

    // этап D: надёжный hangup. WS call_end может утонуть в полумёртвом сокете (сервер не узнает →
    // собеседнику call_ended не придёт, он сбросит только по ICE-grace). Дублируем «bye» через E2EE-канал
    // сигналинга — та же очередь с гарантией доставки, что offer/answer/ICE. Во время звонка приложение
    // активно (живая аудиосессия) → у получателя работает и WS-пинг, и 10-секундный поллинг сообщений.
    private func sendBye() {
        guard let callId, peerDeviceId != nil else { return }   // до accept адресовать некому (ringing-отмену закрывает серверный RING_TIMEOUT)
        sendSignal(CallSignal(callId: callId, kind: "bye"))
    }

    // синхронно создаём PeerConnection (с аудио-дорожкой) СРАЗУ, не блокируясь на сети —
    // чтобы на холодном старте дорожка была готова ДО CallKit didActivate (иначе нет звука).
    // Возвращает false, если PeerConnection создать нельзя. Сам звонок НЕ завершает — решение
    // за вызывающим: у входящего и исходящего разные точки, где это корректно показать.
    @discardableResult
    private func ensureRTC() -> Bool {
        guard rtc == nil else { return true }

        let relayOnly = CallSettings.mustRelay
        // Fail-closed: пользователь включил «звонить через сервер» именно чтобы не светить IP.
        // Тихо откатиться на прямое соединение — значит нарушить обещание и промолчать об этом;
        // провалившийся звонок он заметит и переспросит, утечку — нет.
        if relayOnly, !hasTurnServers {
            CallDiag.log(CallSettings.simulateBlock
                ? "🚫 имитация блокировки звонков: нет ни волонтёрского TURN, ни мостика — звонку идти некуда"
                : "🚫 relay-only включён, но TURN недоступен")
            return false
        }
        if CallSettings.simulateBlock { CallDiag.log("🧪 имитация блокировки звонков: только волонтёрский TURN") }

        let servers = iceServers ?? [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        let client = WebRTCClient(iceServers: servers, isVideo: isVideo, relayOnly: relayOnly)
        client.onLocalIce = { [weak self] cand in
            Task { @MainActor in self?.sendSignal(CallSignal(
                callId: self?.callId ?? "", kind: "ice",
                candidate: cand.sdp, sdpMid: cand.sdpMid, sdpMLineIndex: cand.sdpMLineIndex)) }
        }
        client.onRemoteVideoTrack = { [weak self] track in self?.remoteVideoTrack = track }
        client.onStateChange = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                CallDiag.log("🧊 ICE → \(CallDiag.iceName(state))")
                switch state {
                case .connected, .completed:
                    self.iceConnected = true
                    if self.reconnecting { CallSounds.shared.stop() }   // «переподключение…» долой
                    self.reconnecting = false
                    self.reconnectTask?.cancel(); self.reconnectTask = nil
                    if self.connectedAt == nil {
                        self.connectedAt = Date()          // старт таймера разговора (UI) и длительности (callLog)
                        // «пип» звонящему: гудки стихли на ответе, но говорить можно только сейчас, когда
                        // пошёл звук. Только первое соединение — не после переподключения; только у
                        // звонящего — принявший и так знает, что взял трубку.
                        if self.isCaller { CallSounds.shared.play(.connected, loop: false) }
                        CallDiag.logAudio("ICE connected")
                        self.scheduleStatsProbe()          // через 3с/10с: идут ли RTP-байты на самом деле
                        self.startQualitySampling()
                    }
                    self.connectWatchdog?.cancel(); self.connectWatchdog = nil
                case .closed:
                    self.endWithError("failed")
                case .failed:
                    // failed — это НЕ «конец», а ровно тот статус, ради которого существует ICE-рестарт:
                    // прежние кандидаты мертвы, нужно собрать новые. Раньше здесь звонок убивался.
                    self.beginReconnect(immediate: true)
                case .disconnected:
                    // disconnected часто самоизлечивается за 1–2с (микро-провал сети) — не дёргаемся сразу
                    self.beginReconnect(immediate: false)
                default:
                    break
                }
            }
        }
        rtc = client
        localVideoTrack = client.localVideoTrack
        Task { await prefetchIce() }   // подтянуть TURN-креды для будущих звонков (текущий не блокируем)

        return true
    }

    // ===== переподключение =====

    // Запустить борьбу за звонок. Идемпотентно: пока цикл жив, повторные вызовы игнорируются
    // (сигналы .disconnected/.failed и NWPathMonitor легко прилетают пачкой).
    private func beginReconnect(immediate: Bool) {
        guard phase == .active, reconnectTask == nil else { return }

        iceConnected = false
        CallDiag.log("♻️ переподключение: старт (окно \(Int(Self.reconnectWindow))с, инициатор=\(isCaller))")

        // ⚠️ Тревогу (статус «Переподключение…» + сирену) поднимаем НЕ здесь, если пришли по
        // `disconnected`: трёхсекундная отсрочка ниже для того и заведена, что это состояние часто
        // самоизлечивается. Раньше отсрочка касалась только попыток чинить ICE, а пугать начинали
        // сразу — и собеседник, которому просто положили трубку, успевал увидеть «Переподключение…»
        // до того, как доедет уведомление о завершении.
        if immediate { raiseReconnectAlarm() }

        reconnectGeneration += 1
        let generation = reconnectGeneration

        reconnectTask = Task { @MainActor in
            // снять ссылку на СЕБЯ на любом пути выхода, иначе guard выше навсегда заблокирует
            // следующее переподключение. Проверка поколения — чтобы не снести более новую задачу.
            defer { if self.reconnectGeneration == generation { self.reconnectTask = nil } }

            let deadline = Date().addingTimeInterval(Self.reconnectWindow)

            if !immediate {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled || self.iceConnected { return }

                // ICE всё ещё disconnected — но это НЕ обязательно значит, что разговор прервался.
                // Состояние ICE считается по доставке consent-проверок, а на узком рваном канале
                // (Edge) они тонут в очереди, пока аудио продолжает идти. Собеседника прекрасно
                // слышно, а на экране «Переподключение…» и через 30с звонок убивали.
                if await self.mediaStillFlowing() {
                    CallDiag.log("♻️ ICE disconnected, но аудио идёт — тревогу не поднимаем")
                    self.standDownReconnect()

                    return
                }

                // Отсрочка прошла, связь не вернулась, звука нет — теперь сказать честно.
                self.raiseReconnectAlarm()
            }

            for pause in Self.restartBackoff {
                if pause > 0 { try? await Task.sleep(nanoseconds: pause * 1_000_000_000) }
                if Task.isCancelled || self.iceConnected || self.phase != .active { return }
                if Date() >= deadline { break }

                // Рестартует ТОЛЬКО инициатор звонка. Если offer'ы полетят с обеих сторон
                // одновременно — коллизия (glare), и соединение уже не собрать. Правило
                // детерминированное, договариваться не нужно: принимающий просто отвечает
                // на re-offer обычным путём (handleSignal "offer" ничего не знает о рестарте).
                if self.isCaller { await self.sendIceRestart() }
            }

            // последний шанс: ждём до конца окна — новый путь мог собраться после крайней попытки
            let left = deadline.timeIntervalSinceNow
            if left > 0 { try? await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000)) }

            if !Task.isCancelled, !self.iceConnected, self.phase == .active {
                // Последняя проверка перед тем, как оборвать разговор. Убить звонок, который
                // пользователь СЛЫШИТ, — худший из возможных исходов: ошибку в другую сторону
                // (подержали мёртвое соединение лишние секунды) он переживёт, эту — нет.
                if await self.mediaStillFlowing() {
                    CallDiag.log("♻️ ICE не собрался за \(Int(Self.reconnectWindow))с, но аудио идёт — продолжаем")
                    self.standDownReconnect()

                    return
                }

                CallDiag.log("♻️ переподключение: не удалось за \(Int(Self.reconnectWindow))с → завершаем")
                self.endWithError("disconnected")
            }
        }
    }

    // Сказать пользователю, что связь потеряна. Идемпотентно: сирена уже играет — второй раз
    // запускать нечего.
    private func raiseReconnectAlarm() {
        guard !reconnecting else { return }
        reconnecting = true
        CallSounds.shared.play(.reconnecting, loop: true)
    }

    // Снять тревогу, не трогая сам звонок: убрать «Переподключение…» и сирену. ICE при этом
    // остаётся в disconnected — если связь действительно умрёт, он уйдёт в .failed и цикл
    // переподключения запустится заново.
    private func standDownReconnect() {
        reconnecting = false
        CallSounds.shared.stop()
    }

    // Растут ли входящие аудиопакеты. Два замера с паузой: счётчик накопительный, и его абсолютное
    // значение ничего не говорит о том, идёт ли звук ПРЯМО СЕЙЧАС.
    private func mediaStillFlowing() async -> Bool {
        guard let rtc, let before = await rtc.inboundAudioPackets() else { return false }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard phase == .active, let after = await rtc.inboundAudioPackets() else { return false }

        return after > before
    }

    private func sendIceRestart() async {
        guard let rtc, let callId else { return }
        do {
            let offer = try await rtc.offerWithIceRestart()
            sendSignal(CallSignal(callId: callId, kind: "offer", sdp: offer.sdp))
            CallDiag.log("♻️ ICE restart: re-offer отправлен")
        } catch {
            CallDiag.log("❌ ICE restart: \(error.localizedDescription)")
        }
    }

    // Смена сетевого интерфейса (Wi-Fi ↔ LTE, новая точка доступа) ломает старые ICE-кандидаты
    // мгновенно, а ICE узнаёт об этом лишь через несколько секунд таймаутов. Бьём на упреждение —
    // это срезает паузу в разговоре в разы.
    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            // подпись пути: набор активных интерфейсов + доступность. Меняется — значит нас переставили.
            let signature = path.availableInterfaces.map { $0.name }.joined(separator: ",")
                + "|" + (path.status == .satisfied ? "up" : "down")
            Task { @MainActor in
                guard let self else { return }
                defer { self.lastPathSignature = signature }
                guard let previous = self.lastPathSignature, previous != signature else { return }
                guard self.phase == .active, path.status == .satisfied else { return }
                CallDiag.log("🛰 сеть сменилась (\(previous) → \(signature)) → упреждающий ICE restart")
                self.beginReconnect(immediate: true)
            }
        }
        monitor.start(queue: DispatchQueue(label: "ringly.call.path"))
    }

    private func stopPathMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
        lastPathSignature = nil
    }

    // Периодический снимок качества канала. Нужен, чтобы судить о звонках по цифрам
    // (потери/RTT/джиттер/полоса), а не по ощущениям — и чтобы позже было чем питать индикатор в UI.
    private func startQualitySampling() {
        qualityTask?.cancel()
        qualityTask = Task { @MainActor in
            while !Task.isCancelled, phase == .active {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, let rtc, phase == .active else { return }
                let q = await rtc.quality()
                self.quality = q
                CallDiag.log(String(format: "📶 %@ rtt=%.0fms loss=%.1f%% jitter=%.0fms bw=%.0fkbps%@",
                                    q.label,
                                    q.rttMs ?? -1, q.lossPercent ?? -1, q.jitterMs ?? -1,
                                    q.availableOutgoingKbps ?? -1,
                                    q.relayed == true ? " relay" : ""))
            }
        }
    }

    // диагностика: реально ли текут медиабайты после ICE-коннекта (мёртвый аудиоюнит = байты не растут)
    private func scheduleStatsProbe() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await rtc?.logStats("t+3с")
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            await rtc?.logStats("t+10с")
        }
    }

    // Сколько живёт список ICE-серверов. Раньше он брался один раз и жил до перезапуска, а это два
    // бага: TURN-креды выписываются на сутки (TURN_TTL) — приложение, неделю висящее в памяти, звонило
    // с протухшими кредами; и волонтёрские TURN, появившиеся после первого запроса, не подхватывались
    // никогда (а выданная пара могла давно уйти офлайн). Обновляем на старте, при каждом возврате
    // в приложение и в начале исходящего звонка — если список старше этого срока.
    private static let iceMaxAge: TimeInterval = 300

    private var iceIsStale: Bool {
        guard let iceFetchedAt else { return true }
        return Date().timeIntervalSince(iceFetchedAt) > Self.iceMaxAge
            || iceFetchedSimulated != CallSettings.simulateBlock
            || iceFetchedOnBridge != EndpointResolver.shared.isOnBridge   // TURN через мостик — только на мостике
    }

    // Подгрузка ICE-серверов (TURN). Неудача НЕ стирает прежний список: старые креды лучше никаких.
    //
    // Состав списка:
    //  • волонтёрская пара TURN (обход блокировок), а если пул пуст — центральный TURN;
    //  • пока приложение работает через мостик — ещё и центральный TURN ЧЕРЕЗ мостик (TCP внутри
    //    Reality, см. TurnBridgeForwarder). Отдельной логики запасного режима нет: у relay по TCP
    //    самый низкий приоритет в ICE, он выбирается, только если обычные пути не прошли.
    // При имитации блокировки звонков прямой центральный TURN не берётся — он «заблокирован», а через
    // мостик остаётся: в реальной блокировке до него дойдёт именно так.
    private func prefetchIce() async {
        guard iceIsStale, !iceFetching else { return }
        iceFetching = true
        defer { iceFetching = false }
        let simulated = CallSettings.simulateBlock
        let proxyPort = EndpointResolver.shared.activeBridgeProxyPort

        let pair = try? await RelayClient.fetchTurnPair()
        let volunteers = pair ?? []
        // центральный нужен как запасной (пул пуст) и как цель для TURN через мостик
        var central: [IceServerDTO]?
        if (volunteers.isEmpty && !simulated) || proxyPort != nil {
            let resp: IceServersResponse? = try? await APIClient.shared.request("calls/ice-servers")
            central = resp?.iceServers
        }
        // обе загрузки не удались — оставляем прежний список
        if pair == nil, central == nil { return }

        var servers: [RTCIceServer] = []
        if !volunteers.isEmpty {
            // Пара волонтёрских TURN из РАЗНЫХ операторов: ни один не видит оба IP собеседников.
            servers += volunteers.map {
                RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
            }
            servers.append(RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"]))
            // адреса волонтёрских TURN в журнал не пишем: его пересылают, а адреса — то, что блокируют
            CallDiag.log("🧊 TURN-пара получена (обход): \(volunteers.count) релея")
        } else if !simulated, let central {
            servers += central.map {
                RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
            }
            CallDiag.log("🧊 ICE-серверы получены (TURN: \(Self.containsTurn(servers) ? "есть" : "НЕТ"))")
        } else if simulated {
            CallDiag.log("🧊 имитация блокировки звонков: волонтёрских TURN нет, центральный напрямую не берём")
        }

        if let proxyPort, let central, let tunneled = await tunneledTurn(central, proxyPort: proxyPort) {
            servers.append(tunneled)
        }

        storeIce(servers, simulated: simulated, onBridge: proxyPort != nil)
    }

    // Центральный TURN через мостик: первый turn:-адрес (не turns: — TLS-сертификат не сойдётся
    // с 127.0.0.1), всегда по TCP — UDP через туннель не ходит. coturn слушает TCP на том же порту.
    private func tunneledTurn(_ central: [IceServerDTO], proxyPort: Int) async -> RTCIceServer? {
        for server in central {
            guard let username = server.username, let credential = server.credential else { continue }
            for url in server.urls where url.hasPrefix("turn:") {
                guard let (host, port) = Self.turnHostPort(url) else { continue }
                guard let local = await TurnBridgeForwarder.shared.port(for: host, port: port, proxyPort: proxyPort) else {
                    CallDiag.log("🧊 TURN через мостик: не удалось открыть локальный порт")
                    return nil
                }
                CallDiag.log("🧊 + TURN через мостик: 127.0.0.1:\(local) → центральный TURN по TCP")
                return RTCIceServer(urlStrings: ["turn:127.0.0.1:\(local)?transport=tcp"],
                                    username: username, credential: credential)
            }
        }
        return nil
    }

    private func storeIce(_ servers: [RTCIceServer], simulated: Bool, onBridge: Bool) {
        iceServers = servers
        iceFetchedAt = Date()
        iceFetchedSimulated = simulated
        iceFetchedOnBridge = onBridge
    }

    private static func containsTurn(_ servers: [RTCIceServer]) -> Bool {
        servers.contains { $0.urlStrings.contains { $0.hasPrefix("turn:") || $0.hasPrefix("turns:") } }
    }

    // «turn:host:3478?transport=udp» → (host, 3478). Без порта — стандартный 3478.
    private static func turnHostPort(_ url: String) -> (String, Int)? {
        let body = url.dropFirst("turn:".count).split(separator: "?").first.map(String.init) ?? ""
        let parts = body.split(separator: ":")
        guard let host = parts.first, !host.isEmpty else { return nil }
        let port = parts.count > 1 ? Int(parts[1]) ?? 3478 : 3478
        return (String(host), port)
    }

    // Прогрев ICE на старте приложения. Раньше prefetchIce() звался в КОНЦЕ ensureRTC(), то есть
    // самый первый звонок сессии всегда шёл без TURN, на публичном STUN — а это ровно тот звонок,
    // который чаще всего и не соединялся (симметричный NAT у мобильных операторов).
    func warmUpIce() {
        Task { await prefetchIce() }
    }

    // Возврат из фона: локальный порт TURN через мостик мёртв — iOS отбирает слушающие сокеты
    // у спящего приложения (как и у туннеля, см. EndpointResolver.appBecameActive). Пересоздаём его
    // вместе со списком ICE, где записан номер порта. Во время звонка приложение не засыпает — не трогаем.
    func appBecameActive() {
        guard phase == .idle, TurnBridgeForwarder.shared.isRunning else { return }
        TurnBridgeForwarder.shared.stop()
        iceFetchedAt = nil   // список устарел → warmUpIce в startMessaging запросит заново
    }

    // есть ли среди выданных серверов настоящий TURN (STUN сам по себе релей не даёт)
    private var hasTurnServers: Bool {
        guard let iceServers else { return false }
        return iceServers.contains { $0.urlStrings.contains { $0.hasPrefix("turn:") || $0.hasPrefix("turns:") } }
    }

    private func sendSignal(_ s: CallSignal) {
        guard let peerUserId, let peerDeviceId, let conversationId else {
            CallDiag.log("📤 сигнал \(s.kind) НЕ отправлен: peer/conversation ещё неизвестны")
            return
        }
        CallDiag.log("📤 сигнал \(s.kind) → устройству собеседника")
        Task { await messaging?.sendCallSignal(s, toUserId: peerUserId, toDeviceId: peerDeviceId, conversationId: conversationId) }
    }

    private func flushIce() {
        for c in pendingRemoteIce { rtc?.add(remoteCandidate: c) }
        pendingRemoteIce.removeAll()
    }

    // запись «был звонок» в чат: одну каноническую пишет ЗВОНИВШИЙ (E2EE type:"callLog" через обычный
    // пайплайн) — обе стороны и все их устройства получают её в историю; принявшая сторона ничего не
    // пишет сама (иначе дубли). Ограничение (осознанное): убитое приложение звонившего = записи нет.
    private func logCallIfNeeded(reason: String) {
        guard isCaller, let callId, let peerUserId, let conversationId else { return }
        let outcome: String
        var duration: Int? = nil
        if wasAccepted {
            outcome = "answered"
            duration = connectedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
        } else if reason == "rejected" {
            outcome = "declined"
        } else {
            outcome = "unanswered"   // hangup до ответа / timeout / busy / error → у абонента «Пропущенный»
        }
        let log = CallLog(callId: callId, media: isVideo ? "video" : "audio",
                          outcome: outcome, durationSec: duration)
        let peer = peerUserId, conv = conversationId, msg = messaging
        Task { await msg?.sendCallLog(log, recipientUserId: peer, conversationId: conv) }
    }

    private func finish(reason: String) {
        guard phase != .idle, phase != .ended else { return }
        CallDiag.log("🏁 finish(\(reason)) phase=\(phase) ice=\(iceConnected)")
        CallDiag.logAudio("finish")
        logCallIfNeeded(reason: reason)

        // звуковое сопровождение исхода (как в Telegram); циклические (гудки/переподключение/мелодия) стопаются всегда
        CallSounds.shared.stop()
        RingbackPlayer.shared.stop()
        peerRingbackPlaying = false
        switch reason {
        case "busy", "rejected", "timeout":
            if isCaller { CallSounds.shared.play(.busy, loop: false) }   // занято / отклонил / не ответил
        case "declined":
            break                                                        // сам отклонил — без звука
        default:
            if wasAccepted || isCaller { CallSounds.shared.play(.end, loop: false) }
        }
        // убрать нативный CallKit-UI, если он был и завершение НЕ из CallKit
        if callKitIncoming, !endedFromCallKit, let callId, let uuid = UUID(uuidString: callId) {
            let ck: CXCallEndedReason
            switch reason {
            case "timeout":                       ck = .unanswered
            case "busy", "error", "disconnected": ck = .failed
            default:                              ck = .remoteEnded
            }
            CallProvider.shared.reportEnded(uuid: uuid, reason: ck)
        }
        endedReason = reason
        phase = .ended
        updateScreenState()   // вернуть системное поведение экрана (proximity/idle)
        // гасим фоновые циклы ДО close(): иначе переподключение может дёрнуть re-offer уже мёртвого звонка
        reconnectTask?.cancel(); reconnectTask = nil
        qualityTask?.cancel(); qualityTask = nil
        stopPathMonitor()
        rtc?.close()
        // пауза, чтобы UI показал итог; провал соединения показываем дольше (пользователь должен успеть прочитать)
        let failure = ["failed", "disconnected", "error", "busy", "timeout"].contains(reason)
        let pause: UInt64 = failure ? 3_000_000_000 : 1_200_000_000
        Task { try? await Task.sleep(nanoseconds: pause); if phase == .ended { reset() } }
    }

    private func reset() {
        // Итоговый сигнал («занято», отбой) живёт ровно столько, сколько показан экран звонка.
        // Без этого он доигрывал файл до конца уже после того, как экран закрылся: пользователь
        // вернулся в список чатов, а из динамика всё ещё пикает и непонятно, откуда и когда кончится.
        CallSounds.shared.stop()
        RingbackPlayer.shared.stop()   // страховка: мелодия-гудок не переживает границу звонка
        peerRingbackPlaying = false
        connectWatchdog?.cancel(); connectWatchdog = nil
        reconnectTask?.cancel(); reconnectTask = nil
        qualityTask?.cancel(); qualityTask = nil
        quality = nil
        stopPathMonitor()
        iceConnected = false
        wasAccepted = false; connectedAt = nil; reconnecting = false
        rtc?.close()
        rtc = nil
        callId = nil; peerUserId = nil; peerDeviceId = nil; conversationId = nil
        pendingRemoteIce.removeAll(); remoteDescSet = false; isCaller = false
        muted = false; speakerOn = false
        remoteVideoTrack = nil; localVideoTrack = nil
        CallPiP.shared.detach()        // окно PiP не переживает звонок, даже если экран звонка ещё не закрылся
        minimized = false              // следующий звонок начинается с полного экрана
        endedReason = nil
        callKitIncoming = false; endedFromCallKit = false
        phase = .idle
        updateScreenState()
    }
}

#if DEBUG
// Стенд экрана звонка без настоящего звонка (`-callHarness incoming|outgoing|active|video`):
// только состояние для отрисовки, ни сети, ни WebRTC.
extension CallManager {
    func debugPreview(_ mode: String) {
        // `-callName "Имя"` — своё имя собеседника (стенд скриншотов)
        peerName = UserDefaults.standard.string(forKey: "callName") ?? "Анна Соколова"
        // `-callAvatar` — у собеседника есть аватарка (фон экрана — размытое фото, а не градиент)
        if ProcessInfo.processInfo.arguments.contains("-callAvatar") {
            let img = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 400)).image { ctx in
                UIColor.systemOrange.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
                UIColor.systemTeal.setFill(); ctx.fill(CGRect(x: 0, y: 200, width: 400, height: 200))
            }
            let avatar = DemoScreens.avatarPNG(for: peerName) ?? img.pngData()
            ContactProfileStore.save(userId: "debug-peer", name: peerName, avatar: avatar)
            peerUserId = "debug-peer"
            ContactProfileCache.shared.ensure("debug-peer")
        }
        isVideo = mode == "video"
        switch mode {
        case "incoming": phase = .incoming
        case "outgoing":
            phase = .outgoing
            // `-callRingback` — у абонента играет его мелодия (подпись под «Вызов…»)
            peerRingbackPlaying = ProcessInfo.processInfo.arguments.contains("-callRingback")
        default:
            phase = .active
            connectedAt = Date().addingTimeInterval(-63)
        }
    }
}
#endif

