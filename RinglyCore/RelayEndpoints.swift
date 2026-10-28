import Foundation

// Обход блокировок (клиентская часть). Модели ответов сервера выдачи + тонкий клиент поверх APIClient.
// Полный дизайн системы: ringly-docs/relay-daemon.md.

// Описание одного мостика сообщений, полученное от GET /relays/bridges. Сервер отдаёт до двух
// (основной + запасной, см. relay-daemon.md §6). Поля совпадают с тем, что демон публикует при
// регистрации, и с дескриптором ссылки-мостика (ringly-bridge://).
public struct BridgeDescriptor: Codable, Equatable, Sendable {
    public let host: String
    public let port: Int
    public let publicKey: String   // Reality public key (base64url)
    public let shortId: String
    public let sni: String
    public let uuid: String        // VLESS-пользователь
    public let geo: String?

    public init(host: String, port: Int, publicKey: String, shortId: String,
                sni: String, uuid: String, geo: String? = nil) {
        self.host = host; self.port = port; self.publicKey = publicKey
        self.shortId = shortId; self.sni = sni; self.uuid = uuid; self.geo = geo
    }
}

private struct BridgesResponse: Decodable { let bridges: [BridgeDescriptor] }

// Разбор ссылки-мостика, которую печатает демон (`ringly-relay link`) в приватном режиме.
// ⚠️ Формат КОМПАКТНЫЙ (короткие ключи), не совпадает с ответом сервера выдачи — он оптимизирован
// под длину ссылки, которую передают из рук в руки. Держать в синхроне с bridgelink.Descriptor
// в репозитории ringly-relay.
public enum BridgeLink {
    public static let scheme = "ringly-bridge://"

    // Компактное представление: {"h","p","pk","sid","sni","id","msg","call","geo"}
    private struct Compact: Decodable {
        let h: String
        let p: Int
        let pk: String
        let sid: String
        let sni: String
        let id: String
        let msg: Bool?
        let call: Bool?
        let geo: String?
    }

    // Разбирает ringly-bridge://<base64url(json)> в дескриптор. nil — не наша ссылка/битая.
    public static func parse(_ link: String) -> BridgeDescriptor? {
        let s = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix(scheme) else { return nil }

        var b64 = String(s.dropFirst(scheme.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }

        guard let data = Data(base64Encoded: b64),
              let c = try? JSONDecoder().decode(Compact.self, from: data)
        else { return nil }

        return BridgeDescriptor(host: c.h, port: c.p, publicKey: c.pk,
                                shortId: c.sid, sni: c.sni, uuid: c.id, geo: c.geo)
    }
}

// Один TURN-ретранслятор из пары для звонка (GET /relays/turn-pair). Формат совпадает с обычным
// ответом /calls/ice-servers, так что маппинг в RTCIceServer у звонков не меняется.
public struct TurnRelay: Codable, Equatable, Sendable {
    public let urls: [String]
    public let username: String
    public let credential: String
}

private struct TurnPairResponse: Decodable { let relays: [TurnRelay] }

// Клиент выдачи. Ходит через обычный APIClient (то есть сам — по текущему транспорту: напрямую или
// уже через мостик). Осознанно: если прямой путь ещё жив, мостики подтянутся по нему; если нет —
// первичный bootstrap решается иначе (инвайт-ссылка / VPN однократно, relay-daemon.md §8).
public enum RelayClient {
    // До двух живых мостиков для этого аккаунта. Пустой массив — живых мостиков сейчас нет.
    public static func fetchBridges() async throws -> [BridgeDescriptor] {
        let resp: BridgesResponse = try await APIClient.shared.request("relays/bridges")
        return resp.bridges
    }

    // Пара TURN из разных операторов для звонка. geo (ISO-код) — для геоподбора по латентности.
    public static func fetchTurnPair(geo: String? = nil) async throws -> [TurnRelay] {
        let query = geo.map { ["geo": $0] }
        let resp: TurnPairResponse = try await APIClient.shared.request("relays/turn-pair", query: query)
        return resp.relays
    }
}
