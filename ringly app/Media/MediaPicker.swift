import SwiftUI
import Photos
import PhotosUI
import AVKit
import Combine

// Выбор медиа для отправки — по образцу Telegram: всплывающая шторка с сеткой медиатеки и
// нумерованным выбором, подписью и кнопкой отправки; тап по фото открывает его на весь экран.
//
// ⚠️ Своя сетка требует доступа к медиатеке (системный PhotosPicker работал без разрешения, потому
// что живёт в отдельном процессе). Просим полный доступ, уважаем «только выбранные» (кнопка
// «Изменить» открывает системный выбор), а при отказе остаётся системный PhotosPicker — отправка
// медиа не должна зависеть от того, дал ли человек доступ ко всей медиатеке.

extension PHAsset: @retroactive Identifiable {
    public var id: String { localIdentifier }
}

// ---- медиатека ----

@MainActor
final class PhotoLibraryModel: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published private(set) var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published private(set) var assets: [PHAsset] = []

    let images = PHCachingImageManager()
    private var observing = false

    var hasAccess: Bool { status == .authorized || status == .limited }

    func start() async {
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard hasAccess else { return }
        if !observing {
            PHPhotoLibrary.shared().register(self)
            observing = true
        }
        load()
    }

    private func load() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d || mediaType == %d",
                                        PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        let result = PHAsset.fetchAssets(with: options)
        var list: [PHAsset] = []
        list.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in list.append(asset) }
        assets = list
    }

    // «Только выбранные фото»: человек добавил или убрал доступные снимки — перечитываем сетку
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in self.load() }
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }
}

// ---- шторка выбора ----

struct MediaPickerSheet: View {
    @Binding var caption: String
    let maxCount: Int
    let onSend: ([PHAsset]) -> Void
    let onSystemPicked: ([PhotosPickerItem]) -> Void     // запасной путь без доступа к медиатеке

    @Environment(\.dismiss) private var dismiss
    @StateObject private var library = PhotoLibraryModel()
    @State private var selected: [String] = []           // localIdentifier в порядке выбора
    @State private var preview: PreviewRequest?
    @State private var systemItems: [PhotosPickerItem] = []
    @Namespace private var zoom

