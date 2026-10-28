import SwiftUI

// Альбом: несколько фото/видео одним сообщением, сеткой — как в Telegram.
// Раскладка зависит от количества, потому что равномерная сетка на 2 и 3 элемента выглядит пусто.
struct MediaGroupBubble: View {
    let refs: [MediaRef]
    let isMine: Bool

    private var side: CGFloat { MediaLayout.maxWidth }      // ширина всего блока
    @Environment(\.mediaCornerRadius) private var corner
    private let gap: CGFloat = 2

    // Больше четырёх ячеек не рисуем: на последней показываем «+N». Ограничение чисто визуальное,
    // сами файлы никуда не деваются и открываются из просмотрщика листанием.
    private var visible: [MediaRef] { Array(refs.prefix(4)) }
    private var hiddenCount: Int { max(0, refs.count - 4) }

    var body: some View {
        Group {
            switch visible.count {
            case 0:
                // Пустой список — не раскладка на четыре ячейки. Раньше ноль попадал в `default`,
                // а тот безусловно обращается к visible[0…3] → «Index out of range» и падение
                // приложения при каждом открытии чата с такой строкой. Ветку убирать нельзя, даже
                // когда вызывающий код пустой список не передаёт: цена ошибки — краш, а не пустое место.
                EmptyView()
            case 1:
                MediaBubble(ref: visible[0], isMine: isMine)
            case 2:
                HStack(spacing: gap) {
                    cell(0, w: (side - gap) / 2, h: side * 0.75)
                    cell(1, w: (side - gap) / 2, h: side * 0.75)
                }
            case 3:
                // один крупный + два в столбик: так композиция не выглядит обрезанной
                HStack(spacing: gap) {
                    cell(0, w: (side - gap) * 0.6, h: side * 0.8)
                    VStack(spacing: gap) {
                        cell(1, w: (side - gap) * 0.4, h: (side * 0.8 - gap) / 2)
                        cell(2, w: (side - gap) * 0.4, h: (side * 0.8 - gap) / 2)
                    }
                }
            default:
                VStack(spacing: gap) {
                    HStack(spacing: gap) {
                        cell(0, w: (side - gap) / 2, h: (side - gap) / 2)
                        cell(1, w: (side - gap) / 2, h: (side - gap) / 2)
                    }
                    HStack(spacing: gap) {
                        cell(2, w: (side - gap) / 2, h: (side - gap) / 2)
                        cell(3, w: (side - gap) / 2, h: (side - gap) / 2, more: hiddenCount)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner))
    }

    private func cell(_ i: Int, w: CGFloat, h: CGFloat, more: Int = 0) -> some View {
        MediaCell(ref: visible[i], index: i, width: w, height: h, moreCount: more)
    }
}

// Ячейка сетки. Логика загрузки та же, что в одиночном бабле, но без собственных пропорций —
// размер диктует раскладка.
private struct MediaCell: View {
    let ref: MediaRef
    let index: Int
    let width: CGFloat
    let height: CGFloat
    let moreCount: Int

    @ObservedObject private var settings = MediaSettings.shared
    @State private var localFile: URL?
    @State private var loading = false
    @Environment(\.openMedia) private var openMedia
    @Environment(\.mediaMessageId) private var messageId

    private let service = MediaService()

    var body: some View {
        ZStack {
            if let thumb = MediaService.thumbnail(ref) {
                Image(uiImage: thumb)
                    .resizable().scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
                    .blur(radius: localFile == nil && !ref.isPending ? 4 : 0)
            } else {
                Color.gray.opacity(0.25)
                    .overlay(Image(systemName: ref.isVideo ? "video.fill" : "photo.fill")
                        .foregroundStyle(.white.opacity(0.35)))
            }
            if ref.isVideo, let localFile, moreCount == 0 {
                InlineVideo(url: localFile).frame(width: width, height: height)
            }

            if ref.isPending || loading {
                ProgressView().tint(.white)
            } else if moreCount > 0 {
                // «ещё N» поверх последней ячейки — остальные доступны в просмотрщике
                Color.black.opacity(0.55)
                Text("+\(moreCount)").font(.title2.weight(.semibold)).foregroundStyle(.white)
            } else if ref.isVideo, localFile != nil {
                InlineVideoBadge(durationMs: ref.durationMs)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .modifier(MediaSourceCell(index: index))
        .modifier(MediaPress {
            guard !ref.isPending else { return }
            if localFile != nil {
                if let messageId { openMedia?(MediaGalleryItem.key(messageId, index)) }
            } else if !loading {
                Task { await download() }
            }
        })
        .task(id: ref.attachmentId) {
            guard !ref.isPending, localFile == nil, !loading else { return }
            if settings.shouldAutoDownload(bytes: ref.bytes) || ref.bytes == 0 { await download() }
        }
    }

    private func download() async {
        loading = true
        defer { loading = false }
        localFile = await service.localFile(for: ref)
    }
}
