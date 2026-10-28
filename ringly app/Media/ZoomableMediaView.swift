import SwiftUI
import UIKit
import AVFoundation

// Страница просмотрщика: фото или видео с зумом и жестом «смахнуть, чтобы закрыть».
//
// Зум — на UIScrollView, а не на жестах SwiftUI. Только он даёт то, к чему привыкли пальцы:
// увеличение вокруг точки щипка, двойной тап в точку, пружину на краях и инерцию при перетаскивании
// увеличенной картинки. Видео живёт в той же странице и зумится так же, как в Telegram.
struct ZoomableMediaView: UIViewRepresentable {
    let image: UIImage?
    let player: AVPlayer?
    let aspect: CGSize
    let isCurrent: Bool
    let onTap: () -> Void
    let onDismissPan: (UIGestureRecognizer.State, CGPoint, CGPoint) -> Void
    let onZoom: (Bool) -> Void

    func makeUIView(context: Context) -> ZoomScrollView { ZoomScrollView() }

    func updateUIView(_ view: ZoomScrollView, context: Context) {
        view.onTap = onTap
        view.onDismissPan = onDismissPan
        view.onZoom = onZoom
        view.set(image: image, player: player, aspect: aspect)
        // ушли на соседнюю страницу — увеличение сбрасываем, как в Telegram и «Фото»
        if !isCurrent { view.resetZoom() }
    }
}

final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
    var onTap: (() -> Void)?
    var onDismissPan: ((UIGestureRecognizer.State, CGPoint, CGPoint) -> Void)?
    var onZoom: ((Bool) -> Void)?

    private let content = UIView()
    private let imageView = UIImageView()
    private let playerView = PlayerLayerView()
    private var aspect = CGSize(width: 1, height: 1)
    private var laidOutSize: CGSize = .zero
    private var wasZoomed = false

    private let dismissPan = UIPanGestureRecognizer()
    private lazy var dismissDelegate = DismissPanDelegate(owner: self)

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = .clear
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        minimumZoomScale = 1
        maximumZoomScale = 4

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        content.addSubview(imageView)
        content.addSubview(playerView)
        addSubview(content)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        // одиночный тап ждёт, не окажется ли он началом двойного — иначе двойной тап ещё и
        // прятал бы панели
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)

        dismissPan.addTarget(self, action: #selector(handleDismissPan(_:)))
        dismissPan.delegate = dismissDelegate
        addGestureRecognizer(dismissPan)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    var isZoomed: Bool { zoomScale > minimumZoomScale + 0.01 }

    func set(image: UIImage?, player: AVPlayer?, aspect newAspect: CGSize) {
        if imageView.image !== image { imageView.image = image }
        if playerView.player !== player { playerView.player = player }
        guard newAspect.width > 0, newAspect.height > 0, newAspect != aspect else { return }
        aspect = newAspect
        relayout()
    }

    func resetZoom() {
        if isZoomed { setZoomScale(minimumZoomScale, animated: false) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != laidOutSize {
            laidOutSize = bounds.size
            relayout()
        }
    }

    // Рамка содержимого = «вписанная» рамка файла. От неё считаются и зум, и центрирование.
    private func relayout() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        zoomScale = minimumZoomScale
        let fit = AVMakeRect(aspectRatio: aspect, insideRect: CGRect(origin: .zero, size: bounds.size))
        content.frame = CGRect(origin: .zero, size: fit.size)
        imageView.frame = content.bounds
        playerView.frame = content.bounds
        contentSize = fit.size
        centerContent()
        contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
    }

    // Пока картинка меньше экрана, она стоит по центру; больше — прокручивается от края до края.
    private func centerContent() {
        let dx = max(0, (bounds.width - content.frame.width) / 2)
        let dy = max(0, (bounds.height - content.frame.height) / 2)
        contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        let zoomed = isZoomed
        if zoomed != wasZoomed {
            wasZoomed = zoomed
            onZoom?(zoomed)
        }
    }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        if isZoomed {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        // увеличиваем В ТУ ТОЧКУ, куда тапнули, а не в центр
        let point = g.location(in: content)
        let scale: CGFloat = 2.5
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                        width: size.width, height: size.height), animated: true)
    }

    @objc private func handleSingleTap() { onTap?() }

    @objc private func handleDismissPan(_ g: UIPanGestureRecognizer) {
        // В координатах окна: страница сама едет за пальцем, и в собственных координатах
        // смещение «убегало» бы вместе с ней.
        onDismissPan?(g.state, g.translation(in: window), g.velocity(in: window))
    }

    fileprivate func shouldBeginDismiss(_ g: UIPanGestureRecognizer) -> Bool {
        guard !isZoomed else { return false }           // увеличенную картинку тянут, а не закрывают
        let v = g.velocity(in: self)

        return abs(v.y) > abs(v.x) * 1.2                // только явно вертикальный жест
    }
}

// Делегат жеста закрытия — отдельным объектом: собственный делегат UIScrollView занят его жестами.
private final class DismissPanDelegate: NSObject, UIGestureRecognizerDelegate {
    weak var owner: ZoomScrollView?

    init(owner: ZoomScrollView) { self.owner = owner }

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let pan = g as? UIPanGestureRecognizer, let owner else { return false }

        return owner.shouldBeginDismiss(pan)
    }

    // Листание страниц (внешняя лента) и прокрутка увеличенной картинки ждут, пока жест закрытия
    // откажется. Он решает по первому же движению пальца: вертикально — закрываем, нет — уступаем.
    // Без этого вертикальный свайп заодно начинал листать, и страница уезжала вбок.
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        other is UIPanGestureRecognizer && other.view is UIScrollView
    }
}

// Слой видео. Постер (миниатюра) лежит под ним в imageView и виден, пока не пришёл первый кадр.
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }
}
