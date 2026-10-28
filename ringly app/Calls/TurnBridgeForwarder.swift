import Foundation
import Network

// TURN через мостик: голос и видео внутри того же Reality-туннеля, что и сообщения.
//
// Зачем: WebRTC шлёт медиа сам, мимо прокси URLSession, поэтому обычный TURN (UDP/TCP на порт 3478)
// виден DPI как TURN и режется вместе с адресом сервера. Здесь WebRTC получает TURN-сервер
// `turn:127.0.0.1:<порт>?transport=tcp`, а мы каждое TCP-соединение на этот порт проводим через
// HTTP-прокси Xray (CONNECT) до настоящего TURN. Снаружи это неотличимо от остального трафика мостика.
//
// Цена — TCP: при потерях пакетов голос задерживается, а не пропадает. Поэтому это ЗАПАСНОЙ путь
// без отдельной логики: у relay-кандидатов по TCP самый низкий приоритет в ICE, и выбираются они,
// только когда обычные пути не прошли.
//
// Порт прокси обновляется при каждом запросе ICE-серверов (CallManager.prefetchIce): слушатель
// живёт дольше одного звонка, а туннель мог перезапуститься на другом порту.
//
// nonisolated: всё здесь крутится на своей очереди Network.framework, главный актор ни при чём.
// Изменяемое состояние — под замком.
//
// ⚠️ Слушаем ТОЛЬКО 127.0.0.1: на всех интерфейсах любой в той же Wi-Fi сети получил бы вход
// в туннель волонтёра.
nonisolated final class TurnBridgeForwarder: @unchecked Sendable {
    static let shared = TurnBridgeForwarder()

    private let queue = DispatchQueue(label: "ringly.turn-forwarder")
    private let lock = NSLock()
    private var listener: NWListener?
    private var target: (host: String, port: Int)?
    private var localPort: UInt16?
    private var proxyPort: Int?

    // Локальный порт, ведущий к host:port через HTTP-прокси мостика. nil — не удалось поднять слушатель.
    func port(for host: String, port targetPort: Int, proxyPort: Int) async -> UInt16? {
        let reused: UInt16? = lock.withLock {
            self.proxyPort = proxyPort
            guard let target, target.host == host, target.port == targetPort, listener != nil else { return nil }
            return localPort
        }
        if let reused { return reused }
        stop()

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params) else { return nil }
        listener.newConnectionHandler = { [weak self] client in self?.accept(client, host: host, port: targetPort) }
        lock.withLock {
            self.listener = listener
            self.target = (host, targetPort)
            self.proxyPort = proxyPort
        }

        let port: UInt16? = await withCheckedContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: listener.port?.rawValue) }
                case .failed, .cancelled:
                    if once.claim() { continuation.resume(returning: nil) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        if port == nil { stop() } else { lock.withLock { localPort = port } }
        return port
    }

    var isRunning: Bool { lock.withLock { listener != nil } }

    func stop() {
        let old: NWListener? = lock.withLock {
            defer { listener = nil; localPort = nil; target = nil }
            return listener
        }
        old?.cancel()
    }

    // MARK: - Соединение: клиент (WebRTC) ↔ HTTP-прокси Xray ↔ TURN

    private func accept(_ client: NWConnection, host: String, port: Int) {
        guard let proxyPort = lock.withLock({ self.proxyPort }),
              let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: proxyPort))
        else {
            client.cancel()
            return
        }
        let upstream = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
        let close = Self.closer(client, upstream)

        client.stateUpdateHandler = { state in
            if case .failed = state { close() }
        }
        upstream.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.handshake(client: client, upstream: upstream, host: host, port: port, close: close)
            case .failed:
                close()
            default:
                break
            }
        }
        client.start(queue: queue)
        upstream.start(queue: queue)
    }

    private func handshake(client: NWConnection, upstream: NWConnection,
                           host: String, port: Int, close: @escaping @Sendable () -> Void) {
        let request = "CONNECT \(host):\(port) HTTP/1.1\r\nHost: \(host):\(port)\r\n\r\n"
        upstream.send(content: Data(request.utf8), completion: .contentProcessed { error in
            if error != nil { close(); return }
            self.readResponse(upstream: upstream, buffer: Data()) { leftover in
                guard let leftover else {
                    CallDiag.log("🧊 TURN через мостик: прокси не открыл соединение до TURN")
                    close()
                    return
                }
                let start = {
                    self.pipe(from: client, to: upstream, close: close)
                    self.pipe(from: upstream, to: client, close: close)
                }
                if leftover.isEmpty {
                    start()
                } else {
                    client.send(content: leftover, completion: .contentProcessed { error in
                        if error != nil { close() } else { start() }
                    })
                }
            }
        })
    }

    // Читает ответ на CONNECT до пустой строки. Отдаёт байты, пришедшие сверх заголовков (пусто —
    // нормальный случай), или nil, если прокси ответил не 200.
    private func readResponse(upstream: NWConnection, buffer: Data, done: @escaping (Data?) -> Void) {
        upstream.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }

            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let status = head.split(separator: " ", maxSplits: 2).dropFirst().first
                done(status == "200" ? buffer[end.upperBound...] : nil)
                return
            }
            if isComplete || error != nil || buffer.count > 16 * 1024 {
                done(nil)
                return
            }
            self.readResponse(upstream: upstream, buffer: buffer, done: done)
        }
    }

    private func pipe(from source: NWConnection, to sink: NWConnection, close: @escaping @Sendable () -> Void) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                sink.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil || isComplete { close(); return }
                    self?.pipe(from: source, to: sink, close: close)
                })
                return
            }
            if isComplete || error != nil {
                close()
                return
            }
            self?.pipe(from: source, to: sink, close: close)
        }
    }

    // Закрыть обе стороны ровно один раз, с какой бы стороны ни пришёл обрыв.
    private static func closer(_ a: NWConnection, _ b: NWConnection) -> @Sendable () -> Void {
        let once = Once()
        return {
            guard once.claim() else { return }
            a.cancel()
            b.cancel()
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.withLock {
                if done { return false }
                done = true
                return true
            }
        }
    }
}