    struct PreviewRequest: Identifiable {
        let id = UUID()
        let start: String
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !selected.isEmpty {
                PickerCaptionBar(caption: $caption, onSend: sendSelected)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.88), value: selected.isEmpty)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        // Сплошной фон, как у Telegram: системное «стекло» шторки просвечивало переписку под ней,
        // и сетка фото тонула в чужих цветах
        .presentationBackground(Color(uiColor: .secondarySystemBackground))
        .task { await library.start() }
        .onChange(of: systemItems) { _, items in
            guard !items.isEmpty else { return }
            onSystemPicked(items)
            dismiss()
        }
        .fullScreenCover(item: $preview) { request in
            MediaPickerPreview(assets: library.assets, start: request.start, images: library.images,
                               selected: $selected, caption: $caption, maxCount: maxCount,
                               onSend: sendFromPreview)
                .modifier(ZoomFromSource(id: request.start, namespace: zoom))
        }
    }

    // ---- шапка ----

    private var header: some View {
        ZStack {
            Text(L("Недавние")).font(.headline)

            HStack(spacing: 10) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AppColor.text)
                        .frame(width: 44, height: 44)
                        .viewerGlass(Circle())
                }
                .buttonStyle(.plain)

                if !selected.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
                        Text("\(selected.count)").font(.system(size: 17, weight: .semibold)).monospacedDigit()
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(ChatView.sendTint, in: Capsule())
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                    .contentTransition(.numericText())
                }

                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .animation(.spring(response: 0.22, dampingFraction: 0.78), value: selected.count)
    }

    // ---- содержимое ----

    @ViewBuilder private var content: some View {
        switch library.status {
        case .authorized, .limited:
            grid
        case .notDetermined:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            noAccess
        }
    }

    private var grid: some View {
        ScrollView {
            if library.status == .limited { limitedBanner }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                ForEach(library.assets) { asset in
                    cell(asset)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func cell(_ asset: PHAsset) -> some View {
        let number = selected.firstIndex(of: asset.localIdentifier).map { $0 + 1 }

        return Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { AssetImage(asset: asset, images: library.images, target: 280, fill: true) }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if asset.mediaType == .video {
                    Text(Self.duration(asset.duration))
                        .font(.caption2.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 2)
                        .padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                SelectionBadge(number: number) { toggle(asset) }
            }
            .contentShape(Rectangle())
            .onTapGesture { preview = PreviewRequest(start: asset.localIdentifier) }
            .modifier(ZoomSource(id: asset.localIdentifier, namespace: zoom))
    }

    private var limitedBanner: some View {
        HStack {
            Text(L("Доступ только к выбранным фото"))
                .font(.footnote).foregroundStyle(AppColor.subtext)
            Spacer()
            Button(L("Изменить")) { LimitedLibrary.present() }
                .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var noAccess: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40)).foregroundStyle(AppColor.subtext)
            Text(L("Нет доступа к фото")).font(.headline)
            Text(L("Разрешите доступ в Настройках — или выберите файлы через системное окно."))
                .font(.subheadline).foregroundStyle(AppColor.subtext)
                .multilineTextAlignment(.center)
            PhotosPicker(selection: $systemItems, maxSelectionCount: maxCount, selectionBehavior: .ordered,
                         matching: .any(of: [.images, .videos]), photoLibrary: .shared()) {
                Text(L("Выбрать в галерее"))
                    .font(.body.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    .background(ChatView.sendTint, in: Capsule())
            }
            Button(L("Открыть Настройки")) {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .font(.subheadline)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // ---- выбор и отправка ----

    private func toggle(_ asset: PHAsset) {
        withAnimation(.spring(response: 0.2, dampingFraction: 0.72)) {
            if let i = selected.firstIndex(of: asset.localIdentifier) {
                selected.remove(at: i)
            } else if selected.count < maxCount {
                selected.append(asset.localIdentifier)
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
        }
    }

    private func sendSelected() {
        let byId = Dictionary(library.assets.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
        let picked = selected.compactMap { byId[$0] }
        guard !picked.isEmpty else { return }
        onSend(picked)
        dismiss()
    }

    // Из полноэкранного просмотра: отмечено что-то — уходит отмеченное, иначе то, что на экране
    // (как в Telegram: открыл одно фото и сразу отправил).
    private func sendFromPreview(_ current: PHAsset) {
        if selected.isEmpty { selected = [current.localIdentifier] }
        sendSelected()
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())

        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// Кружок выбора в углу ячейки: пустой — не выбрано, с номером — порядок в альбоме.
private struct SelectionBadge: View {
    let number: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if let number {
                    Circle().fill(ChatView.sendTint)
                    Text("\(number)").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                } else {
                    Circle().fill(.black.opacity(0.18))
                    Circle().stroke(.white, lineWidth: 1.5)
                }
            }
            .frame(width: 26, height: 26)
            .shadow(color: .black.opacity(0.25), radius: 2)
            // пружинка при выборе — как в Telegram
            .scaleEffect(number == nil ? 1 : 1.08)
            .animation(.spring(response: 0.25, dampingFraction: 0.45), value: number)
            .padding(6)
            // зона нажатия больше кружка: в угол ячейки палец попадает неточно
            .frame(width: 48, height: 48, alignment: .topTrailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// Поле подписи и кнопка отправки внизу шторки и полноэкранного просмотра.
private struct PickerCaptionBar: View {
    @Binding var caption: String
    let onSend: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(L("Добавить подпись…"), text: $caption, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .tint(ChatView.sendTint)
                .padding(.horizontal, 16).padding(.vertical, 11)
                .viewerGlass(RoundedRectangle(cornerRadius: 22, style: .continuous))

            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(ChatView.sendTint, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }
}

// ---- полноэкранный просмотр перед отправкой ----

struct MediaPickerPreview: View {
    let assets: [PHAsset]
    let start: String
    let images: PHCachingImageManager
    @Binding var selected: [String]
    @Binding var caption: String
    let maxCount: Int
    let onSend: (PHAsset) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var currentId: String?

    init(assets: [PHAsset], start: String, images: PHCachingImageManager, selected: Binding<[String]>,
         caption: Binding<String>, maxCount: Int, onSend: @escaping (PHAsset) -> Void) {
        self.assets = assets
        self.start = start
        self.images = images
        _selected = selected
        _caption = caption
        self.maxCount = maxCount
        self.onSend = onSend
        _currentId = State(initialValue: start)
    }

    private var current: PHAsset? {
        assets.first { $0.localIdentifier == currentId } ?? assets.first { $0.localIdentifier == start }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(assets) { asset in
                            PreviewPage(asset: asset, images: images, isCurrent: asset.localIdentifier == currentId)
                                .containerRelativeFrame(.horizontal)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $currentId)
                .scrollIndicators(.hidden)
                .ignoresSafeArea()
                .onAppear { proxy.scrollTo(start) }
            }
        }
        .overlay(alignment: .top) { topBar }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PickerCaptionBar(caption: $caption) { if let current { onSend(current) } }
        }
        .environment(\.colorScheme, .dark)
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .viewerGlass(Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            if let current {
                SelectionBadge(number: selected.firstIndex(of: current.localIdentifier).map { $0 + 1 }) {
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.72)) {
                        if let i = selected.firstIndex(of: current.localIdentifier) {
                            selected.remove(at: i)
                        } else if selected.count < maxCount {
                            selected.append(current.localIdentifier)
                        }
                    }
                }
                .scaleEffect(1.3)
                .padding(.trailing, 10)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }
}

private struct PreviewPage: View {
    let asset: PHAsset
    let images: PHCachingImageManager
    let isCurrent: Bool

    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            AssetImage(asset: asset, images: images, target: 1600, fill: false)

            if asset.mediaType == .video {
                if let player {
                    VideoPlayer(player: player)
                } else {
                    Button { Task { await play() } } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 26)).foregroundStyle(.white)
                            .frame(width: 64, height: 64)
                            .viewerGlass(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onChange(of: isCurrent) { _, now in
            if !now { player?.pause(); player = nil }    // ушли со страницы — звук не тянется следом
        }
    }

    private func play() async {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic
        let item: AVPlayerItem? = await withCheckedContinuation { cont in
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                cont.resume(returning: item)
            }
        }
        guard let item else { return }
        let player = AVPlayer(playerItem: item)
        self.player = player
        player.play()
    }
}

// ---- картинка из медиатеки ----

private struct AssetImage: View {
    let asset: PHAsset
    let images: PHCachingImageManager
    let target: CGFloat              // точки по длинной стороне
    let fill: Bool                   // ячейка сетки — с обрезкой, просмотр — целиком

    @State private var image: UIImage?
    @State private var request: PHImageRequestID?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: fill ? .fill : .fit)
            } else {
                Color.gray.opacity(fill ? 0.18 : 0)
            }
        }
        .onAppear { load() }
        .onDisappear {
            if let request { images.cancelImageRequest(request) }
            request = nil
        }
    }

    private func load() {
        let options = PHImageRequestOptions()
        // Сначала приходит быстрая мыльная копия, следом чёткая — обработчик зовётся до двух раз.
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true         // фото в iCloud подтягиваются
        options.resizeMode = .fast
        let scale = UIScreen.main.scale
        request = images.requestImage(for: asset, targetSize: CGSize(width: target * scale, height: target * scale),
                                      contentMode: fill ? .aspectFill : .aspectFit, options: options) { result, _ in
            if let result { image = result }
        }
    }
}

// ---- анимация «из ячейки на весь экран» ----

// Системный zoom-переход (iOS 18): фото вырастает из своей ячейки и смахиванием вниз уходит
// обратно. На iOS 17 его нет — там остаётся обычное появление.
private struct ZoomSource: ViewModifier {
    let id: String
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
    }
}

