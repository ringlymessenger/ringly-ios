import SwiftUI
import AVFoundation
import Combine

// Полноэкранный просмотр медиа — по образцу Telegram.
//
// Открывается и закрывается «из миниатюры»: картинка вырастает из своего места в ленте и туда же
// возвращается. Листается вбок по всем медиа переписки, зумится щипком и двойным тапом, закрывается
// смахиванием вверх или вниз. Тап прячет и показывает панели.
//
// Показывается через fullScreenCover БЕЗ системной анимации и с прозрачным фоном (см. ChatView):
// системный выезд снизу заменён своим — из миниатюры, а при смахивании сквозь фон видна переписка.
struct MediaViewer: View {
    let request: MediaViewerRequest
    let authorName: (LocalMessage) -> String
    let onCurrentChange: (String?) -> Void            // какую миниатюру прятать в ленте
    let onFinish: (MediaViewerAction?) -> Void        // анимация закрытия закончилась

    private enum Phase { case opening, open, closing }

    @State private var phase: Phase = .opening
    @State private var scrollId: String?
    @State private var chromeVisible = true
    @State private var drag: CGSize = .zero
    @State private var dragging = false
    @State private var zoomed = false

    // «Летящая» картинка анимаций открытия и закрытия. Сама лента страниц в это время спрятана:
    // анимировать рамку UIScrollView из SwiftUI нельзя, а подменить её картинкой — незаметно.
    @State private var heroImage: UIImage?
    @State private var heroRect: CGRect = .zero
    @State private var heroCorner: CGFloat = 12
    @State private var heroOpacity: Double = 1
    @State private var backdrop: Double = 0

    @State private var toast: String?
    @State private var saving = false              // идёт сохранение в «Фото» — плашка с крутилкой
    @State private var toastTask: Task<Void, Never>?
    @StateObject private var video = GalleryVideo()

    private static let pageGap: CGFloat = 20          // зазор между фото при листании, как в Telegram
    private static let heroSpring = Animation.spring(response: 0.27, dampingFraction: 0.9)

    init(request: MediaViewerRequest, authorName: @escaping (LocalMessage) -> String,
         onCurrentChange: @escaping (String?) -> Void, onFinish: @escaping (MediaViewerAction?) -> Void) {
        self.request = request
        self.authorName = authorName
        self.onCurrentChange = onCurrentChange
        self.onFinish = onFinish
        _scrollId = State(initialValue: request.items[request.start].key)
    }

    private var items: [MediaGalleryItem] { request.items }

    private var current: MediaGalleryItem {
        items.first { $0.key == scrollId } ?? items[request.start]
    }

