import SwiftUI
import AVKit
import WebRTC

// «Картинка в картинке» для видеозвонка: свернул приложение — собеседник остаётся в плавающем окне
// поверх других приложений (системный механизм для звонков, AVPictureInPictureVideoCallViewController).
//
// ⚠️ В окно PiP нельзя просто положить RTCMTLVideoView: в фоне приложению запрещено отправлять работу
// на GPU (Metal), и окно оставалось бы чёрным. Поэтому кадры собеседника отдельно перекладываются в
// AVSampleBufferDisplayLayer — его рисует сама система, в фоне тоже.
//
// Чтобы и собеседник продолжал видеть НАС, камере разрешена работа в многозадачности — см.
// WebRTCClient.allowCameraInBackground.
@MainActor
final class CallPiP: NSObject, AVPictureInPictureControllerDelegate {
    static let shared = CallPiP()

    private var controller: AVPictureInPictureController?
    private var callVC: AVPictureInPictureVideoCallViewController?
    private weak var sourceView: UIView?
    private let videoView = PiPVideoView()
    private let renderer = PiPFrameRenderer()
    private weak var track: RTCVideoTrack?

    // Подключить PiP к экрану звонка: source — область видео собеседника, из неё окно «вылетает»
    // при сворачивании и в неё же возвращается.
    func attach(source: UIView, track: RTCVideoTrack?) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        if controller == nil || sourceView !== source { setUp(source: source) }
        setTrack(track)
    }

    // Экран, к которому был привязан PiP, исчез. ⚠️ Источников два — полный экран звонка и окошко
    // свёрнутого звонка (MiniCallVideo), — и при переключении между ними новый появляется РАНЬШЕ, чем
    // уходит старый. Раньше уборка старого стирала привязку нового, и после «свернуть → развернуть»
    // картинка в картинке больше не появлялась. Отвязываем, только если PiP всё ещё на этом экране.
    func detach(source: UIView) {
        guard sourceView == nil || sourceView === source else { return }
        detach()
    }

    // Звонок кончился или экран звонка закрыт — окно убираем, дорожку отпускаем.
    func detach() {
        controller?.stopPictureInPicture()
        controller?.delegate = nil
        controller = nil
        callVC = nil
        sourceView = nil
        setTrack(nil)
        videoView.flush()
    }

    private func setUp(source: UIView) {
        let vc = AVPictureInPictureVideoCallViewController()
        vc.preferredContentSize = CGSize(width: 9, height: 16)   // до первого кадра — портрет телефона
        videoView.frame = vc.view.bounds
        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        vc.view.addSubview(videoView)

        let content = AVPictureInPictureController.ContentSource(activeVideoCallSourceView: source,
                                                                 contentViewController: vc)
        let pip = AVPictureInPictureController(contentSource: content)
        // окно появляется само при сворачивании приложения — отдельной кнопки не нужно
        pip.canStartPictureInPictureAutomaticallyFromInline = true
        pip.delegate = self

        renderer.view = videoView
        // окно PiP принимает пропорции видео собеседника (портрет/альбом, поворот телефона)
        renderer.onSize = { [weak vc] size in vc?.preferredContentSize = size }

        controller = pip
        callVC = vc
        sourceView = source
    }

    private func setTrack(_ new: RTCVideoTrack?) {
        guard track !== new else { return }
        track?.remove(renderer)
        track = new
        new?.add(renderer)
    }

    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        print("PiP failed to start:", error)
    }
}

// Место на экране звонка, к которому привязано окно PiP (под видео собеседника, невидимое).
struct CallPiPSource: UIViewRepresentable {
    let track: RTCVideoTrack?

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ view: UIView, context: Context) {
        CallPiP.shared.attach(source: view, track: track)
    }

    static func dismantleUIView(_ view: UIView, coordinator: ()) {
        CallPiP.shared.detach(source: view)
    }
}