private struct ZoomFromSource: ViewModifier {
    let id: String
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            content
        }
    }
}

// ---- «только выбранные фото» ----

enum LimitedLibrary {
    @MainActor static func present() {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first else { return }
        var top = root
        while let next = top.presentedViewController { top = next }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top)
    }
}

// ---- чтение выбранного ----

// Выбранное — из системного окна или из своей сетки — приводится к одному виду: картинка в памяти
// или видеофайл во временной папке. Дальше путь у обоих общий (MediaProcessor → шифрование → заливка).
enum PickedSource {
    case item(PhotosPickerItem)
    case asset(PHAsset)

    var isVideo: Bool {
        switch self {
        case .item(let item): item.supportedContentTypes.contains { $0.conforms(to: .movie) }
        case .asset(let asset): asset.mediaType == .video
        }
    }

    struct Loaded {
        var image: UIImage?
        var movie: URL?
    }

    func load() async -> Loaded? {
        switch self {
        case .item(let item):
            // Именно loadTransferable для видео экспортирует ролик из медиатеки и занимает десятки секунд
            if isVideo, let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                return Loaded(movie: movie.url)
            }
            guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                return nil
            }

            return Loaded(image: image)

        case .asset(let asset):
            return isVideo ? await Self.exportVideo(asset) : await Self.loadImage(asset)
        }
    }

    private static func loadImage(_ asset: PHAsset) async -> Loaded? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat     // один ответ — оригинал (с учётом правок)
        options.version = .current
        let data: Data? = await withCheckedContinuation { cont in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                cont.resume(returning: data)
            }
        }

        return data.flatMap(UIImage.init(data:)).map { Loaded(image: $0) }
    }

    // Видео копируем исходным файлом из медиатеки: так приходит и отредактированная версия
    // (.fullSizeVideo), и ролик из iCloud. Перекодирует его уже MediaProcessor.
    private static func exportVideo(_ asset: PHAsset) async -> Loaded? {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .fullSizeVideo })
                ?? resources.first(where: { $0.type == .video }) else { return nil }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("picked-\(UUID().uuidString).mov")
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let ok: Bool = await withCheckedContinuation { cont in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                cont.resume(returning: error == nil)
            }
        }

        return ok ? Loaded(movie: url) : nil
    }
}
