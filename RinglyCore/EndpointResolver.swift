import Foundation
import Network
import CryptoKit

// Резолвер эндпоинтов: решает, каким транспортом ходить к серверу — напрямую или через мостик —
// и переключается при недоступности. Живёт НИЖЕ APIClient/WebSocketClient: меняет только адрес/прокси,
// не сетевую логику поверх. Полные правила — ringly-docs/relay-daemon.md §11, ios-relay-client.md.
//
// Мостики двух сортов, и при отказе ведут себя по-разному:
//  • СВОЙ — вставлен руками, пришёл ссылкой ringly-bridge:// или в инвайте. Как прокси в Telegram:
//    отказал → уходим напрямую и пробуем его снова (раз в минуту и при возврате в приложение).
//    Удаляется только руками; обновление списка с сервера его не трогает.
//  • ВЫДАННЫЙ — из распределения сервера (GET /relays/bridges). Отказал → берём другой выданный.
//
// Инварианты:
//  • на мостик переключаемся ТОЛЬКО после проверки (туннель поднят + запрос дошёл до сервера). Раньше
//    неудача туннеля молча откатывала на прямой путь, а экран показывал мостик активным — со стороны
//    выглядело, что обход работает, хотя трафик шёл мимо;
//  • во время звонка НЕ переключаемся (медиа идёт по TURN отдельно; дёргать WS при звонке нельзя);
//  • гистерезис: отказ транспорта — это N неудач подряд, заработавший транспорт «липкий»;
//  • Xray в процессе один: проверка чужого мостика гасит текущий туннель. Поэтому пинг честный
//    только у активного, у остальных — время TCP-подключения (жив ли сервер, но не маскировка).
public final class EndpointResolver {
    public static let shared = EndpointResolver()

    public enum Transport: Equatable {
        case direct
        case bridge(BridgeDescriptor)
    }

    public enum Origin: Equatable {
        case own
        case server
    }

    // Что показать у точки входа на экране «Обход блокировок».
    public enum BridgeStatus: Equatable {
        case idle                   // ещё не проверяли
        case connecting
        case connected(ms: Int?)    // активный; пинг — запрос через мостик до сервера
        case reachable(ms: Int)     // не активный, сервер отвечает по TCP
        case unavailable
    }

    public struct BridgeEntry: Identifiable, Equatable {
        public let bridge: BridgeDescriptor
        public let origin: Origin
        public let status: BridgeStatus
        public let isActive: Bool
        public var id: String { EndpointResolver.key(bridge) }
    }

    // Изменилось то, что видно на экране «Обход блокировок»: статус, пинг, активный транспорт.
    // Постится на главной очереди.
    public static let stateChangedNotification = Notification.Name("EndpointResolver.stateChanged")

    // Сколько подряд неудач до переключения. Один таймаут может быть транзиентом — не дёргаемся.
    private let failureThreshold = 3

    // Повтор своего мостика после отказа. Если мы в это время на выданном мостике — реже и только
    // когда сервер отвечает по TCP: полная проверка гасит рабочий туннель, и каждая попытка к
    // мёртвому мостику стоила бы обрыва связи.
    private static let ownRetryInterval: TimeInterval = 60
    private static let ownRetryFromBridgeInterval: TimeInterval = 600

    // Отказавший мостик не берём при автоматическом выборе столько времени. Руками — можно всегда.
    private static let failureMemory: TimeInterval = 600

    private static let probeTimeout: TimeInterval = 10
    private static let reachTimeout: TimeInterval = 5

    // Вызывается (вне lock) при смене транспорта — WebSocketClient переподключается на новый прокси.
    // Ставится один раз на старте (bootstrap).
    public var onTransportChange: (() -> Void)?

    // Журнал диагностики (скрытое меню). Ставит приложение: CallDiag живёт в его таргете, а этот
    // файл компилируется и в NSE.
    public var log: ((String) -> Void)?

    private let lock = NSLock()
    private var own: [BridgeDescriptor] = []
    private var server: [BridgeDescriptor] = []
    private var transport: Transport = .direct
    private var preferredOwn: String?                  // свой мостик, включённый пользователем
    private var probingKey: String?                    // мостик, который сейчас проверяем
    private var probeGeneration = 0                    // устаревшие проверки не применяем
    private var failedAt: [String: Date] = [:]         // мостики, отказавшие по-настоящему
    private var reach: [String: Int] = [:]             // TCP-пинг неактивных
    private var activePing: Int?
    private var lastOwnProbeAt: Date?
    private var retryTimer: Timer?
    private var consecutiveFailures = 0
    private var callActive = false
    private var tunnel: BridgeTunnel = BridgeTunnelFactory.make()
    private var tunnelKey: String?                     // какой мостик сейчас поднят в туннеле
    private var tunnelPort: Int?                       // его локальный HTTP-прокси
    private var directCheckRunning = false
    private var pathMonitor: NWPathMonitor?
    private var lastPathSignature: String?
    private var cachedSession: URLSession?             // переиспользуемый пул соединений (см. makeSession)

    private let defaults = AppGroup.defaults
    private let transportKey = "relay.transport"      // последний рабочий мостик (host:port)
    private let bridgesKey = "relay.bridges"          // выданные сервером
    private let ownBridgesKey = "relay.ownBridges"
    private let preferredOwnKey = "relay.preferredOwn"
    private let simulateBlockKey = "relay.simulateBlock"