// Содержимое окна PiP: слой, который система рисует сама. Поворот кадра применяется к слою —
// AVSampleBufferDisplayLayer метаданные поворота WebRTC не читает.
final class PiPVideoView: UIView {
    let displayLayer = AVSampleBufferDisplayLayer()
    var rotation: RTCVideoRotation = ._0 { didSet { if rotation != oldValue { setNeedsLayout() } } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let sideways = rotation == ._90 || rotation == ._270
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.setAffineTransform(.identity)
        displayLayer.bounds = CGRect(x: 0, y: 0,
                                     width: sideways ? bounds.height : bounds.width,
                                     height: sideways ? bounds.width : bounds.height)
        displayLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        displayLayer.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(rotation.rawValue) * .pi / 180))
        CATransaction.commit()
    }

    func enqueue(_ sample: CMSampleBuffer) {
        if displayLayer.status == .failed { displayLayer.flush() }
        displayLayer.enqueue(sample)
    }

    func flush() { displayLayer.flushAndRemoveImage() }
}

// Перекладывает кадры WebRTC в CMSampleBuffer для AVSampleBufferDisplayLayer.
// Аппаратный H.264 приходит готовым CVPixelBuffer; VP8/VP9 — программным I420, его переупаковываем
// в NV12 (формат, который слой принимает напрямую).
final class PiPFrameRenderer: NSObject, RTCVideoRenderer {
    weak var view: PiPVideoView?
    var onSize: ((CGSize) -> Void)?

    private var pool: CVPixelBufferPool?
    private var poolSize = (w: 0, h: 0)
    private var lastSize = CGSize.zero          // трогается только на главном потоке

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame, let pixel = pixelBuffer(frame.buffer), let sample = Self.sampleBuffer(pixel) else { return }
        let rotation = frame.rotation
        let w = CGFloat(frame.width), h = CGFloat(frame.height)
        let size = (rotation == ._90 || rotation == ._270) ? CGSize(width: h, height: w) : CGSize(width: w, height: h)

        DispatchQueue.main.async { [weak self] in
            guard let self, let view = self.view else { return }
            if size != self.lastSize, size.width > 0, size.height > 0 {
                self.lastSize = size
                self.onSize?(size)
            }
            view.rotation = rotation
            view.enqueue(sample)
        }
    }

    private func pixelBuffer(_ buffer: RTCVideoFrameBuffer) -> CVPixelBuffer? {
        if let cv = buffer as? RTCCVPixelBuffer { return cv.pixelBuffer }

        return nv12(from: buffer.toI420())
    }

    private func nv12(from i420: RTCI420BufferProtocol) -> CVPixelBuffer? {
        let w = Int(i420.width), h = Int(i420.height)
        guard w > 0, h > 0 else { return nil }
        if pool == nil || poolSize != (w, h) {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey: w,
                kCVPixelBufferHeightKey: h,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            pool = nil
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
            poolSize = (w, h)
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let pb = out else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return nil }

        let yDst = yBase.assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let ySrc = i420.dataY, ySrcStride = Int(i420.strideY)
        for row in 0..<h {
            memcpy(yDst + row * yStride, ySrc + row * ySrcStride, w)
        }

        let uvDst = uvBase.assumingMemoryBound(to: UInt8.self)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let cw = Int(i420.chromaWidth), ch = Int(i420.chromaHeight)
        let uSrc = i420.dataU, vSrc = i420.dataV
        let uStride = Int(i420.strideU), vStride = Int(i420.strideV)
        for row in 0..<ch {
            let d = uvDst + row * uvStride
            let u = uSrc + row * uStride, v = vSrc + row * vStride
            for x in 0..<cw {
                d[2 * x] = u[x]
                d[2 * x + 1] = v[x]
            }
        }

        return pb
    }

    // кадр «показать сразу»: у звонка нет своей шкалы времени, задержка в слое не нужна
    private static func sampleBuffer(_ pixel: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel,
                                                           formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel, formatDescription: format,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        return sample
    }
}
