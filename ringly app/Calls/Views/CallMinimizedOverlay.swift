import SwiftUI
import WebRTC

// Показ звонка поверх приложения: полный экран (CallOverlayView) или свёрнутый вид — как в Telegram:
//  • аудио — зелёная полоса сверху «имя · таймер», всё приложение сдвигается под неё;
//  • видео — плавающее окошко с собеседником, перетаскивается к любому углу.
// Тап по полосе или окошку разворачивает экран звонка обратно. Вешается на корень (MainTabView).
struct CallPresentation: ViewModifier {
    @ObservedObject private var call = CallManager.shared

    private var showsMiniVideo: Bool { call.showMinimized && call.isVideo && call.remoteVideoTrack != nil }

    private var showsBar: Bool { call.showMinimized && !showsMiniVideo }

    func body(content: Content) -> some View {
        content
            // ⚠️ Сдвиг — через безопасную зону ОКНА, а не `.safeAreaInset`: системные панели навигации
            // (UIKit под NavigationStack) отступ SwiftUI не видят, и полоса ложилась поверх шапки чата.
            .background(WindowTopInset(extra: showsBar ? CallReturnBar.height : 0))
            .overlay(alignment: .top) {
                if showsBar {
                    CallReturnBar()
                        .ignoresSafeArea(edges: .top)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay {
                if showsMiniVideo {
                    MiniCallVideo(track: call.remoteVideoTrack)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.86), value: call.showMinimized)
            // экран звонка поверх всего (CallKit-входящий показывается нативно, его не дублируем)
            .fullScreenCover(isPresented: .init(get: { call.showFullScreen }, set: { _ in })) {
                CallOverlayView()
            }
    }
}

// Полоса «вернуться к звонку» для свёрнутого аудиозвонка. Занимает статус-бар и ещё `height` под ним —
// ровно то место, на которое WindowTopInset сдвинул приложение.
private struct CallReturnBar: View {
    static let height: CGFloat = 38
    @ObservedObject private var call = CallManager.shared

    private var statusBarHeight: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.statusBarManager?.statusBarFrame.height }.first ?? 54
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: statusBarHeight)
            row
        }
        .background(Color(red: 0.2, green: 0.74, blue: 0.35))
    }

    private var row: some View {
        Button { call.restore() } label: {
            HStack(spacing: 8) {
                Image(systemName: "phone.fill").font(.system(size: 13, weight: .semibold))
                Text(call.peerName).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                CallStatusText().font(.system(size: 15, weight: .medium)).monospacedDigit()
                Image(systemName: "chevron.up").font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: Self.height)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// Добавочный верхний отступ безопасной зоны корневого контроллера окна. Сдвигает ВСЁ приложение,
// включая системные панели навигации и таб-бар. Полноэкранные шиты/обложки — отдельные контроллеры,
// их не трогает.
private struct WindowTopInset: UIViewRepresentable {
    let extra: CGFloat

    func makeUIView(context: Context) -> Probe { Probe() }

    func updateUIView(_ view: Probe, context: Context) {
        view.extra = extra
        view.apply()
    }

    static func dismantleUIView(_ view: Probe, coordinator: ()) {
        view.extra = 0
        view.apply()
    }

    final class Probe: UIView {
        var extra: CGFloat = 0

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        func apply() {
            guard let root = window?.rootViewController, root.additionalSafeAreaInsets.top != extra else { return }
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0) {
                root.additionalSafeAreaInsets.top = self.extra
                root.view.layoutIfNeeded()
            }
        }
    }
}

// Статус свёрнутого звонка: таймер разговора или текущая стадия.
struct CallStatusText: View {
    @ObservedObject private var call = CallManager.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(text(now: context.date))
        }
    }

    // Таймер разговора: «01:13», а после часа — «1:50:56». Раньше минуты просто росли дальше 59,
    // и двухчасовой разговор показывался как «110:56».
    static func timer(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }

        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    private func text(now: Date) -> String {
        switch call.phase {
        case .outgoing: return L("Вызов…")
        case .active:
            if call.reconnecting { return L("Переподключение…") }
            guard let c = call.connectedAt else { return L("Соединение…") }
            let s = max(0, Int(now.timeIntervalSince(c)))
            return Self.timer(s)
        case .ended: return L("Звонок завершён")
        case .incoming, .idle: return ""
        }
    }
}

// Плавающее окошко свёрнутого видеозвонка. Тап — развернуть, перетаскивание — прилипает к углу.
private struct MiniCallVideo: View {
    let track: RTCVideoTrack?
    @ObservedObject private var call = CallManager.shared

    @State private var corner = Corner.topTrailing
    @State private var drag = CGSize.zero

    private enum Corner { case topLeading, topTrailing, bottomLeading, bottomTrailing }
    private let size = CGSize(width: 108, height: 156)
    private let margin: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let origin = position(corner, in: geo.size)

            RTCVideoView(track: track)
                // свернули и приложение — собеседник уезжает в системное окно «картинка в картинке»
                .background(CallPiPSource(track: track))
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(alignment: .bottom) {
                    CallStatusText()
                        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.black.opacity(0.45), in: Capsule())
                        .padding(.bottom, 6)
                }
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.2), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .position(x: origin.x + drag.width, y: origin.y + drag.height)
                .onTapGesture { call.restore() }
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { drag = $0.translation }
                        .onEnded { v in
                            let end = CGPoint(x: origin.x + v.predictedEndTranslation.width,
                                              y: origin.y + v.predictedEndTranslation.height)
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                corner = nearest(to: end, in: geo.size)
                                drag = .zero
                            }
                        }
                )
        }
    }

    private func position(_ c: Corner, in s: CGSize) -> CGPoint {
        // сверху — под шапкой экрана, снизу — над таб-баром/полем ввода
        let left = margin + size.width / 2, right = s.width - margin - size.width / 2
        let top = 64 + size.height / 2, bottom = s.height - 90 - size.height / 2
        switch c {
        case .topLeading:     return CGPoint(x: left, y: top)
        case .topTrailing:    return CGPoint(x: right, y: top)
        case .bottomLeading:  return CGPoint(x: left, y: bottom)
        case .bottomTrailing: return CGPoint(x: right, y: bottom)
        }
    }

    private func nearest(to p: CGPoint, in s: CGSize) -> Corner {
        switch (p.x < s.width / 2, p.y < s.height / 2) {
        case (true, true): return .topLeading
        case (false, true): return .topTrailing
        case (true, false): return .bottomLeading
        case (false, false): return .bottomTrailing
        }
    }
}
