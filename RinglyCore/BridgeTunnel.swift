import Foundation

// Шов интеграции туннеля. Абстрагируем запуск локального прокси, чтобы вся остальная логика
// (EndpointResolver) не зависела от конкретного фреймворка и была тестируема.
//
// Реализация — LibXrayBridgeTunnel (libXray MIT + Xray-core MPL-2.0; НЕ sing-box: он GPL-3.0 и
// заражает приложение при линковке, см. ringly-docs/ios-relay-client.md). Фреймворк подключён
// к таргету приложения, но НЕ к NotificationService — там остаётся UnavailableBridgeTunnel,
// и это правильно: расширение туннель не поднимает (лимит 24 МБ / 30 с).

// Туннель мостика: поднимает локальный прокси к мостику b и возвращает порт 127.0.0.1:<port>,
// на который надо направлять URLSession. Идемпотентен: повторный start с тем же мостиком — no-op.
public protocol BridgeTunnel: AnyObject {
    // true, если этот транспорт вообще доступен в сборке (Libbox подключён).
    var isAvailable: Bool { get }

    // Поднять туннель к мостику. Возвращает локальный порт mixed-прокси. Бросает, если не удалось.
    func start(bridge: BridgeDescriptor) throws -> Int

    // Остановить туннель (при переключении на другой мостик / на прямой путь).
    func stop()
}

// Заглушка там, где LibXray не подключён (расширение уведомлений): мостиков нет, только прямой путь.
public final class UnavailableBridgeTunnel: BridgeTunnel {
    public init() {}
    public var isAvailable: Bool { false }
    public func start(bridge: BridgeDescriptor) throws -> Int {
        throw NSError(domain: "BridgeTunnel", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "LibXray не подключён — транспорт через мостик недоступен"
        ])
    }
    public func stop() {}
}

// Точка, куда EndpointResolver обращается за туннелем. Реализация выбирается АВТОМАТИЧЕСКИ по
// наличию LibXray.xcframework в проекте — правок в коде после добавления фреймворка не требуется.
public enum BridgeTunnelFactory {
    public static var make: () -> BridgeTunnel = {
        // Два условия, и оба обязательны:
        //   canImport        — фреймворк собран (./scripts/build-libxray.sh); без него заглушка,
        //                      и проект всё равно компилируется;
        //   RINGLY_BRIDGE_TUNNEL — таргету туннель РАЗРЕШЁН. Задан только у приложения.
        //
        // ⚠️ Одного canImport мало: Xcode распаковывает срез xcframework в общий BUILT_PRODUCTS_DIR,
        // который лежит в путях поиска у всех таргетов воркспейса. Расширение уведомлений начинает
        // «видеть» модуль, Swift автолинкует его — и NSE падает на линковке, а если бы не упало,
        // потащило бы в себя 90 МБ Go-рантайма ради работы, которую ему делать нельзя.
        #if canImport(LibXray) && RINGLY_BRIDGE_TUNNEL
        return LibXrayBridgeTunnel()
        #else
        return UnavailableBridgeTunnel()
        #endif
    }
}