    // Мы внутри app-extension (NSE)? У расширения лимит 24 МБ / 30 с — поднять там Xray-туннель
    // нереально, а попытка съест память и время до вылета. Значит NSE всегда ходит напрямую: если
    // прямой путь заблокирован, расшифровать пуш не выйдет и покажется generic-баннер («Новое
    // сообщение») — штатная деградация, ровно как при любой неуспешной расшифровке.
    private static let isAppExtension = Bundle.main.bundleURL.pathExtension == "appex"

    nonisolated static func key(_ b: BridgeDescriptor) -> String { "\(b.host):\(b.port)" }

    // Метка мостика для журнала вместо адреса. Адреса мостиков — самое ценное в обходе блокировок:
    // журнал пересылают, и адрес из него ушёл бы дальше. Метка стабильна (один мостик — одна метка,
    // видно, какой из них отказал), но адрес из неё не восстановить.
    nonisolated static func label(_ b: BridgeDescriptor) -> String {
        "мостик " + SHA256.hash(data: Data(key(b).utf8)).prefix(2).map { String(format: "%02x", $0) }.joined()
    }

    private init() {
        own = loadBridges(ownBridgesKey)
        server = loadBridges(bridgesKey)
        if defaults.object(forKey: ownBridgesKey) == nil, !server.isEmpty {
            // Раньше свои и выданные лежали одним списком, и обновление с сервера стирало свои.
            // Задним числом их не различить — считаем все своими: лишний удалить можно руками,
            // а потерянный свой мостик значит остаться без связи.
            own = server
            server = []
            saveBridges(own, ownBridgesKey)
            saveBridges(server, bridgesKey)
        }
        preferredOwn = defaults.string(forKey: preferredOwnKey)

        guard !Self.isAppExtension else { return }

        // Вернуться туда, где были. До ответа проверки ходим напрямую: подключаемся только к тому,
        // что реально отвечает.
        let last = defaults.string(forKey: transportKey)
        let restore = allBridgesLocked().first { Self.key($0.bridge) == last || $0.bridge.host == last }?.bridge
            ?? own.first { Self.key($0) == preferredOwn }
        DispatchQueue.main.async {
            self.installRetryTimer()
            self.installPathMonitor()
            if let restore {
                self.startProbe(restore, reason: "восстановление после запуска")
            } else {
                self.checkDirect(reason: "запуск")
            }
        }
    }

    // MARK: - Текущий транспорт

    public var current: Transport {
        lock.lock(); defer { lock.unlock() }
        return transport
    }

    // Точки входа со статусами — для экрана «Обход блокировок». Свои сверху.
    public var entries: [BridgeEntry] {
        lock.lock(); defer { lock.unlock() }
        return allBridgesLocked().map { item in
            let k = Self.key(item.bridge)
            let active: Bool
            if case .bridge(let b) = transport, Self.key(b) == k { active = true } else { active = false }
            return BridgeEntry(bridge: item.bridge, origin: item.origin,
                               status: statusLocked(k, active: active), isActive: active)
        }
    }

    // Доступен ли транспорт через мостик вообще: без LibXray.xcframework мостики бесполезны,
    // и UI обязан сказать об этом прямо, а не делать вид, что подключение возможно.
    public var isTunnelAvailable: Bool { tunnel.isAvailable }

    // MARK: - Выбор пользователя

    // Подключиться к точке входа (нажал на строку или «Подключить»). Свой мостик становится
    // включённым — его будем пробовать снова после отказа. Выбор выданного включённый свой снимает.
    public func connect(host: String, port: Int) {
        lock.lock()
        guard let item = allBridgesLocked().first(where: { $0.bridge.host == host && $0.bridge.port == port }) else {
            lock.unlock(); return
        }
        setPreferredLocked(item.origin == .own ? Self.key(item.bridge) : nil)
        lock.unlock()
        startProbe(item.bridge, reason: "выбран вручную")
    }

    // Вернуться на прямое подключение и перестать пробовать свой мостик.
    public func selectDirect() {
        lock.lock()
        setPreferredLocked(nil)
        probeGeneration += 1          // идущая проверка больше не применится
        probingKey = nil
        let changed = transport != .direct
        transport = .direct
        consecutiveFailures = 0
        transportChangedLocked()
        stopTunnelLocked()
        lock.unlock()
        emit("🌉 выбрано прямое подключение")
        if changed { onTransportChange?() }
        notifyState()
    }

    // Убрать свою точку входа. Выданные не удаляются: их список ведёт сервер.
    public func removeBridge(host: String, port: Int) {
        lock.lock()
        let k = "\(host):\(port)"
        own.removeAll { Self.key($0) == k }
        saveBridges(own, ownBridgesKey)
        if preferredOwn == k { setPreferredLocked(nil) }
        if probingKey == k { probeGeneration += 1; probingKey = nil; stopTunnelLocked() }
        var changed = false
        if case .bridge(let b) = transport, Self.key(b) == k {
            transport = .direct
            transportChangedLocked()
            stopTunnelLocked()
            changed = true
        }
        lock.unlock()
        if changed { onTransportChange?() }
        notifyState()
    }

