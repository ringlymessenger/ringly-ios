import Foundation

final class WebSocketClient: NSObject, URLSessionWebSocketDelegate {
    // тот же хост, что в APIClient, но схема ws/wss и путь /ws (см. AppConfig)
    private let wsURL = AppConfig.webSocketURL

    var onDeliver: (() -> Void)?                       // {type:"deliver"} → синкнуть сообщения
    var onEnvelope: ((IncomingDelivery) -> Void)?      // {type:"envelope"} → конверт пришёл целиком, синк не нужен
    var onStatus: ((_ messageId: String, _ state: String) -> Void)?   // {type:"status",state:"delivered",...}
    var onSync: (() -> Void)?                          // {type:"sync"} → запустить Profile-Key sync
    var onCallEvent: ((_ type: String, _ payload: [String: Any]) -> Void)?   // call_* lifecycle
    var onPresence: ((_ userId: String, _ online: Bool, _ lastSeenAt: Date?) -> Void)?   // presence собеседника
    var onConnectionState: ((_ open: Bool) -> Void)?   // статус подключения для шапки («Соединение…»)

    private var task: URLSessionWebSocketTask?
    private var presenceSubs: Set<String> = []     // на кого подписаны — переотправляем на реконнекте
    private var heartbeat: Timer?
    private var reconnectDelay: TimeInterval = 1
    private var isStopped = false
    private var isOpen = false
    private var isConnecting = false
    // если сокет ещё не открыт (ответ через CallKit) — копим и шлём на коннекте. С временем постановки:
    // устаревшее не отправляем (см. flushPending).
    private var pendingSends: [(text: String, at: Date)] = []
    // ⚠️ Дольше этого событие в очереди не живёт. Без срока сокет, поднявшийся через минуту,
    // отправлял задним числом call_initiate давно отменённого звонка и call_accept чужого — сервер
    // заводил «призрачный» вызов, и следующие звонки ломались у обоих (calls-stability.md).
    private static let pendingTTL: TimeInterval = 20
    private var wiredResolver = false              // колбэк смены транспорта ставим один раз

