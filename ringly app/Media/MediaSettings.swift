import Foundation
import Combine
import Network

// Настройки автозагрузки медиа. Заложены с первого дня намеренно: без них приложение молча копит
// гигабайты чужих видео, и жалоба «съело всё место» приходит раньше, чем возможность это настроить.
// Локально, как и остальные пользовательские настройки — сервер о них не знает.
final class MediaSettings: ObservableObject {
    static let shared = MediaSettings()

    enum Policy: String, CaseIterable, Identifiable {
        case always            // всегда
        case wifiOnly          // только по Wi-Fi
        case never             // никогда (только по тапу)

        var id: String { rawValue }
        var title: String {
            switch self {
            case .always:   return L("Всегда")
            case .wifiOnly: return L("Только по Wi-Fi")
            case .never:    return L("Никогда")
            }
        }
    }

    private let key = "media.autoDownload"
    private let limitKey = "media.autoDownloadLimitMB"

    @Published var policy: Policy {
        didSet { UserDefaults.standard.set(policy.rawValue, forKey: key) }
    }

    // Потолок автозагрузки: даже по Wi-Fi незачем без спроса тянуть 25-мегабайтное видео.
    @Published var limitMB: Int {
        didSet { UserDefaults.standard.set(limitMB, forKey: limitKey) }
    }

    private let monitor = NWPathMonitor()
    private var onWiFi = true

    private init() {
        let raw = UserDefaults.standard.string(forKey: key) ?? Policy.wifiOnly.rawValue
        policy = Policy(rawValue: raw) ?? .wifiOnly
        let savedLimit = UserDefaults.standard.integer(forKey: limitKey)
        limitMB = savedLimit == 0 ? 10 : savedLimit

        monitor.pathUpdateHandler = { [weak self] path in
            // usesInterfaceType(.wifi) вместо isExpensive: последний true и для персональной точки
            // доступа, а это как раз тот случай, когда качать без спроса не надо
            self?.onWiFi = path.usesInterfaceType(.wifi)
        }
        monitor.start(queue: DispatchQueue(label: "ringly.media.path"))
    }

    // для копии медиа в iCloud (BackupMediaSettings)
    var isOnWiFi: Bool { onWiFi }

    func shouldAutoDownload(bytes: Int) -> Bool {
        guard bytes <= limitMB * 1024 * 1024 else { return false }

        switch policy {
        case .always:   return true
        case .wifiOnly: return onWiFi
        case .never:    return false
        }
    }
}
