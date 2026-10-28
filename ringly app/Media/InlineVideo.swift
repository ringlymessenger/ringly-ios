import SwiftUI
import AVFoundation

// Видео в ленте играет само, без звука и по кругу — как в Telegram. Тап открывает просмотрщик
// со звуком (GalleryVideo), здесь звука нет вовсе.
//
// ⚠️ Звуковые дорожки ОТКЛЮЧАЮТСЯ, а не просто приглушаются. Даже приглушённый плеер со звуковой
// дорожкой забирает аудиосессию: у пользователя останавливалась бы музыка, едва в ленте мелькнёт
// видео. Без дорожек плеер звуком не занимается и чужое аудио не трогает.
//
// Играет, только пока ячейка в ленте на экране: LazyVStack убирает строки за краем, onDisappear
// останавливает и отпускает плеер, чтобы в памяти не висели десятки декодеров.
struct InlineVideo: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> InlineVideoView { InlineVideoView() }

    func updateUIView(_ view: InlineVideoView, context: Context) {
        view.load(url)
    }

    static func dismantleUIView(_ view: InlineVideoView, coordinator: ()) {
        view.stop()
    }
}

final class InlineVideoView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    private var url: URL?
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var tracksObservation: NSKeyValueObservation?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false          // тапы — ячейке медиа (просмотрщик, меню)
        backgroundColor = .clear
        playerLayer.videoGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    func load(_ newURL: URL) {
        guard newURL != url else { return }
        stop()
        url = newURL

        let item = AVPlayerItem(url: newURL)
        // дорожки известны только после загрузки ассета — отключаем звук, как только они появились
        tracksObservation = item.observe(\.tracks, options: [.initial, .new]) { item, _ in
            for track in item.tracks where track.assetTrack?.mediaType == .audio {
                track.isEnabled = false
            }
        }
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.preventsDisplaySleepDuringVideoPlayback = false
        queue.allowsExternalPlayback = false
        looper = AVPlayerLooper(player: queue, templateItem: item)
        player = queue
        playerLayer.player = queue
        queue.play()
    }

    func stop() {
        player?.pause()
        looper?.disableLooping()
        looper = nil
        tracksObservation = nil
        playerLayer.player = nil
        player = nil
        url = nil
    }

    // ушли из окна (строка уехала за край, открыт другой экран) — не тратим декодер
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { player?.pause() } else { player?.play() }
    }
}

// Метка поверх видео в ленте: длительность и «без звука», как в Telegram.
struct InlineVideoBadge: View {
    let durationMs: Int?

    var body: some View {
        HStack(spacing: 4) {
            if let durationMs {
                Text(Self.format(durationMs)).monospacedDigit()
            }
            Image(systemName: "speaker.slash.fill").font(.system(size: 10, weight: .semibold))
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(.black.opacity(0.45), in: Capsule())
        .padding(6)
        .allowsHitTesting(false)
    }

    static func format(_ ms: Int) -> String {
        let s = max(0, ms / 1000)

        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
