import SwiftUI

// Размер медиа в ленте — как в Telegram: файл вписывается в рамку по своим пропорциям. Широкое
// видео идёт почти во всю ширину ленты, вертикальное — высоким и уже, а не одной узкой полосой
// фиксированной ширины. Размер считается по ширине/высоте из MediaRef (они есть ещё до скачивания),
// поэтому лента не «прыгает», когда приходит оригинал.
enum MediaLayout {
    // рамка: ширина ленты за вычетом отступов и зазора со стороны собеседника (Spacer 40 в строке)
    static var maxWidth: CGFloat { min(UIScreen.main.bounds.width - 72, 380) }
    static var maxHeight: CGFloat { maxWidth * 1.3 }
    // совсем узкое или совсем плоское не сжимается в полоску — лишнее обрезается (scaledToFill)
    private static let minWidth: CGFloat = 150
    private static let minHeight: CGFloat = 120

    static func size(_ ref: MediaRef) -> CGSize {
        guard ref.width > 0, ref.height > 0 else { return CGSize(width: maxWidth, height: maxWidth * 0.75) }
        let a = aspect(ref)
        let ratio = a.width / a.height
        var w = maxWidth
        var h = w / ratio
        if h > maxHeight {                      // вертикальное: упираемся в высоту, ширина — по пропорции
            h = maxHeight
            w = h * ratio
        }

        return CGSize(width: max(w, minWidth).rounded(), height: max(h, minHeight).rounded())
    }

    // Пропорции для показа. У видео, отправленных до исправления поворота (MediaProcessor.displaySize),
    // ширина и высота в сообщении переставлены: вертикальное записано горизонтальным. Миниатюра
    // всегда снята с учётом поворота — если её ориентация спорит с записанной, верим миниатюре.
    // Такие сообщения уже лежат у получателей, переотправить их нельзя — поэтому чиним при показе.
    static func aspect(_ ref: MediaRef) -> CGSize {
        let w = CGFloat(max(ref.width, 1)), h = CGFloat(max(ref.height, 1))
        guard ref.isVideo, let thumb = MediaService.thumbnail(ref),
              thumb.size.width > 0, thumb.size.height > 0 else { return CGSize(width: w, height: h) }
        let thumbPortrait = thumb.size.height > thumb.size.width
        let refPortrait = h > w

        return thumbPortrait != refPortrait ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    // ширина всего медиа сообщения — по ней тянется подпись под ним; альбом всегда во всю рамку
    static func width(_ refs: [MediaRef]) -> CGFloat {
        refs.count == 1 ? size(refs[0]).width : maxWidth
    }
}

// Медиа в ленте сообщений. Показывает миниатюру из payload СРАЗУ — оригинал качается отдельно
// и только по правилам автозагрузки. Поэтому в офлайне, при выключенной автозагрузке и даже после
// истечения серверного TTL пользователь видит превью и понимает, что за сообщение перед ним.
struct MediaBubble: View {
    let ref: MediaRef
    let isMine: Bool
    var index = 0                                   // номер файла в альбоме (для просмотрщика)

    @ObservedObject private var settings = MediaSettings.shared
    @State private var localFile: URL?
    @State private var loading = false
    @State private var failed = false
    @Environment(\.openMedia) private var openMedia
    @Environment(\.mediaMessageId) private var messageId
    @Environment(\.mediaCornerRadius) private var corner

    private let service = MediaService()

    private var displaySize: CGSize { MediaLayout.size(ref) }

    var body: some View {
        ZStack {
            thumbnailLayer
            // скачанное видео играет само, без звука (миниатюра под ним — до первого кадра)
            if ref.isVideo, let localFile {
                InlineVideo(url: localFile)
                    .frame(width: displaySize.width, height: displaySize.height)
            }
            overlayLayer
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .contentShape(RoundedRectangle(cornerRadius: corner))
        .modifier(MediaSourceCell(index: index))
        .modifier(MediaPress { tap() })
        // id важен: после заливки заготовка (attachmentId == "") подменяется настоящим ref, и без
        // перезапуска задачи бабл остался бы в состоянии «не скачано», хотя файл уже лежит локально
        .task(id: ref.attachmentId) { await autoDownloadIfNeeded() }
    }

    @ViewBuilder private var thumbnailLayer: some View {
        if let thumb = MediaService.thumbnail(ref) {
            Image(uiImage: thumb)
                .resizable().scaledToFill()
                .frame(width: displaySize.width, height: displaySize.height)
                .clipped()
                // до скачивания оригинала миниатюра размыта — честный сигнал «это ещё превью»
                .blur(radius: localFile == nil ? 6 : 0)
        } else {
            // Превью ещё нет: у видео кадр появляется только после экспорта из медиатеки, а бабл
            // мы показываем раньше. Иконка по типу — чтобы это не выглядело сломанной картинкой.
            Color.gray.opacity(0.25)
                .overlay(
                    Image(systemName: ref.isVideo ? "video.fill" : "photo.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.white.opacity(0.35)))
        }
    }

    @ViewBuilder private var overlayLayer: some View {
        if ref.isPending {
            // своё, ещё не залитое: крутилка поверх собственного превью (телеграм-стиль)
            ProgressView()
                .tint(.white)
                .padding(14)
                .background(.black.opacity(0.45), in: Circle())
        } else if loading {
            ProgressView().tint(.white)
        } else if failed {
            badge(icon: "exclamationmark.triangle.fill", text: L("Недоступно"))
        } else if localFile == nil {
            // не скачано: показываем размер, чтобы решение «качать или нет» было осознанным
            badge(icon: ref.isVideo ? "play.circle.fill" : "arrow.down.circle.fill",
                  text: ByteCountFormatter.string(fromByteCount: Int64(ref.bytes), countStyle: .file))
        } else if ref.isVideo {
            // видео уже играет — вместо кнопки «плей» длительность и «без звука», как в Telegram
            InlineVideoBadge(durationMs: ref.durationMs)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func badge(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(text).font(.caption)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.black.opacity(0.55), in: Capsule())
    }

    private func tap() {
        guard !ref.isPending else { return }   // ещё заливается — открывать нечего
        if localFile != nil {
            if let messageId { openMedia?(MediaGalleryItem.key(messageId, index)) }
        } else if !loading {
            Task { await download() }   // ручная загрузка работает всегда, даже если автозагрузка выключена
        }
    }

    private func autoDownloadIfNeeded() async {
        // своё отправленное уже лежит локально — попадём в первую ветку localFile(for:) без сети
        guard !ref.isPending, localFile == nil, !loading else { return }
        if isMine || settings.shouldAutoDownload(bytes: ref.bytes) {
            await download()
        }
    }

    private func download() async {
        loading = true
        defer { loading = false }
        let url = await service.localFile(for: ref)
        localFile = url
        failed = url == nil
    }
}
