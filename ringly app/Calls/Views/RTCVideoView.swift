import SwiftUI
import WebRTC

// SwiftUI-обёртка над RTCMTLVideoView (Metal-рендер WebRTC-дорожки).
struct RTCVideoView: UIViewRepresentable {
    let track: RTCVideoTrack?

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFill
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        context.coordinator.attach(track, to: uiView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private weak var current: RTCVideoTrack?
        func attach(_ track: RTCVideoTrack?, to view: RTCMTLVideoView) {
            guard current !== track else { return }
            current?.remove(view)
            current = track
            track?.add(view)
        }
    }
}
