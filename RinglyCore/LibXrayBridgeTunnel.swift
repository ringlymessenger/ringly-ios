import Foundation

#if canImport(LibXray) && RINGLY_BRIDGE_TUNNEL
import LibXray

// Реализация BridgeTunnel поверх libXray (MIT) + Xray-core (MPL-2.0).
//
// Активируется автоматически, как только LibXray.xcframework добавлен в проект (см.
// BridgeTunnelFactory). Без фреймворка файл компилируется в пустоту, работает заглушка.
//
// API libXray — одна функция `LibXrayInvoke(requestJSON) -> responseJSON` в стиле JSON-RPC:
//   {"apiVersion":3,"method":"runXray","payload":{"xrayJson":"..."}}
// → {"success":true,"data":{...}} | {"success":false,"error":"..."}
//
// ⚠️ `apiVersion` сверяется на точное равенство (`validateAPIVersion` в invoke.go), а не «не ниже».
// Разойдясь с версией фреймворка, получим `unsupported apiVersion` на КАЖДЫЙ вызов — туннель молча
// не поднимется. При обновлении LibXray.xcframework сверять `LibXrayAPIVersion` в invoke_model.go.
//
// ⚠️ Xray в процессе ОДИН (глобальное состояние ядра): нельзя держать два туннеля одновременно —
// поэтому start() к другому мостику сначала гасит текущий.
public final class LibXrayBridgeTunnel: BridgeTunnel {

    // Должна совпадать с LibXrayAPIVersion во фреймворке (libXray/invoke_model.go).
    private static let apiVersion = 3

    private let lock = NSLock()
    private var runningHost: String?   // мостик, который сейчас поднят
    private var runningPort: Int?      // локальный порт HTTP-прокси

    public init() {}

    public var isAvailable: Bool { true }

    public func start(bridge: BridgeDescriptor) throws -> Int {
        lock.lock(); defer { lock.unlock() }

        // Идемпотентность: тот же мостик уже поднят — возвращаем его порт.
        if runningHost == bridge.host, let port = runningPort, isRunning() {
            return port
        }
        stopLocked()

        let port = try freePort()
        let configData = try XrayClientConfig.make(bridge: bridge, localPort: port)
        guard let configJSON = String(data: configData, encoding: .utf8) else {
            throw TunnelError.badConfig
        }

        _ = try invoke(method: "runXray", payload: ["xrayJson": configJSON])
        runningHost = bridge.host
        runningPort = port
        return port
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        stopLocked()
    }

    // MARK: - Внутреннее

    private func stopLocked() {
        if runningHost != nil {
            _ = try? invoke(method: "stopXray", payload: nil)
            runningHost = nil
            runningPort = nil
        }
    }

    private func isRunning() -> Bool {
        // `try?` над функцией, которая и бросает, и возвращает опционал, схлопывает два уровня в один:
        // `data` здесь уже развёрнут. И брошенная ошибка, и пустой ответ одинаково означают «не
        // запущен», так что различать их незачем.
        guard let data = try? invoke(method: "getXrayState", payload: nil),
              let running = data["running"] as? Bool
        else { return false }
        return running
    }

    // Свободный локальный порт запрашиваем у самой libXray: она проверяет занятость в этом же
    // процессе, где потом и слушает — свой поиск порта дал бы гонку.
    private func freePort() throws -> Int {
        guard let data = try invoke(method: "getFreePorts", payload: ["count": 1]),
              let ports = data["ports"] as? [Int],
              let port = ports.first
        else { throw TunnelError.noFreePort }
        return port
    }

    // Обёртка над LibXrayInvoke: собирает запрос, разбирает конверт, бросает при success=false.
    @discardableResult
    private func invoke(method: String, payload: [String: Any]?) throws -> [String: Any]? {
        var request: [String: Any] = ["apiVersion": Self.apiVersion, "method": method]
        if let payload { request["payload"] = payload }

        guard let requestData = try? JSONSerialization.data(withJSONObject: request),
              let requestJSON = String(data: requestData, encoding: .utf8)
        else { throw TunnelError.badConfig }

        let responseJSON = LibXrayInvoke(requestJSON)

        guard let responseData = responseJSON.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        else { throw TunnelError.badResponse(responseJSON) }

        if envelope["success"] as? Bool != true {
            throw TunnelError.core(envelope["error"] as? String ?? "unknown")
        }
        return envelope["data"] as? [String: Any]
    }

    enum TunnelError: LocalizedError {
        case badConfig
        case badResponse(String)
        case noFreePort
        case core(String)

        var errorDescription: String? {
            switch self {
            case .badConfig:            return "Не удалось собрать конфиг Xray"
            case .badResponse(let s):   return "Неразбираемый ответ libXray: \(s.prefix(200))"
            case .noFreePort:           return "Нет свободного локального порта"
            case .core(let s):          return "Ошибка Xray: \(s)"
            }
        }
    }
}
#endif