    var body: some View {
        ZStack {
            GeometryReader { geo in
                stage(geo.size)
                    .onAppear { open(geo.size) }
                    .onChange(of: closeRequest) { _, req in if let req { close(geo.size, action: req.action) } }
            }
            .ignoresSafeArea()

            chrome
                .opacity(chromeVisible && phase == .open && !dragging ? 1 : 0)
                // спрятанные панели не должны ловить тапы: иначе тап «по пустому месту» вверху
                // попадал бы в невидимую кнопку назад
                .allowsHitTesting(chromeVisible && phase == .open && !dragging)
                // при смахивании панели исчезают СРАЗУ, без плавного ухода — как в Telegram
                .animation(dragging ? nil : .easeInOut(duration: 0.15), value: chromeVisible)
                .animation(dragging ? nil : .easeInOut(duration: 0.15), value: phase)

            if saving || toast != nil {
                HStack(spacing: 8) {
                    if saving { ProgressView().tint(.white) }
                    Text(saving ? L("Сохранение…") : toast ?? "")
                }
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .viewerGlass(Capsule())
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden(!chromeVisible && phase == .open)
        .onChange(of: scrollId) { _, _ in pageChanged() }
    }

    // ---- сцена: фон, страницы, летящая картинка ----

    @ViewBuilder private func stage(_ size: CGSize) -> some View {
        ZStack {
            Color.black.opacity(phase == .open ? 1 - min(1, abs(drag.height) / 500) : backdrop)

            pager(size)
                .opacity(phase == .open ? 1 : 0)
                .allowsHitTesting(phase == .open)

            if phase != .open {
                hero
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func pager(_ size: CGSize) -> some View {
        // Страница шире экрана на зазор, и лента сдвинута на половину зазора влево: при листании
        // между фото видна чёрная полоса, а в покое каждое фото стоит ровно по экрану.
        ScrollViewReader { proxy in
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(items) { item in
                    MediaPage(item: item, isCurrent: item.key == scrollId,
                              drag: item.key == scrollId ? drag : .zero, video: video,
                              onTap: toggleChrome, onDismissPan: { handleDismissPan($0, $1, $2, size) },
                              onZoom: { zoomed = $0 })
                        .padding(.horizontal, Self.pageGap / 2)
                        .frame(width: size.width + Self.pageGap, height: size.height)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $scrollId)
        .scrollIndicators(.hidden)
        .scrollDisabled(dragging)
        // Ленивая лента не всегда встаёт на начальный id из scrollPosition — ставим явно.
        .onAppear { proxy.scrollTo(items[request.start].key, anchor: .leading) }
        }
        // ⚠️ По центру ЯВНО: лента шире экрана на зазор, и без этого она прижималась к левому краю
        // и съезжала вправо на весь зазор.
        .frame(width: size.width + Self.pageGap, height: size.height)
        .position(x: size.width / 2, y: size.height / 2)
    }

    private var hero: some View {
        Group {
            if let heroImage {
                Image(uiImage: heroImage).resizable().scaledToFill()
            } else {
                Color.gray.opacity(0.25)
            }
        }
        .frame(width: max(1, heroRect.width), height: max(1, heroRect.height))
        .clipShape(RoundedRectangle(cornerRadius: heroCorner, style: .continuous))
        .position(x: heroRect.midX, y: heroRect.midY)
        .opacity(heroOpacity)
    }

    // ---- открытие и закрытие ----

    private func fitted(_ ref: MediaRef, in size: CGSize) -> CGRect {
        let aspect = MediaLayout.aspect(ref)

        return AVMakeRect(aspectRatio: aspect, insideRect: CGRect(origin: .zero, size: size))
    }

    private func open(_ size: CGSize) {
        let item = current
        onCurrentChange(item.key)
        let target = fitted(item.ref, in: size)
        heroImage = MediaViewer.localURL(item.ref).flatMap(MediaImageCache.cached) ?? MediaService.thumbnail(item.ref)

        if let source = MediaFrames.frames[item.key], source.width > 0 {
            heroRect = source
            heroCorner = 12
        } else {
            // рамку миниатюры не знаем — проявляемся на месте, чуть подрастая
            heroRect = target.insetBy(dx: target.width * 0.08, dy: target.height * 0.08)
            heroOpacity = 0
        }

        Task {
            // Оригинал декодируем ДО старта полёта: иначе картинка летела бы мыльной миниатюрой
            // (~200px) и резко «щёлкала» в чёткую, когда показывается лента страниц.
            if let url = MediaViewer.localURL(item.ref), let full = await MediaImageCache.load(url) {
                heroImage = full
            }
            withAnimation(Self.heroSpring) {
                heroRect = target
                heroCorner = 0
                heroOpacity = 1
                backdrop = 1
            } completion: {
                phase = .open
            }
        }
    }

    // Запрос на закрытие из панелей. Через состояние, потому что размер сцены известен только
    // внутри GeometryReader.
    private struct CloseRequest: Equatable {
        let id = UUID()
        let action: MediaViewerAction?
        static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    }
    @State private var closeRequest: CloseRequest?

    private func requestClose(_ action: MediaViewerAction? = nil) {
        closeRequest = CloseRequest(action: action)
    }

    private func close(_ size: CGSize, action: MediaViewerAction?) {
        guard phase == .open else { return }
        video.pause()

        let item = current
        let start = fitted(item.ref, in: size).offsetBy(dx: drag.width, dy: drag.height)
        heroImage = MediaViewer.localURL(item.ref).flatMap(MediaImageCache.cached) ?? MediaService.thumbnail(item.ref)
        heroRect = start
        heroCorner = 0
        heroOpacity = 1
        backdrop = 1 - min(1, abs(drag.height) / 500)
        phase = .closing

        // Возвращаемся в миниатюру, только если она на экране. Ушла за край (долистали до старых
        // фото) — улетаем в сторону смахивания и растворяемся, как Telegram.
        let screen = CGRect(origin: .zero, size: size).insetBy(dx: 0, dy: 60)
        let source = MediaFrames.frames[item.key].flatMap { $0.intersects(screen) && $0.width > 0 ? $0 : nil }
        let direction: CGFloat = drag.height < 0 ? -1 : 1

        withAnimation(Self.heroSpring) {
            if let source {
                heroRect = source
                heroCorner = 12
            } else {
                heroRect = start.offsetBy(dx: 0, dy: direction * size.height * 0.35)
                heroOpacity = 0
            }
            backdrop = 0
        } completion: {
            onFinish(action)
        }
    }

    private func handleDismissPan(_ state: UIGestureRecognizer.State, _ t: CGPoint, _ v: CGPoint, _ size: CGSize) {
        switch state {
        case .began, .changed:
            dragging = true
            drag = CGSize(width: t.x, height: t.y)
        default:
            // закрываем по расстоянию ИЛИ по скорости: короткий резкий взмах тоже закрывает
            if abs(t.y) > 110 || abs(v.y) > 900 {
                close(size, action: nil)
                dragging = false
            } else {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) { drag = .zero }
                dragging = false
            }
        }
    }

    private func pageChanged() {
        onCurrentChange(current.key)
        video.detach()
        zoomed = false
    }

    private func toggleChrome() {
        chromeVisible.toggle()
    }

    // ---- панели ----

    private var chrome: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            bottomBar
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            circleButton("chevron.left") { requestClose() }

            Spacer(minLength: 0)

            VStack(spacing: 1) {
                Text(authorName(current.message))
                    .font(.headline).lineLimit(1)
                Text(Self.dateText(current.message.sentAt))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 20).padding(.vertical, 6)
            .viewerGlass(Capsule())

            Spacer(minLength: 0)

            Menu {
                Button { requestClose(.showInChat(current.message)) } label: {
                    Label(L("Показать в чате"), systemImage: "text.bubble")
                }
                Button { Task { await save() } } label: {
                    Label(current.ref.isVideo ? L("Сохранить видео") : L("Сохранить фото"),
                          systemImage: "arrow.down.circle")
                }
                Button { requestClose(.reply(current.message)) } label: {
                    Label(L("Ответить"), systemImage: "arrowshape.turn.up.left")
                }
                if current.message.isMine {
                    Button(role: .destructive) { requestClose(.delete(current.message)) } label: {
                        Label(L("Удалить у всех"), systemImage: "trash")
                    }
                }
            } label: {
                circleIcon("ellipsis")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private var bottomBar: some View {
        VStack(spacing: 14) {
            if current.ref.isVideo, video.key == current.key {
                VideoScrubber(video: video)
                    .padding(.horizontal, 20)
            }

            if items.count > 1 {
                ThumbnailStrip(items: items, currentKey: scrollId) { key in
                    withAnimation(.easeInOut(duration: 0.18)) { scrollId = key }
                }
            }

            HStack {
                circleButton("arrowshape.turn.up.right") { requestClose(.forward(current.message)) }

                Spacer()

                if current.ref.isVideo, video.key == current.key {
                    circleButton(video.playing ? "pause.fill" : "play.fill") { video.toggle() }
                }

                Spacer()

                // удалить у всех — только своё (как и в меню сообщения в ленте)
                if current.message.isMine {
                    circleButton("trash") { requestClose(.delete(current.message)) }
                } else {
                    Color.clear.frame(width: 50, height: 50)
                }
            }
            .padding(.horizontal, 24)
        }
        .padding(.bottom, 8)
    }

    private func circleButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { circleIcon(icon) }
            .buttonStyle(.plain)
    }

    private func circleIcon(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 50, height: 50)
            .viewerGlass(Circle())
            .contentShape(Circle())
    }

    // ---- действия ----

    // Видео сохраняется заметное время (копия файла + запись в медиатеку), и без индикатора казалось,
    // что нажатие не сработало. Пока идёт сохранение — плашка «Сохранение…» с крутилкой, потом итог.
    private func save() async {
        guard !saving else { return }                // второе нажатие во время сохранения — не дублируем
        guard let url = MediaViewer.localURL(current.ref) else {
            showToast(L("Не удалось сохранить"))
            return
        }
        toastTask?.cancel()
        withAnimation { toast = nil; saving = true }
        let result = await MediaSaver.saveToPhotos(url: url, isVideo: current.ref.isVideo)
        withAnimation { saving = false }
        switch result {
        case .saved:  showToast(L("Сохранено"))
        // без доступа — говорим прямо, где его дать: иначе «не удалось» выглядит как поломка
        case .denied: showToast(L("Нет доступа к фото — разрешите в Настройках"))
        case .failed: showToast(L("Не удалось сохранить"))
        }
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { toast = nil }
        }
    }

    // ---- форматирование ----

    static func localURL(_ ref: MediaRef) -> URL? {
        MediaStore.exists(ref.attachmentId, ext: ref.fileExtension)
            ? MediaStore.file(ref.attachmentId, ext: ref.fileExtension) : nil
    }

    static func dateText(_ sentAt: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(sentAt) / 1000)
        let time = ChatView.timeText(sentAt)
        let cal = Calendar.current
        if cal.isDateInToday(date) { return L("сегодня в %@", time) }
        if cal.isDateInYesterday(date) { return L("вчера в %@", time) }

        return L("%@ в %@", ChatView.dateSeparatorText(sentAt), time)
    }
}

// ---- страница ----

private struct MediaPage: View {
    let item: MediaGalleryItem
    let isCurrent: Bool
    let drag: CGSize
    @ObservedObject var video: GalleryVideo
    let onTap: () -> Void
    let onDismissPan: (UIGestureRecognizer.State, CGPoint, CGPoint) -> Void
    let onZoom: (Bool) -> Void

