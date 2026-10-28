import Foundation

// Генератор клиентского конфига Xray-core (libXray) для мостика сообщений.
//
// Схема: локальный HTTP-прокси на 127.0.0.1:<port>, куда указывает URLSession, и VLESS+Reality
// outbound на мостик:
//   URLSession → 127.0.0.1 (http) → VLESS/Reality → демон-мостик → origin.
//
// Почему HTTP, а не SOCKS: iOS не отдаёт SOCKS-константы для `connectionProxyDictionary`
// (`kCFNetworkProxiesSOCKS*` помечены unavailable), поддерживается только HTTP-прокси. CONNECT
// покрывает и HTTPS, и wss — этого достаточно.
//
// Серверная сторона (демон) поднимает Reality через sing-box; Reality — протокол, реализации Xray и
// sing-box взаимно совместимы. См. ringly-docs/ios-relay-client.md.
public enum XrayClientConfig {

    // Собирает JSON-конфиг Xray: локальный HTTP-прокси localPort → мостик b.
    public static func make(bridge b: BridgeDescriptor, localPort: Int) throws -> Data {
        let conf: [String: Any] = [
            "log": ["loglevel": "warning"],
            "inbounds": [[
                "tag": "local-http",
                "listen": "127.0.0.1",
                "port": localPort,
                "protocol": "http",
                "settings": [:] as [String: Any]
            ]],
            "outbounds": [[
                "tag": "bridge",
                "protocol": "vless",
                "settings": [
                    "vnext": [[
                        "address": b.host,
                        "port": b.port,
                        "users": [[
                            "id": b.uuid,
                            "encryption": "none",   // у VLESS шифрование даёт транспорт (Reality)
                            "flow": Self.flow
                        ]]
                    ]]
                ],
                "streamSettings": [
                    "network": "tcp",
                    "security": "reality",
                    "realitySettings": [
                        "serverName": b.sni,        // заимствованный домен
                        "fingerprint": "chrome",    // uTLS: маскировка отпечатка ClientHello
                        "publicKey": b.publicKey,
                        "shortId": b.shortId,
                        "spiderX": "/"
                    ]
                ]
            ]]
        ]
        return try JSONSerialization.data(withJSONObject: conf, options: [.sortedKeys])
    }

    // VLESS flow для Reality — тот же, что на сервере (bridgelink.Flow в ringly-relay).
    public static let flow = "xtls-rprx-vision"
}