    // Приложение вернулось на передний план: сразу пробуем включённый свой мостик, если сейчас не на нём.
    //
    // ⚠️ Туннель при этом поднимается заново. Пока приложение спит в фоне, iOS отбирает у него
    // слушающие сокеты (TN2277) — а туннель и есть локальный прокси Xray на 127.0.0.1. Xray считает
    // себя запущенным, но порт мёртв: после возврата все запросы падали, три неудачи подряд —
    // и резолвер «честно» уходил с мостика напрямую. Закрывать туннель при уходе в фон нельзя:
    // через него ещё уходит последний кадр WebSocket (presence_inactive). Во время звонка приложение
    // не засыпает, сокет живой — и транспорт тогда трогать нельзя вообще.
    public func appBecameActive() {
        if Self.isAppExtension { return }
        lock.lock()
        lastOwnProbeAt = nil
        var restarted = false
        if case .bridge = transport, !callActive, tunnelKey != nil {
            stopTunnelLocked()
            dropSessionLocked()   // следующий makeSession поднимет туннель на свежем сокете
            restarted = true
        }
        lock.unlock()
        if restarted { emit("🌉 возврат в приложение — туннель перезапущен (iOS отбирает сокеты в фоне)") }
        retryOwnIfNeeded()
        checkDirect(reason: "возврат в приложение")
    }

    // Работаем через мостик — порт его локального HTTP-прокси (для TURN через мостик). nil — напрямую.
    public var activeBridgeProxyPort: Int? {
        lock.lock(); defer { lock.unlock() }
        guard case .bridge(let b) = transport, tunnelKey == Self.key(b) else { return nil }
        return tunnelPort
    }

    public var isOnBridge: Bool {
        if case .bridge = current { return true }
        return false
    }

    // MARK: - Быстрая проверка прямого пути

    // Блокировка обычно не отвечает отказом, а молча отбрасывает пакеты: каждый запрос ждёт полный
    // таймаут URLSession (60 с), и три неудачи подряд набирались бы около минуты, а то и дольше.
    // Поэтому в узловых моментах (запуск, возврат в приложение, первая неудача, смена сети) отдельно
    // стучимся в /health напрямую с коротким таймаутом. Не ответил — сразу берём годный мостик.
    // Любой HTTP-ответ, даже 5xx, — путь жив: мостик от упавшего сервера не спасёт.
    private static let directCheckTimeout: TimeInterval = 5

    private func checkDirect(reason: String) {
        if Self.isAppExtension { return }
        lock.lock()
        guard transport == .direct, !directCheckRunning, probingKey == nil, !callActive,
              firstUsableLocked() != nil
        else { lock.unlock(); return }
        directCheckRunning = true
        let proxy = simulateBlock ? Self.proxy(port: Self.blackholePort) : nil
        lock.unlock()

        Task {
            let reachable = await Self.directReachable(proxy: proxy)
            let next = finishDirectCheck(reachable: reachable)
            guard !reachable else { return }
            emit("🌉 прямой путь не ответил за \(Int(Self.directCheckTimeout)) с (\(reason))")
            if let next { startProbe(next, reason: "прямой путь не отвечает") }
        }
    }

    // Синхронно: NSLock в async-функциях недоступен.
    private func finishDirectCheck(reachable: Bool) -> BridgeDescriptor? {
        lock.lock(); defer { lock.unlock() }
        directCheckRunning = false
        guard !reachable, transport == .direct, probingKey == nil, !callActive else { return nil }
        return firstUsableLocked()
    }

    private static func directReachable(proxy: [AnyHashable: Any]?) async -> Bool {
        let cfg = URLSessionConfiguration.ephemeral
        if let proxy { cfg.connectionProxyDictionary = proxy }
        cfg.timeoutIntervalForRequest = directCheckTimeout
        cfg.timeoutIntervalForResource = directCheckTimeout
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }

