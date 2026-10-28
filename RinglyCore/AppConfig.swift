import Foundation

// Единая точка сетевой конфигурации (используется и приложением, и NotificationService).
// Раньше адрес бэкенда был зашит в трёх местах (APIClient, WebSocketClient, PushService) —
// теперь всё берётся отсюда. Аватарки клиент НЕ конструирует: их presigned-URL
// (media.ringlyapp.net) приходит готовым в ответе сервера.
enum AppConfig {

    enum Environment {
        case production       // боевой бэкенд
        case local            // локальный бэкенд для разработки

        var apiBaseURL: URL {
            switch self {
            case .production: return URL(string: "https://api.ringlyapp.net")!
            case .local:      return URL(string: "http://MacBook-Air-Fedor.local:3000")!
            }
        }
    }

    // Активное окружение выбирается автоматически по типу сборки:
    // Debug (запуск из Xcode для тестов, симулятор, dev-устройство) → локальный бэк,
    // Release/Archive (TestFlight, App Store) → прод. Менять руками не нужно.
    static let current: Environment = {
        #if DEBUG
        return .local
        #else
        return .production
        #endif
    }()

    // Служебные инструменты (тест рекламы, имитация блокировок сети и звонков) — только в Debug и
    // TestFlight, в публичной App Store-сборке их быть не должно (решение владельца). TestFlight и
    // App Store получают ОДИН бинарник, поэтому TestFlight различаем во время работы: у его установки
    // чек песочницы `sandboxReceipt` (так же делает Signal). Не вышло определить → считаем App Store:
    // ошибка в эту сторону лишь прячет инструменты. Флаги, включённые в TestFlight, после обновления
    // из App Store тоже перестают действовать — иначе имитация блокировки осталась бы без выключателя.
    static let testingToolsEnabled: Bool = {
        #if DEBUG
        return true
        #else
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
    }()

    // Базовый адрес REST API.
    static var apiBaseURL: URL { current.apiBaseURL }

    // Ссылка-приглашение на пользователя. Всегда боевой домен, даже в Debug: ссылку копируют, чтобы
    // отправить другому человеку, и локальный адрес разработчика у него не откроется.
    // Обрабатывается как Universal Link (см. AppViewModel.handleDeepLink) и резолвится страницей
    // links.controller.ts на бэкенде.
    static func inviteLink(username: String) -> String {
        var link = "https://ringlyapp.net/u/\(username)"
        // Холодный старт (обход блокировок): подкладываем в ссылку живой мостик. Приглашающий уже
        // в сети, значит мостик рабочий — новая установка получит точку входа, даже если прямой путь
        // заблокирован и список мостиков с сервера не забрать. Самовосстанавливающийся канал:
        // ссылки рождаются у тех, у кого всё работает. См. relay-daemon.md §8.
        if let hint = EndpointResolver.shared.bridgeHintForInvite() {
            link += "?b=\(hint)"
        }
        return link
    }

    // Адрес WebSocket: тот же хост, что у API, схема ws/wss выводится из http/https, путь /ws.
    static var webSocketURL: URL {
        var comps = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false)!
        comps.scheme = (comps.scheme == "https") ? "wss" : "ws"
        comps.path = "/ws"
        return comps.url!
    }
}
