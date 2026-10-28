import Foundation
import Combine

// Язык интерфейса.
//
// Базовый язык кода — русский: ключом перевода служит сама русская строка. Так wrapper вокруг
// существующего текста получается механическим (`Text(L("Отправить"))` → `Text(L("Отправить"))`),
// а пропущенный перевод виден сразу — на экране остаётся русская фраза, а не «missing_key».
//
// Переводы лежат словарём в коде (`Strings.en`), а не в `.strings`-файлах: словарь одинаково
// доступен приложению и расширению уведомлений, переключается на лету и не требует возни с
// ресурсами в проекте. Когда языков станет больше двух, это стоит перенести в String Catalog.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case ru
    case en

    public var id: String { rawValue }

    // Название в списке выбора — на своём языке, как принято в системных настройках.
    public var title: String {
        switch self {
        case .system: return L("Системный")
        case .ru:     return "Русский"
        case .en:     return "English"
        }
    }
}

@MainActor
public final class LanguageStore: ObservableObject {
    public static let shared = LanguageStore()

    private static let key = "appLanguage"

    // App Group, а не стандартные defaults: тем же выбором пользуется расширение уведомлений,
    // которое формирует текст баннера. Иначе приложение было бы на английском, а уведомления
    // приходили бы на русском.
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: AppGroup.identifier) ?? .standard
    }

    @Published public var language: AppLanguage {
        didSet {
            Self.defaults.set(language.rawValue, forKey: Self.key)
            Localization.resolved = Self.resolve(language)
        }
    }

    private init() {
        let saved = Self.defaults.string(forKey: Self.key).flatMap(AppLanguage.init) ?? .system
        language = saved
        Localization.resolved = Self.resolve(saved)
    }

    // Системный язык → ru, если система просит русский; во ВСЕХ остальных случаях английский.
    // Español, 中文, неопределённый — всё это «не русский», и показывать такому человеку русский
    // интерфейс хуже, чем английский.
    static func resolve(_ language: AppLanguage) -> AppLanguage {
        switch language {
        case .ru, .en:
            return language
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"

            return preferred.hasPrefix("ru") ? .ru : .en
        }
    }

    // Локаль для форматирования дат и чисел. Без неё «вчера» и названия месяцев остались бы
    // на системном языке, даже когда интерфейс переключён вручную.
    public var locale: Locale {
        Locale(identifier: Localization.resolved == .ru ? "ru_RU" : "en_US")
    }
}

// Разрешённый язык хранится отдельно от стора: к нему обращаются из фоновых контекстов и из
// расширения, где @MainActor-стор поднимать незачем.
public enum Localization {
    nonisolated(unsafe) public static var resolved: AppLanguage = {
        let saved = UserDefaults(suiteName: AppGroup.identifier)?.string(forKey: "appLanguage")
        let language = saved.flatMap(AppLanguage.init) ?? .system

        switch language {
        case .ru, .en: return language
        case .system:  return (Locale.preferredLanguages.first ?? "en").hasPrefix("ru") ? .ru : .en
        }
    }()
}

// Перевод строки. Русский — базовый язык, поэтому для него ключ и есть результат.
public func L(_ key: String) -> String {
    guard Localization.resolved == .en else { return key }

    return Strings.en[key] ?? key
}

// Перевод с подстановкой. Отдельная функция, потому что порядок аргументов в переводе может
// отличаться от русского оригинала — интерполяция строки такого не позволяет.
public func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}

// Множественное число. Русскому нужно ТРИ формы, английскому две, и правило выбора у них разное —
// подстановкой одной строки это не решается.
//
// ⚠️ До локализации в коде было «\(n) файла» — неверно и по-русски: «1 файла», «5 файла».
// Локализация лишь вывела наружу то, что было сломано и раньше.
public func LPlural(_ count: Int, ru: (one: String, few: String, many: String),
                    en: (one: String, other: String)) -> String {
    if Localization.resolved == .en {
        return "\(count) \(count == 1 ? en.one : en.other)"
    }

    let mod100 = count % 100
    let mod10 = count % 10

    // 11–14 — исключение: «11 файлов», хотя оканчиваются на 1–4
    if (11...14).contains(mod100) { return "\(count) \(ru.many)" }
    if mod10 == 1 { return "\(count) \(ru.one)" }
    if (2...4).contains(mod10) { return "\(count) \(ru.few)" }

    return "\(count) \(ru.many)"
}

// Готовые счётчики, чтобы формы не расползались по коду.
public enum Plural {
    public static func files(_ n: Int) -> String {
        LPlural(n, ru: ("файл", "файла", "файлов"), en: ("file", "files"))
    }

    public static func messages(_ n: Int) -> String {
        LPlural(n, ru: ("сообщение", "сообщения", "сообщений"), en: ("message", "messages"))
    }
}
