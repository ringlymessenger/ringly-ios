import SwiftUI
import ImageIO

// Общая обвязка просмотрщика медиа: что листаем, откуда открыли и куда возвращаться.
//
// Просмотрщик один на чат (см. ChatView), а не свой у каждого бабла: только так можно листать
// ВСЕ медиа переписки, а не одно сообщение, и анимировать возврат в ту миниатюру, на которой
// пользователь в итоге остановился.

struct MediaGalleryItem: Identifiable {
    let key: String              // "<id сообщения>#<номер файла в альбоме>"
    let ref: MediaRef
    let message: LocalMessage

    var id: String { key }

    static func key(_ messageId: String, _ index: Int) -> String { "\(messageId)#\(index)" }
}

struct MediaViewerRequest: Identifiable {
    let id = UUID()
    let items: [MediaGalleryItem]
    let start: Int
}

// Что сделать с сообщением ПОСЛЕ того, как просмотрщик закрылся: всё это действия ленты чата,
// и выполнять их поверх открытого просмотрщика было бы некуда.
enum MediaViewerAction {
    case showInChat(LocalMessage)
    case reply(LocalMessage)
    case forward(LocalMessage)
    case delete(LocalMessage)
}

// Где на экране сейчас каждая миниатюра (в координатах окна). Отсюда анимация открытия берёт
// стартовую рамку, а закрытия — конечную.
//
// Обычный словарь, а НЕ ObservableObject: рамки меняются на каждом кадре прокрутки ленты, и
// публикация этих изменений перерисовывала бы весь чат ради данных, которые нужны лишь в момент
// открытия и закрытия.
@MainActor
enum MediaFrames {
    static var frames: [String: CGRect] = [:]
}

// ---- окружение: связь миниатюр с просмотрщиком ----

private struct MediaMessageIdKey: EnvironmentKey { static let defaultValue: String? = nil }
private struct OpenMediaKey: EnvironmentKey { static let defaultValue: ((String) -> Void)? = nil }
private struct HiddenMediaKey: EnvironmentKey { static let defaultValue: String? = nil }
private struct MediaCornerKey: EnvironmentKey { static let defaultValue: CGFloat = 14 }
private struct MessageLongPressKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }

extension EnvironmentValues {
    // Скругление медиа в ленте. С подписью медиа лежит внутри общего бабла и своих углов не
    // скругляет: верхние срезает форма бабла, нижние упираются в подпись.
    var mediaCornerRadius: CGFloat {
        get { self[MediaCornerKey.self] }
        set { self[MediaCornerKey.self] = newValue }
    }

    // id сообщения, внутри которого рисуется миниатюра. nil — миниатюра не из ленты (например, превью
    // контекстного меню): такая ни открывать просмотрщик, ни регистрировать рамку не должна, иначе
    // рамка превью затёрла бы настоящую.
    var mediaMessageId: String? {
        get { self[MediaMessageIdKey.self] }
        set { self[MediaMessageIdKey.self] = newValue }
    }

    var openMedia: ((String) -> Void)? {
        get { self[OpenMediaKey.self] }
        set { self[OpenMediaKey.self] = newValue }
    }

    // Миниатюра, которая сейчас «улетела» в просмотрщик: на её месте пусто, как в Telegram,
    // иначе во время анимации картинка была бы видна в двух местах сразу.
    var hiddenMediaKey: String? {
        get { self[HiddenMediaKey.self] }
        set { self[HiddenMediaKey.self] = newValue }
    }

    // Открыть меню сообщения, внутри которого лежит миниатюра (см. MediaPress). nil — миниатюра
    // не в ленте (превью меню, просмотрщик): там долгого нажатия нет.
    var messageLongPress: (() -> Void)? {
        get { self[MessageLongPressKey.self] }
        set { self[MessageLongPressKey.self] = newValue }
    }
}

// Тап и долгое нажатие на миниатюре — ОДНИМ жестом на ней самой.
//
// ⚠️ Долгое нажатие нельзя оставлять только на всём сообщении (MessageLongPress): у миниатюры свой
// тап (просмотрщик), и долгое нажатие родителя ждало, пока этот тап «сдастся». На медиа меню
// открывалось заметно позже, чем на тексте. Здесь долгое нажатие с тем же порогом, что у текста,
// и с приоритетом: удержал — меню, отпустил раньше — обычный тап.
struct MediaPress: ViewModifier {
    let onTap: () -> Void
    @Environment(\.messageLongPress) private var longPress

    func body(content: Content) -> some View {
        if let longPress {
            // Порядок важен: долгое нажатие — ВНУТРЕННИЙ жест (у него приоритет, срабатывает по
            // порогу), тап — внешний и ждёт, пока долгое нажатие не сорвётся. В обратном порядке
            // долгое нажатие снова ждало бы тапа; связка `.exclusively(before:)` проверена —
            // в ней короткий тап не срабатывал вовсе.
            content
                .onLongPressGesture(minimumDuration: MessageLongPress.minimumDuration,
                                    maximumDistance: MessageLongPress.maximumDistance) {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    longPress()
                }
                .onTapGesture { onTap() }
        } else {
            content.onTapGesture { onTap() }
        }
    }
}

// Вешается на каждую миниатюру в ленте: помнит её рамку и прячет, пока она открыта.
struct MediaSourceCell: ViewModifier {
    let index: Int

    @Environment(\.mediaMessageId) private var messageId
    @Environment(\.hiddenMediaKey) private var hidden

    func body(content: Content) -> some View {
        let key = messageId.map { MediaGalleryItem.key($0, index) }

        content
            .opacity(key != nil && key == hidden ? 0 : 1)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect in
                if let key { MediaFrames.frames[key] = rect }
            }
    }
}

// Картинки для просмотрщика — уменьшенные до разумного размера и закешированные.
//
// Оригинал с камеры — 12+ Мп: декодировать его целиком на главном потоке значит подвесить анимацию
// открытия. ImageIO сразу отдаёт уменьшенную копию, а 2800 px по длинной стороне хватает и экрану,
// и зуму.
enum MediaImageCache {
    private static let cache = NSCache<NSString, UIImage>()
    private static let maxPixel = 2800

    static func cached(_ url: URL) -> UIImage? {
        cache.object(forKey: url.path as NSString)
    }

    static func load(_ url: URL) async -> UIImage? {
        if let hit = cached(url) { return hit }

        let image = await Task.detached(priority: .userInitiated) { downsample(url) }.value
        if let image { cache.setObject(image, forKey: url.path as NSString) }

        return image
    }

    private static func downsample(_ url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,    // учесть ориентацию из EXIF
            kCGImageSourceShouldCacheImmediately: true,          // декодировать здесь, не при отрисовке
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        return UIImage(cgImage: cg)
    }
}