    @State private var file: URL?
    @State private var image: UIImage?
    @State private var loading = false
    @State private var failed = false

    private let service = MediaService()

    var body: some View {
        ZoomableMediaView(
            image: image ?? MediaService.thumbnail(item.ref),
            player: video.key == item.key ? video.player : nil,
            aspect: MediaLayout.aspect(item.ref),
            isCurrent: isCurrent,
            onTap: onTap, onDismissPan: onDismissPan, onZoom: onZoom)
        .overlay {
            if loading {
                ProgressView().tint(.white).controlSize(.large)
            } else if failed {
                Label(L("Недоступно"), systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .viewerGlass(Capsule())
            }
        }
        .offset(drag)
        // Соседние страницы тоже подгружаются: лента материализует их заранее, и к моменту
        // перелистывания оригинал уже на месте. В просмотрщике пользователь листает сам, поэтому
        // правила автозагрузки здесь не действуют — как и при ручном тапе по миниатюре.
        .task(id: item.key) { await load() }
        .onChange(of: isCurrent) { _, _ in attachVideoIfNeeded() }
        .onChange(of: file) { _, _ in attachVideoIfNeeded() }
    }

    private func load() async {
        if let url = MediaViewer.localURL(item.ref) {
            file = url
        } else {
            loading = true
            file = await service.localFile(for: item.ref)
            loading = false
            failed = file == nil
        }
        if let file, !item.ref.isVideo { image = await MediaImageCache.load(file) }
        attachVideoIfNeeded()
    }

    private func attachVideoIfNeeded() {
        guard item.ref.isVideo, isCurrent, let file else { return }
        video.attach(key: item.key, url: file)
    }
}

// ---- видео ----

// Один плеер на весь просмотрщик — у текущей страницы. Соседние видео показывают постер: играть
// звук двух роликов сразу (или держать в памяти десяток плееров) незачем.
@MainActor
final class GalleryVideo: ObservableObject {
    @Published private(set) var key: String?
    @Published private(set) var player: AVPlayer?
    @Published private(set) var playing = false
    @Published private(set) var current: Double = 0
    @Published private(set) var duration: Double = 0

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    func attach(key: String, url: URL) {
        guard self.key != key else { return }
        detach()

        let player = AVPlayer(url: url)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.current = time.seconds
                if let d = player.currentItem?.duration.seconds, d.isFinite { self.duration = d }
            }
        }
        // доиграли — встаём в начало на паузу, чтобы повтор был одним нажатием
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                             object: player.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.playing = false
                player.seek(to: .zero)
            }
        }

        self.key = key
        self.player = player
        Self.enableSound()
        player.play()
        playing = true
    }

    // ⚠️ Без этого видео играет БЕЗ ЗВУКА, когда на iPhone включён беззвучный режим (переключатель
    // сбоку): у приложения по умолчанию категория аудиосессии .soloAmbient, а она переключателю
    // подчиняется. Пользователь, нажавший «смотреть видео», звук ждёт — как в Telegram и «Фото»,
    // поэтому категория .playback. Во время звонка сессию не трогаем: ею владеет WebRTC/CallKit,
    // и смена категории оборвала бы разговор.
    private static func enableSound() {
        guard CallManager.shared.phase == .idle else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }

    // Отдать звук обратно: остальные приложения (музыка, подкаст), приглушённые на время ролика,
    // продолжают играть.
    private static func releaseSound() {
        guard CallManager.shared.phase == .idle else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        try? session.setCategory(.soloAmbient)
    }

    func toggle() {
        guard let player else { return }
        if playing { player.pause() } else { Self.enableSound(); player.play() }
        playing.toggle()
    }

    func pause() {
        player?.pause()
        playing = false
    }

    func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        current = seconds
    }

    func detach() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        let hadPlayer = player != nil
        player?.pause()
        player = nil
        key = nil
        playing = false
        current = 0
        duration = 0
        if hadPlayer { Self.releaseSound() }
    }

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }
}

