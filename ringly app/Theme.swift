import SwiftUI
import Combine

// Оформление приложения.
//
// По умолчанию — тёмное: с ним приложение вышло, и это его узнаваемый вид. Светлое включается
// вручную в профиле и запоминается. Системное («как в настройках телефона») сознательно НЕ
// предлагаем: пользователь просил именно выбор из двух, а третий вариант в списке — это ещё и
// вопрос «почему приложение вдруг побелело», когда телефон сам переключится по расписанию.
enum AppTheme: String, CaseIterable, Identifiable {
    case dark
    case light

    var id: String { rawValue }
    var title: String { self == .dark ? "Тёмная" : "Светлая" }
    var icon: String { self == .dark ? "moon.fill" : "sun.max.fill" }
    var colorScheme: ColorScheme { self == .dark ? .dark : .light }
}

@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()
    private static let key = "appTheme"

    @Published var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Self.key) }
    }

    private init() {
        // Незнакомое/отсутствующее значение → тёмная. Настройка локальная и на другие устройства
        // не синхронизируется: это вкус на конкретном экране, а не часть профиля.
        theme = UserDefaults.standard.string(forKey: Self.key).flatMap(AppTheme.init) ?? .dark
    }
}

// Палитра интерфейса.
//
// Раньше цвета были захардкожены под тёмный фон: `Color.black` подложкой и `white.opacity(…)`
// поверх неё. В светлой теме это давало белое на белом, поэтому каждый цвет здесь задан ДЛЯ ОБЕИХ
// тем сразу — через динамический `UIColor`, который сам разрешается по текущей схеме.
//
// Светлая тема повторяет системную раскладку iOS (серый фон + белые карточки), а не «инвертированную
// тёмную»: полупрозрачный чёрный поверх белого даёт грязно-серые карточки без границ.
enum AppColor {
    /// фон экрана
    static let background = dynamic(dark: .black, light: .systemGroupedBackground)
    /// карточки и строки настроек поверх фона
    static let surface = dynamic(dark: UIColor(white: 1, alpha: 0.06), light: .secondarySystemGroupedBackground)
    /// заливка полей ввода и поиска
    static let fill = dynamic(dark: UIColor(white: 1, alpha: 0.08), light: .secondarySystemFill)
    /// обводка полей
    static let stroke = dynamic(dark: UIColor(white: 1, alpha: 0.12), light: UIColor(white: 0, alpha: 0.12))
    /// разделители внутри карточек
    static let hairline = dynamic(dark: UIColor(white: 1, alpha: 0.1), light: .separator)

    /// фирменный фиолетовый: кнопка отправки, волна на экране входа, страница инвайт-ссылки
    /// (`links.controller.ts` на бэкенде — при смене оттенка правится и там)
    static let brand = Color(red: 0.48, green: 0.36, blue: 0.96)

    /// основной текст
    static let text = Color.primary
    /// подписи и второстепенное
    static let subtext = Color.secondary
    /// совсем тихое: шевроны, вспомогательные даты
    static let faint = Color(uiColor: .tertiaryLabel)

    private static func dynamic(dark: UIColor, light: UIColor) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}