        var req = URLRequest(url: AppConfig.apiBaseURL.appendingPathComponent("health"))
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = directCheckTimeout
        return (try? await session.data(for: req)) != nil
    }

    // Смена сети (ушёл с домашнего Wi-Fi на сотовую) — частый момент, когда прямой путь пропадает.
    private func installPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let signature = path.availableInterfaces.map { $0.name }.joined(separator: ",")
                + "|" + (path.status == .satisfied ? "up" : "down")
            DispatchQueue.main.async {
                guard let self else { return }
                defer { self.lastPathSignature = signature }
                guard let previous = self.lastPathSignature, previous != signature,
                      path.status == .satisfied
                else { return }
                // дать новой сети секунду устояться: первые запросы сразу после смены часто падают сами
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.checkDirect(reason: "сменилась сеть") }
            }
        }
        monitor.start(queue: .global(qos: .utility))
        pathMonitor = monitor
    }

    // MARK: - Имитация блокировки (скрытое меню)

    // Прямой путь к API заведомо не работает: запросы уходят в прокси на порт, где никто не слушает.
    // Мостики (их проверка идёт через свою сессию с туннелем) и TCP-пинг не затронуты — то есть
    // ровно то, что видит человек, у которого заблокирован адрес сервера. DPI так не воспроизвести.
    // Флаг в App Group: NSE тоже ходит напрямую и при настоящей блокировке так же не достучится.
    public var simulateBlock: Bool { AppConfig.testingToolsEnabled && defaults.bool(forKey: simulateBlockKey) }

    public func setSimulateBlock(_ on: Bool) {
        lock.lock()
        defaults.set(on, forKey: simulateBlockKey)
        consecutiveFailures = 0
        firstFailureAt = nil
        dropSessionLocked()
        let onDirect = transport == .direct
        lock.unlock()
        emit(on ? "🌉 имитация блокировки ВКЛЮЧЕНА: прямой путь к серверу закрыт"
                : "🌉 имитация блокировки выключена")
        if onDirect { onTransportChange?() }   // WS переподключится уже по новым правилам
        notifyState()
        if on { checkDirect(reason: "включена имитация") }
    }

    // Порт discard на локальном адресе: на iOS его никто не слушает → мгновенный отказ соединения.
    private static let blackholePort = 9

    // MARK: - Сессии

    // Прокси-словарь для URLSessionConfiguration. nil — прямой путь. Для мостика поднимает (при
    // необходимости) локальный туннель и возвращает HTTP-прокси на 127.0.0.1. ok=false — туннель не
    // поднялся: запрос уйдёт напрямую, а мостик уже объявлен упавшим (сессию такую не кэшируем).
    private func proxyConfigurationLocked() -> (proxy: [AnyHashable: Any]?, ok: Bool) {
        let direct = simulateBlock ? Self.proxy(port: Self.blackholePort) : nil
        if Self.isAppExtension { return (direct, true) }   // см. isAppExtension: в NSE туннель не поднимаем

        guard case .bridge(let b) = transport else { return (direct, true) }
        do {
            return (Self.proxy(port: try ensureTunnelLocked(for: b)), true)
        } catch {
            emit("🌉 туннель к \(Self.label(b)) упал и не поднимается: \(error.localizedDescription)")
            DispatchQueue.main.async { self.bridgeDown(b, reason: "туннель не поднимается") }
            return (nil, false)
        }
    }

    // iOS в URLSession поддерживает только HTTP-прокси (SOCKS-ключи недоступны). Inbound Xray
    // принимает HTTP CONNECT — этого достаточно и для HTTPS, и для wss.
    //
    // ⚠️ HTTPS-ключи ОБЯЗАТЕЛЬНЫ. Ключи HTTP* действуют только на http:// — запросы https:// с ними
    // молча идут НАПРЯМУЮ (проверено: с одними HTTP*-ключами на мёртвый порт https-запрос проходит,
    // с HTTPS* — отказ). Так весь REST ходил мимо мостика, через туннель шёл только WebSocket, а
    // проверка мостика давала ложное «подключено». Константы kCFNetworkProxiesHTTPS* на iOS
    // недоступны, но сами строковые ключи CFNetwork понимает — отсюда литералы.
    private static func proxy(port: Int) -> [AnyHashable: Any] {
        [
            kCFNetworkProxiesHTTPEnable as AnyHashable: 1,
            kCFNetworkProxiesHTTPProxy as AnyHashable: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as AnyHashable: port,
            "HTTPSEnable": 1,
            "HTTPSProxy": "127.0.0.1",
            "HTTPSPort": port
        ]
    }

    // Готовая URLSession с текущим транспортом. delegate нужен для WebSocket; для обычных запросов nil.
    //
    // ⚠️ Сессия КЭШИРУЕТСЯ и переиспользуется. Раньше здесь создавалась новая на каждый запрос, а пул
    // соединений у URLSession свой на экземпляр — то есть каждое отправленное сообщение платило
    // полным TCP+TLS-рукопожатием. На плохой сети это секунды и килобайты, больше любой экономии
    // на формате тела. Побочно уходит и утечка: несозданная заново сессия не держит себя в памяти
    // до инвалидации.
    //
    // Кэш сбрасывается при КАЖДОЙ смене транспорта (`transportChangedLocked`) — иначе запросы
    // продолжали бы идти в прокси уже погашенного туннеля.
    public func makeSession(delegate: URLSessionDelegate? = nil,
                            delegateQueue: OperationQueue? = nil) -> URLSession {
        lock.lock(); defer { lock.unlock() }

        // У WebSocket своя сессия: делегат у каждого соединения свой, и живёт она ровно столько же.
        // Кэшировать её нечего — она и так создаётся один раз на подключение.
        if delegate != nil {
            return Self.newSession(proxy: proxyConfigurationLocked().proxy,
                                   delegate: delegate, delegateQueue: delegateQueue)
        }

        if let cachedSession { return cachedSession }

        let config = proxyConfigurationLocked()
        let session = Self.newSession(proxy: config.proxy, delegate: nil, delegateQueue: nil)
        if config.ok { cachedSession = session }

        return session
    }

    private static func newSession(proxy: [AnyHashable: Any]?,
                                   delegate: URLSessionDelegate?,
                                   delegateQueue: OperationQueue?) -> URLSession {
        let cfg = URLSessionConfiguration.default
        if let proxy { cfg.connectionProxyDictionary = proxy }
        return URLSession(configuration: cfg, delegate: delegate, delegateQueue: delegateQueue)
    }

    // Выбросить кэш. finishTasksAndInvalidate, а не invalidateAndCancel: запрос, уже ушедший по
    // старому пути, может ещё успеть пройти — убивать его незачем, а новые пойдут по новому.
    private func dropSessionLocked() {
        cachedSession?.finishTasksAndInvalidate()
        cachedSession = nil
    }

    // Единая точка «транспорт сменился»: сохранить выбор И выбросить сессию. Держать это вместе
    // обязательно — забытая инвалидация означает запросы в прокси уже погашенного туннеля,
    // то есть молчаливую потерю связи вместо переключения.
    private func transportChangedLocked() {
        activePing = nil
        persistTransportLocked()
        dropSessionLocked()
    }

    // MARK: - Проверка мостика

    // Поднять туннель и довести через него запрос до сервера. Только при успехе мостик становится
    // транспортом; пока идёт проверка, трафик остаётся там, где был.
    private func startProbe(_ b: BridgeDescriptor, reason: String) {
        if Self.isAppExtension { return }
        let k = Self.key(b)

        lock.lock()
        if callActive {
            lock.unlock()
            emit("🌉 \(Self.label(b)): подключение отложено — идёт звонок")
            return
        }
        if probingKey == k { lock.unlock(); return }
        probeGeneration += 1
        let generation = probeGeneration
        probingKey = k
        if k == preferredOwn { lastOwnProbeAt = Date() }
        lock.unlock()

        notifyState()
        emit("🌉 подключение: \(Self.label(b)) (\(reason))…")
        Task { await runProbe(b, generation: generation) }
    }

    private func runProbe(_ b: BridgeDescriptor, generation: Int) async {
        guard tunnel.isAvailable else {
            emit("🌉 сборка без LibXray — мостики недоступны, остаёмся на прямом пути")
            finishProbe(b, generation: generation, ping: nil)
            return
        }

        let port: Int
        switch raiseTunnel(for: b, generation: generation) {
        case .stale:
            return
        case .failed(let error):
            emit("🌉 туннель к \(Self.label(b)) не поднялся: \(error.localizedDescription)")
            finishProbe(b, generation: generation, ping: nil)
            return
        case .up(let p):
            port = p
        }
        emit("🌉 туннель поднят: 127.0.0.1:\(port) → \(Self.label(b))")

        // Первый запрос — проверка (в нём рукопожатия TCP/Reality/TLS), второй по тому же
        // соединению — пинг.
        let session = Self.probeSession(proxyPort: port)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await Self.ping(session)
            let ms = try await Self.ping(session)
            emit("🌉 подключено через \(Self.label(b)), пинг \(ms) мс")
            finishProbe(b, generation: generation, ping: ms)
        } catch {
            emit("🌉 через \(Self.label(b)) запрос до сервера не дошёл: \(error.localizedDescription)")
            finishProbe(b, generation: generation, ping: nil)
        }
    }

    private enum TunnelResult {
        case up(Int)
        case failed(Error)
        case stale          // пока шли сюда, выбрали другое
    }

    // Синхронно: NSLock в async-функциях недоступен (между lock и unlock не должно быть await).
    private func raiseTunnel(for b: BridgeDescriptor, generation: Int) -> TunnelResult {
        lock.lock()
        guard generation == probeGeneration else { lock.unlock(); return .stale }
        // Xray один: если сейчас работаем через ДРУГОЙ мостик, его туннель сейчас погаснет —
        // честно уходим на прямой путь на время проверки, а не держим сессию в мёртвый прокси.
        var leftBridge = false
        if case .bridge(let cur) = transport, Self.key(cur) != Self.key(b) {
            transport = .direct
            transportChangedLocked()
            leftBridge = true
        }
        let result: TunnelResult
        do {
            result = .up(try ensureTunnelLocked(for: b))
        } catch {
            result = .failed(error)
        }
        lock.unlock()
        if leftBridge { onTransportChange?() }
        return result
    }

    private func finishProbe(_ b: BridgeDescriptor, generation: Int, ping: Int?) {
        let k = Self.key(b)

        lock.lock()
        guard generation == probeGeneration else { lock.unlock(); return }   // уже выбрали другое
        probingKey = nil
        var changed = false
        var next: BridgeDescriptor?

        if let ping, !callActive {
            failedAt[k] = nil
            if transport != .bridge(b) {
                transport = .bridge(b)
                transportChangedLocked()
                changed = true
            }
            activePing = ping
            consecutiveFailures = 0
            if originLocked(k) == .own { setPreferredLocked(k) }
        } else if ping != nil {
            // проверка прошла, но начался звонок — переключаться нельзя, попробуем позже
            if tunnelKey == k, transport != .bridge(b) { stopTunnelLocked() }
        } else {
            failedAt[k] = Date()
            reach[k] = nil
            if transport == .bridge(b) {
                transport = .direct
                transportChangedLocked()
                changed = true
            }
            if tunnelKey == k { stopTunnelLocked() }
            if originLocked(k) == .server { next = nextServerLocked(after: k) }
        }
        lock.unlock()

        if changed {
            emit(ping != nil ? "🌉 транспорт: через \(Self.label(b))" : "🌉 транспорт: напрямую")
            onTransportChange?()
        }
        notifyState()
        if let next { startProbe(next, reason: "выданный \(k) не отвечает") }
    }

    // Запрос через мостик упал, или туннель не поднимается: свой → напрямую (и пробуем снова позже),
    // выданный → другой выданный.
    private func bridgeDown(_ b: BridgeDescriptor, reason: String) {
        let k = Self.key(b)
        lock.lock()
        guard transport == .bridge(b), !callActive else { lock.unlock(); return }
        failedAt[k] = Date()
        transport = .direct
        consecutiveFailures = 0
        transportChangedLocked()
        stopTunnelLocked()
        let next = originLocked(k) == .server ? nextServerLocked(after: k) : nil
        lock.unlock()

        emit("🌉 \(Self.label(b)) отказал (\(reason)) → " + (next.map { "пробуем \(Self.label($0))" } ?? "напрямую"))
        onTransportChange?()
        notifyState()
        if let next { startProbe(next, reason: "выданный \(k) отказал") }
    }

    // MARK: - Повтор своего мостика

    private func installRetryTimer() {
        retryTimer?.invalidate()
        // Таймер на главном цикле: только у него есть запущенный RunLoop (см. WebSocketClient.heartbeat).
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.retryOwnIfNeeded() }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    private func retryOwnIfNeeded() {
        lock.lock()
        guard !callActive, probingKey == nil,
              let k = preferredOwn, let b = own.first(where: { Self.key($0) == k })
        else { lock.unlock(); return }
        var onOtherBridge = false
        if case .bridge(let cur) = transport {
            if Self.key(cur) == k { lock.unlock(); return }   // уже на нём
            onOtherBridge = true
        }
        let interval = onOtherBridge ? Self.ownRetryFromBridgeInterval : Self.ownRetryInterval
        if let last = lastOwnProbeAt, Date().timeIntervalSince(last) < interval { lock.unlock(); return }
        lastOwnProbeAt = Date()
        lock.unlock()

        guard onOtherBridge else {
            startProbe(b, reason: "повторная попытка")
            return
        }
        Task {
            guard await Self.tcpPing(b) != nil else { return }
            startProbe(b, reason: "повторная попытка, сервер снова отвечает")
        }
    }

    // MARK: - Пинг (экран «Обход блокировок»)

    // Обновить пинги: у активного — запрос через мостик до сервера, у остальных — TCP до их сервера.
    public func refreshPings() async {
        if Self.isAppExtension { return }

        let (active, others) = lock.withLock { () -> (BridgeDescriptor?, [BridgeDescriptor]) in
            var active: BridgeDescriptor?
            if case .bridge(let b) = transport { active = b }
            return (active, allBridgesLocked().map(\.bridge).filter { Self.key($0) != probingKey && $0 != active })
        }

        if let active {
            let session = makeSession()
            if let ms = try? await Self.ping(session) {
                lock.withLock { if transport == .bridge(active) { activePing = ms } }
            }
        }

        await withTaskGroup(of: (String, Int?).self) { group in
            for b in others {
                group.addTask { (Self.key(b), await Self.tcpPing(b)) }
            }
            for await (k, ms) in group {
                lock.withLock { reach[k] = ms }
            }
        }
        notifyState()
    }

    private static func probeSession(proxyPort: Int) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = proxy(port: proxyPort)
        cfg.timeoutIntervalForRequest = probeTimeout
        cfg.timeoutIntervalForResource = probeTimeout
        return URLSession(configuration: cfg)
    }

    // Время одного запроса к /health (публичный, без БД — дешёвый). Бросает, если ответа нет.
    private static func ping(_ session: URLSession) async throws -> Int {
        var req = URLRequest(url: AppConfig.apiBaseURL.appendingPathComponent("health"))
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = probeTimeout
        let start = Date()
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return Int(Date().timeIntervalSince(start) * 1000)
    }

    // Время TCP-подключения к серверу мостика. nil — не ответил за reachTimeout.
    private static func tcpPing(_ b: BridgeDescriptor) async -> Int? {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: b.port)) else { return nil }
        let connection = NWConnection(host: NWEndpoint.Host(b.host), port: port, using: .tcp)
        let once = Once()
        let start = Date()

        return await withCheckedContinuation { continuation in
            let finish: (Int?) -> Void = { value in
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(Int(Date().timeIntervalSince(start) * 1000))
                // .waiting — отказ или нет маршрута: NWConnection будет ждать вечно, нам ответ нужен сейчас
                case .failed, .cancelled, .waiting: finish(nil)
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + reachTimeout) { finish(nil) }
        }
    }

    private final class Once {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    // MARK: - Обратная связь от сетевого слоя

    // Запрос удался: сбрасываем счётчик неудач (текущий транспорт «липкий» — не перепроверяем).
    // Сбрасываем и таймер алерта: следующий обрыв связи — уже новая ситуация, о ней стоит сказать.
    public func reportSuccess() {
        lock.lock()
        consecutiveFailures = 0
        firstFailureAt = nil
        lastStrandedNotifyAt = nil
        lock.unlock()
    }

    // Запрос не прошёл. После порога подряд-неудач и вне звонка — меняем транспорт: с мостика
    // (свой → напрямую, выданный → другой выданный), с прямого — на первый годный мостик.
    // Возвращает true, если транспорт сменился.
    @discardableResult
    public func reportFailure() -> Bool {
        // NSE всегда ходит напрямую (туннель там не поднять), поэтому его неудачи ничего не говорят
        // о работоспособности мостиков — переключать по ним выбор для ВСЕГО приложения нельзя.
        if Self.isAppExtension { return false }

        lock.lock()
        if consecutiveFailures == 0 { firstFailureAt = Date() }   // начало текущей полосы неудач
        consecutiveFailures += 1
        // во время проверки мостика не дёргаемся: она сама решит, куда идти
        guard consecutiveFailures >= failureThreshold, !callActive, probingKey == nil else {
            let first = consecutiveFailures == 1 && transport == .direct
            lock.unlock()
            if first { DispatchQueue.main.async { self.checkDirect(reason: "запрос не прошёл") } }
            return false
        }

        if case .bridge(let b) = transport {
            lock.unlock()
            bridgeDown(b, reason: "\(failureThreshold) неудачи подряд")
            return true
        }

        var next: BridgeDescriptor?
        var stranded = false
        if let usable = firstUsableLocked() {
            next = usable
            consecutiveFailures = 0
        } else {
            // Переключаться некуда И прямой путь не работает — пути наружу нет вообще.
            //
            // ⚠️ Одних трёх неудач подряд МАЛО. Приложение шлёт несколько запросов сразу (синк,
            // беседы, профиль), и перезапуск бэкенда или секундный провал связи выдают три отказа
            // за доли секунды — а пользователь получал окно «ваша сеть блокирует Ringly», хотя
            // ничего никто не блокировал. Отличить блокировку от лежащего сервера клиент не может,
            // поэтому единственный честный признак — ПРОДОЛЖИТЕЛЬНОСТЬ: блокировка не проходит
            // сама через пару секунд.
            let now = Date()
            let lastingLongEnough = firstFailureAt
                .map { now.timeIntervalSince($0) >= Self.strandedMinDuration } ?? false
            let cooledDown = lastStrandedNotifyAt
                .map { now.timeIntervalSince($0) >= Self.strandedCooldown } ?? true

            if lastingLongEnough && cooledDown {
                lastStrandedNotifyAt = now
                stranded = true
            }
        }
        lock.unlock()

        if let next { startProbe(next, reason: "прямой путь не отвечает") }
        if stranded {
            NotificationCenter.default.post(name: Self.strandedNotification, object: nil)
        }
        return false
    }

    // CallManager выставляет на время звонка: запрещает переключение транспорта.
    public func setCallActive(_ active: Bool) {
        lock.lock(); callActive = active; lock.unlock()
    }

    // MARK: - Обновление списка мостиков

    // Подтянуть свежие выданные мостики с сервера (по текущему транспорту). Свои не трогаем.
    public func refreshBridges() async {
        guard let fresh = try? await RelayClient.fetchBridges() else { return }
        applyServerBridges(fresh)
    }

    private func applyServerBridges(_ fresh: [BridgeDescriptor]) {
        lock.lock()
        let ownKeys = Set(own.map(Self.key))
        server = fresh.filter { !ownKeys.contains(Self.key($0)) }
        saveBridges(server, bridgesKey)
        // свежий список — свежий шанс: прошлые отказы выданных забываем
        for b in server { failedAt[Self.key(b)] = nil }
        // если текущий выданный мостик исчез из списка — вернёмся на прямой путь
        var changed = false
        if case .bridge(let b) = transport, originLocked(Self.key(b)) == nil {
            transport = .direct
            transportChangedLocked()
            stopTunnelLocked()
            changed = true
        }
        lock.unlock()
        if changed {
            emit("🌉 текущий мостик пропал из выдачи → напрямую")
            onTransportChange?()
        }
        notifyState()
    }

    // MARK: - Холодный старт (bootstrap мостика в обход сервера выдачи)

    // Мостик для подкладывания в инвайт-ссылку: base64url(JSON дескриптора). Берём тот, что сейчас
    // РАБОТАЕТ у нас (или первый известный) — приглашающий в сети, значит мостик живой.
    // nil, если мостиков нет вообще (тогда ссылка остаётся обычной).
    public func bridgeHintForInvite() -> String? {
        lock.lock()
        let bridge: BridgeDescriptor?
        if case .bridge(let b) = transport { bridge = b } else { bridge = own.first ?? server.first }
        lock.unlock()

        guard let bridge, let data = try? JSONEncoder().encode(bridge) else { return nil }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // Принять мостик из инвайт-ссылки (?b=...) как свой. Не подключаемся: прямой путь, возможно,
    // и так работает — мостик возьмём, когда он откажет. Возвращает true, если мостик новый.
    @discardableResult
    public func acceptBridgeHint(_ encoded: String) -> Bool {
        var b64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }

        guard let data = Data(base64Encoded: b64),
              let bridge = try? JSONDecoder().decode(BridgeDescriptor.self, from: data)
        else { return false }
        return addOwn(bridge)
    }

    // Принять мостик из ссылки `ringly-bridge://...`, которую печатает демон в приватном режиме
    // (`ringly-relay link`) — волонтёр раздаёт её из рук в руки, сервер о таком мостике не знает.
    // Только добавляет; подключает вызывающий (connect). true — мостик новый.
    @discardableResult
    public func acceptBridgeLink(_ link: String) -> Bool {
        guard let bridge = BridgeLink.parse(link) else { return false }
        return addOwn(bridge)
    }

    // Добавляет свой мостик (дедуп по host:port). Если такой был среди выданных — теперь он свой.
    @discardableResult
    private func addOwn(_ bridge: BridgeDescriptor) -> Bool {
        lock.lock()
        let k = Self.key(bridge)
        guard !own.contains(where: { Self.key($0) == k }) else { lock.unlock(); return false }
        own.append(bridge)
        server.removeAll { Self.key($0) == k }
        saveBridges(own, ownBridgesKey)
        saveBridges(server, bridgesKey)
        lock.unlock()
        notifyState()
        return true
    }

    // Совсем нет пути наружу: прямой путь не работает и годных мостиков нет. UI показывает алерт
    // «нужен VPN однократно» — это честный пол схемы (relay-daemon.md §8).
    public var isStranded: Bool {
        lock.lock(); defer { lock.unlock() }
        return transport == .direct && consecutiveFailures >= failureThreshold && firstUsableLocked() == nil
    }

    // Постится, когда путь наружу пропал совсем. UI показывает алерт на любом экране.
    public static let strandedNotification = Notification.Name("EndpointResolver.stranded")

    // Не чаще одного алерта в 10 минут: сетевые сбои идут пачками, и уведомлять на каждый запрос
    // значило бы завалить пользователя одним и тем же окном.
    private static let strandedCooldown: TimeInterval = 600
    private var lastStrandedNotifyAt: Date?

    // Сколько подряд должно не работать, прежде чем сказать «пути наружу нет». Перезапуск бэкенда,
    // пересадка с Wi-Fi на соту и прочие секундные провалы укладываются сильно быстрее.
    private static let strandedMinDuration: TimeInterval = 60
    private var firstFailureAt: Date?

    // MARK: - Выбор (под lock)

    private func allBridgesLocked() -> [(bridge: BridgeDescriptor, origin: Origin)] {
        own.map { ($0, Origin.own) } + server.map { ($0, Origin.server) }
    }

    private func originLocked(_ k: String) -> Origin? {
        if own.contains(where: { Self.key($0) == k }) { return .own }
        if server.contains(where: { Self.key($0) == k }) { return .server }
        return nil
    }

    private func recentlyFailedLocked(_ k: String) -> Bool {
        guard let at = failedAt[k] else { return false }
        return Date().timeIntervalSince(at) < Self.failureMemory
    }

    // С прямого пути: сначала свои (включённый — первым), потом выданные; недавно отказавшие пропускаем.
    private func firstUsableLocked() -> BridgeDescriptor? {
        let ordered = own.filter { Self.key($0) == preferredOwn }
            + own.filter { Self.key($0) != preferredOwn }
            + server
        return ordered.first { !recentlyFailedLocked(Self.key($0)) }
    }

    // Следующий выданный после отказавшего.
    private func nextServerLocked(after k: String) -> BridgeDescriptor? {
        server.first { Self.key($0) != k && !recentlyFailedLocked(Self.key($0)) }
    }

    private func statusLocked(_ k: String, active: Bool) -> BridgeStatus {
        if probingKey == k { return .connecting }
        if active { return .connected(ms: activePing) }
        if failedAt[k] != nil { return .unavailable }
        if let ms = reach[k] { return .reachable(ms: ms) }
        return .idle
    }

    private func setPreferredLocked(_ k: String?) {
        preferredOwn = k
        if let k { defaults.set(k, forKey: preferredOwnKey) } else { defaults.removeObject(forKey: preferredOwnKey) }
    }

    // MARK: - Туннель (под lock)

    private func ensureTunnelLocked(for b: BridgeDescriptor) throws -> Int {
        let k = Self.key(b)
        if tunnelKey == k {
            let port = try tunnel.start(bridge: b) // идемпотентно: вернёт уже поднятый порт
            tunnelPort = port
            return port
        }
        tunnel.stop()
        tunnelKey = nil
        tunnelPort = nil
        let port = try tunnel.start(bridge: b)
        tunnelKey = k
        tunnelPort = port
        return port
    }

    private func stopTunnelLocked() {
        if tunnelKey != nil {
            tunnel.stop()
            tunnelKey = nil
            tunnelPort = nil
        }
    }

    // MARK: - Журнал и уведомления

    // В журнал — без адресов: текст ошибки Xray сам может содержать «dial tcp <IP>:443», поэтому
    // адреса известных мостиков заменяем их метками, а любые оставшиеся IP — заглушкой.
    private func emit(_ text: String) {
        guard let log else { return }
        var line = text
        for item in lock.withLock({ allBridgesLocked() }) {
            line = line.replacingOccurrences(of: item.bridge.host, with: Self.label(item.bridge))
        }
        // 127.0.0.1 оставляем — это наш локальный прокси, не адрес. IPv6 — от 5 групп или с «::»,
        // чтобы не задеть время вида 22:23:10.
        line = line.replacingOccurrences(of: #"\b(?!127\.)\d{1,3}(\.\d{1,3}){3}\b"#, with: "<IP>", options: .regularExpression)
        line = line.replacingOccurrences(of: #"(?:[0-9a-fA-F]{0,4}:){4,7}[0-9a-fA-F]{1,4}|[0-9a-fA-F]{1,4}::[0-9a-fA-F:]*[0-9a-fA-F]"#,
                                         with: "<IP>", options: .regularExpression)
        log(line)
    }

    private func notifyState() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.stateChangedNotification, object: nil)
        }
    }

    // MARK: - Персистентность (App Group)

    private func persistTransportLocked() {
        switch transport {
        case .direct:
            defaults.removeObject(forKey: transportKey)
        case .bridge(let b):
            defaults.set(Self.key(b), forKey: transportKey)
        }
    }

    private func saveBridges(_ bridges: [BridgeDescriptor], _ key: String) {
        if let data = try? JSONEncoder().encode(bridges) {
            defaults.set(data, forKey: key)
        }
    }

    private func loadBridges(_ key: String) -> [BridgeDescriptor] {
        guard let data = defaults.data(forKey: key),
              let bridges = try? JSONDecoder().decode([BridgeDescriptor].self, from: data)
        else { return [] }
        return bridges
    }
}