private struct VideoScrubber: View {
    @ObservedObject var video: GalleryVideo

    var body: some View {
        HStack(spacing: 10) {
            Text(Self.format(video.current)).monospacedDigit()
            Slider(value: Binding(get: { video.current }, set: { video.seek(to: $0) }),
                   in: 0...max(video.duration, 0.1))
                .tint(.white)
            Text(Self.format(video.duration)).monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.white)
    }

    static func format(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let total = Int(s.rounded())

        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// ---- лента миниатюр ----

// Полоса превью внизу, как в Telegram: текущее шире остальных, тап — перейти.
private struct ThumbnailStrip: View {
    let items: [MediaGalleryItem]
    let currentKey: String?
    let onSelect: (String) -> Void

    var body: some View {
        // Отступы по краям — в полэкрана: тогда ЛЮБАЯ миниатюра, включая первую и последнюю,
        // может встать по центру, и текущая всегда стоит ровно под фото.
        GeometryReader { geo in
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 3) {
                    ForEach(items) { item in
                        thumb(item)
                            .id(item.key)
                            .onTapGesture { onSelect(item.key) }
                    }
                }
                .padding(.horizontal, max(0, geo.size.width / 2 - 28))
            }
            .scrollIndicators(.hidden)
            .frame(height: 44)
            .onAppear { proxy.scrollTo(currentKey, anchor: .center) }
            .onChange(of: currentKey) { _, key in
                withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(key, anchor: .center) }
            }
        }
        }
        .frame(height: 44)
    }

    private func thumb(_ item: MediaGalleryItem) -> some View {
        let selected = item.key == currentKey

        return Group {
            if let image = MediaService.thumbnail(item.ref) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.gray.opacity(0.3)
            }
        }
        .frame(width: selected ? 44 : 28, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .padding(.horizontal, selected ? 6 : 0)
        .animation(.easeInOut(duration: 0.2), value: selected)
    }
}

// ---- стекло ----

extension View {
    // Панели просмотрщика — «жидкое стекло» iOS 26, на старых системах — системный материал.
    @ViewBuilder func viewerGlass<S: Shape>(_ shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}