    func connect() {
        guard let token = TokenStore.shared.token else { return }
        wireResolver()
        guard !isOpen, !isConnecting else { return }   // уже подключены/подключаемся — не плодим сокеты
        isConnecting = true
        isStopped = false
        var comps = URLComponents(url: wsURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "token", value: token)]
        // сессия от резолвера: прямой путь или через мостик (тот же прокси, что у REST)
        let session = EndpointResolver.shared.makeSession(delegate: self, delegateQueue: nil)
        task = session.webSocketTask(with: comps.url!)
        task?.resume()
        receive()
    }

    // При смене транспорта (REST-запрос упёрся в блокировку → резолвер переключился на мостик)
    // пересоздаём сокет с новым прокси. Во время звонка резолвер транспорт не меняет, так что
    // инвариант «не дёргать WS при звонке» соблюдён на стороне резолвера.
    private func wireResolver() {
        guard !wiredResolver else { return }
        wiredResolver = true
        EndpointResolver.shared.onTransportChange = { [weak self] in
            DispatchQueue.main.async {
                guard let self, !self.isStopped else { return }
                self.task?.cancel(with: .goingAway, reason: nil)
                self.task = nil
                self.isOpen = false
                self.isConnecting = false
                self.connect()
            }
        }
    }

    func disconnect() {
        isStopped = true
        isOpen = false
        isConnecting = false
        stopHeartbeat()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    // --- URLSessionWebSocketDelegate ---
    func urlSession(_ s: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol p: String?) {
        guard webSocketTask === task else { return }     // игнор колбэка устаревшего сокета
        reconnectDelay = 1
        isOpen = true
        isConnecting = false
        CallDiag.log("🔌 WS открыт")
        onConnectionState?(true)
        startHeartbeat()
        flushPending()                  // отправить накопленные call_* события
        for uid in presenceSubs {       // сокет пересоздан → сервер потерял подписки, переподписываемся
            send(event: "presence_subscribe", data: ["userId": uid])
        }
        onDeliver?()                    // на коннекте сразу подтянуть пропущенное
    }
    func urlSession(_ s: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard webSocketTask === task else { return }     // закрылся СТАРЫЙ сокет — новый не трогаем
        scheduleReconnect()
    }

    private func receive() {
        let current = task
        current?.receive { [weak self] result in
            guard let self, current === self.task else { return }   // колбэк старого сокета — игнор
            switch result {
            case .failure:
                self.scheduleReconnect()
            case .success(let message):
                if case .string(let text) = message { self.handle(text) }
                self.receive()          // слушаем дальше
            }
        }
    }

    // кадр {type:"envelope", delivery:{…}} — поле в точности совпадает с элементом GET /messages,
    // поэтому разбирается тем же типом и дальше идёт тем же конвейером
    private struct EnvelopeFrame: Decodable { let delivery: IncomingDelivery }

    // разбор входящего WS-события: {type:"deliver"} | {type:"envelope"} | {type:"status",…}
    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "deliver":
            onDeliver?()
        case "envelope":
            // Сервер положил конверт прямо в сокет — GET /messages не нужен, остаётся только ack.
            // Если разобрать не вышло (несовпадение версий), откатываемся на обычный синк:
            // сообщение всё равно лежит в очереди доставки и никуда не денется.
            if let frame = try? JSONDecoder().decode(EnvelopeFrame.self, from: data) {
                onEnvelope?(frame.delivery)
            } else {
                onDeliver?()
            }
        case "status":
            if let messageId = obj["messageId"] as? String, let state = obj["state"] as? String {
                onStatus?(messageId, state)
            }
        case "sync":
            onSync?()
        case "presence":
            if let userId = obj["userId"] as? String {
                let online = (obj["online"] as? Bool) ?? false
                let seen = (obj["lastSeenAt"] as? String).flatMap(WebSocketClient.parseISO)
                onPresence?(userId, online, seen)
            }
        case let t where t.hasPrefix("call_"):
            onCallEvent?(type, obj)
        default:
            break
        }
    }

    // подписка на presence собеседника (при открытии чата). Идемпотентно; при закрытом сокете
    // отправится в didOpen (переподписка). Сервер проверяет право (общая беседа) и шлёт текущий статус.
    func subscribePresence(_ userId: String) {
        guard presenceSubs.insert(userId).inserted else { return }
        if isOpen { send(event: "presence_subscribe", data: ["userId": userId]) }
    }
    func unsubscribePresence(_ userId: String) {
        guard presenceSubs.remove(userId) != nil else { return }
        if isOpen { send(event: "presence_unsubscribe", data: ["userId": userId]) }
    }

    // ISO8601 с дробными секундами и без — сервер может слать в любом варианте
    private static func parseISO(_ s: String) -> Date? {
        let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter(); f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }

    // отправка события на сервер (формат WsAdapter: {event, data})
    func send(event: String, data: [String: Any]) {
        let msg: [String: Any] = ["event": event, "data": data]
        guard let json = try? JSONSerialization.data(withJSONObject: msg),
              let text = String(data: json, encoding: .utf8) else { return }
        if isOpen, let task {
            task.send(.string(text)) { _ in }
        } else {
            pendingSends.append((text, Date()))   // сокет ещё не открыт — отправим в didOpen
            if event.hasPrefix("call_") { CallDiag.log("🔌 WS закрыт — \(event) в очереди") }
        }
    }

    private func flushPending() {
        guard isOpen, let task, !pendingSends.isEmpty else { return }
        let items = pendingSends
        pendingSends.removeAll()
        let now = Date()
        for item in items {
            guard now.timeIntervalSince(item.at) <= Self.pendingTTL else {
                CallDiag.log("🔌 WS: устаревшее событие из очереди отброшено")
                continue
            }
            task.send(.string(item.text)) { _ in }
        }
    }

    // приложение стало активным — для presence «онлайн = на переднем плане»
    func notifyActive() { send(event: "presence_active", data: [:]) }

    // ушли в фон: шлём presence_inactive и вызываем done В КОЛБЭКЕ ОТПРАВКИ (кадр реально ушёл),
    // чтобы вызывающий рвал сокет ТОЛЬКО после флаша (под background-task) — иначе offline не доходит.
    func notifyInactiveFlush(_ done: @escaping () -> Void) {
        guard isOpen, let task else { done(); return }
        task.send(.string("{\"event\":\"presence_inactive\",\"data\":{}}")) { _ in
            DispatchQueue.main.async { done() }
        }
    }

    // вернулись в foreground: пере-подписаться на presence открытых чатов, чтобы получить СВЕЖИЙ статус,
    // даже если сокет остался жив и didOpen не сработал (иначе «залоченный собеседник висит в сети»,
    // пока не переоткроешь чат). Если сокет не открыт — переподписка произойдёт в didOpen после connect.
    func resubscribePresence() {
        guard isOpen else { return }
        for uid in presenceSubs { send(event: "presence_subscribe", data: ["userId": uid]) }
    }

    // ⚠️ Таймер — СТРОГО на главном цикле событий. Сюда приходят из didOpenWithProtocol, а делегат
    // URLSession (delegateQueue: nil) зовётся на фоновой очереди, у которой нет запущенного RunLoop:
    // `Timer.scheduledTimer` там заводился и НЕ СРАБАТЫВАЛ НИ РАЗУ (проверено отдельным тестом).
    // Цена была огромной и незаметной: сервер держит presence `ws:device:*` 90 с и продлевает его
    // только этим heartbeat'ом — через полторы минуты после подключения устройство для сервера
    // «пропадало», и он молча выбрасывал call_initiated/call_accepted/call_ended, хотя сокет был жив.
    // Отсюда «после одного звонка следующие не устанавливаются» (calls-stability.md §5б). Заодно не
    // работали ни детект зомби-сокета ping'ом, ни рефреш presence собеседника открытого чата.
    private func startHeartbeat() {
        DispatchQueue.main.async { [weak self] in self?.installHeartbeat() }
    }

    // остановка — тоже на главном: Timer снимается с того потока, на котором заведён
    private func stopHeartbeat() {
        if Thread.isMainThread {
            heartbeat?.invalidate(); heartbeat = nil
        } else {
            DispatchQueue.main.async { [weak self] in self?.heartbeat?.invalidate(); self?.heartbeat = nil }
        }
    }

    private func installHeartbeat() {
        heartbeat?.invalidate()
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            guard let self, let task = self.task else { return }
            task.send(.string("{\"event\":\"heartbeat\",\"data\":{}}")) { _ in }
            // самокоррекция presence ОТКРЫТОГО чата: сервер мог молча потерять подписку (гонки чисток
            // на реконнектах — «был в сети 6 мин назад» при живой переписке). Переподписка идемпотентна
            // и сразу возвращает актуальный статус. Только собеседник открытого чата (3/мин) — весь
            // список чатов жёг бы rl:presence (30/мин).
            if let uid = CurrentChat.shared.openPeerUserId, self.presenceSubs.contains(uid) {
                self.send(event: "presence_subscribe", data: ["userId": uid])
            }
            // детект «зомби»-сокета: молча сдохшее соединение (send уходит в никуда, presence протухает,
            // «онлайн» врёт) ловим ping'ом → реконнект переустановит presence. Реальный кейс: iPad открыт,
            // но у собеседника «был в сети 24 мин назад».
            task.sendPing { [weak self] error in
                guard let self, task === self.task, error != nil else { return }
                self.scheduleReconnect()
            }
        }
        RunLoop.main.add(timer, forMode: .common)   // .common — тикает и во время прокрутки
        heartbeat = timer
    }

    private func scheduleReconnect() {
        stopHeartbeat()
        if isOpen { CallDiag.log("🔌 WS оборвался — переподключение") }
        isOpen = false
        isConnecting = false
        onConnectionState?(false)      // связи нет → шапка покажет «Соединение…»
        guard !isStopped else { return }
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)     // экспоненциальный backoff до 30с
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isStopped else { return }
            self.connect()
        }
    }
}
