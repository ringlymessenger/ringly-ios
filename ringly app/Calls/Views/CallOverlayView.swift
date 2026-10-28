import SwiftUI
import Combine
import WebRTC

// Полноэкранный оверлей звонка: входящий / исходящий / активный / завершён.
//
// Оформление — в духе остального приложения (iOS 26, «жидкое стекло»):
//  • аудио и всё, что до соединения, — размытая аватарка собеседника на весь экран (нет аватарки —
//    фирменный градиент), по центру крупная аватарка с пульсирующими кольцами, пока идёт вызов;
//  • видео — собеседник на весь экран, имя и таймер в стеклянной капсуле сверху (как шапка чата),
//    своё окошко перетаскивается и прилипает к ближайшему углу; тап по экрану прячет панели.
// Экран звонка всегда тёмный: он поверх видео/фото, светлая тема тут не читалась бы.
struct CallOverlayView: View {
    @ObservedObject private var call = CallManager.shared
    @ObservedObject private var contacts = ContactProfileCache.shared
    @State private var seconds = 0
    @State private var controlsHidden = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var showsVideo: Bool { call.isVideo && call.phase == .active && call.remoteVideoTrack != nil }
    private var avatar: UIImage? { call.peerUserId.flatMap { contacts.byUser[$0]?.avatar } }

    var body: some View {
        ZStack {
            if showsVideo {
                videoStage
            } else {
                backdrop
                portrait
            }

            VStack(spacing: 0) {
                if showsVideo { videoHeader.padding(.top, 8) }
                Spacer()
                controls
                    .padding(.bottom, 24)
            }
            .opacity(showsVideo && controlsHidden ? 0 : 1)
            .allowsHitTesting(!(showsVideo && controlsHidden))

            // свернуть экран звонка, не сбрасывая звонок (как в Telegram): вернуться — по полосе
            // сверху или по окошку с собеседником (CallPresentation)
            if call.canMinimize {
                VStack {
                    HStack {
                        Button { call.minimize() } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .viewerGlass(Circle())
                        Spacer()
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .opacity(showsVideo && controlsHidden ? 0 : 1)
                .allowsHitTesting(!(showsVideo && controlsHidden))
            }
        }
        // смахнуть вниз — свернуть, как кнопкой «⌄». Обычный `.gesture` на корне уступает жестам
        // детей: кнопкам и перетаскиванию своего окошка видео, так что они не превращаются в «свернуть».
        .contentShape(Rectangle())                  // ловить жест и на пустом фоне
        .gesture(
            DragGesture(minimumDistance: 20).onEnded { v in
                guard call.canMinimize, v.translation.height > 80,
                      v.translation.height > abs(v.translation.width) else { return }
                call.minimize()
            }
        )
        .environment(\.colorScheme, .dark)
        .animation(.easeInOut(duration: 0.2), value: controlsHidden)
        .animation(.easeInOut(duration: 0.25), value: showsVideo)
        // таймер разговора идёт от РЕАЛЬНОГО ICE-коннекта (connectedAt), а не от момента accept
        .onReceive(timer) { _ in
            if let c = call.connectedAt { seconds = Int(Date().timeIntervalSince(c)) }
        }
        .onAppear { if let id = call.peerUserId { contacts.ensure(id) } }
        .onChange(of: showsVideo) { _, now in if !now { controlsHidden = false } }
    }

    // ===== фон и портрет (аудио, вызов, соединение) =====

    private var backdrop: some View {
        ZStack {
            if let avatar {
                // ⚠️ Картинка — оверлеем на пустом слое и с обрезкой. Голая `scaledToFill()` без рамки
                // берёт размер по картинке: квадратная аватарка, заполняя высоту экрана, становилась
                // шириной ~870pt, весь экран звонка расширялся за края телефона, и кнопка «свернуть»
                // в левом углу уезжала за экран (видно было только при аватарке собеседника).
                Color.clear
                    .overlay {
                        Image(uiImage: avatar)
                            .resizable().scaledToFill()
                            .blur(radius: 60)
                            .scaleEffect(1.3)      // размытые края уходят за экран
                    }
                    .clipped()
                    .overlay(Color.black.opacity(0.45))
            } else {
                LinearGradient(colors: [AppColor.brand.opacity(0.85), Color(red: 0.12, green: 0.08, blue: 0.3), .black],
                               startPoint: .topLeading, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
    }

    private var portrait: some View {
        VStack(spacing: 14) {
            Spacer()
            CallAvatar(image: avatar, name: call.peerName, pulsing: isRinging)
                .padding(.bottom, 12)
            Text(call.peerName)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(statusText)
                .font(.system(size: 17))
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .monospacedDigit()
                .contentTransition(.numericText())
            if call.phase == .outgoing && call.peerRingbackPlaying {
                ringbackNote
                    .padding(.top, 10)
                    .transition(.opacity)
            }
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
        .animation(.easeInOut(duration: 0.25), value: call.peerRingbackPlaying)
    }

    // Пока звонящий слышит мелодию абонента: кто её поставил и что такую можно завести себе за Rings.
    // «использует» — без рода и падежа, имя подставляется как есть.
    // Каждая строка — в одну линию: на узком экране (SE, 375pt) и с крупным шрифтом в настройках
    // текст ужимается, а не переносится по словам; крупнее .xLarge подпись не растёт — это
    // второстепенная плашка, имя и статус над ней важнее.
    private var ringbackNote: some View {
        VStack(spacing: 3) {
            Label(L("%@ использует свой гудок", ringbackOwnerName), systemImage: "music.note")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
            Text(L("Такой можно поставить себе за Rings"))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    // имя без фамилии: «Анна Соколова» → «Анна»; ник оставляем целиком
    private var ringbackOwnerName: String {
        let name = call.peerName.trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("@") { return name }
        return name.split(separator: " ").first.map(String.init) ?? name
    }

    // кольца вокруг аватарки — пока нет живого разговора
    private var isRinging: Bool {
        switch call.phase {
        case .outgoing, .incoming: return true
        case .active: return call.connectedAt == nil || call.reconnecting
        case .ended, .idle: return false
        }
    }

    // ===== видео =====

    private var videoStage: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RTCVideoView(track: call.remoteVideoTrack).ignoresSafeArea()
                // свернули приложение — собеседник уезжает в окно «картинка в картинке» (CallPiP)
                .background(CallPiPSource(track: call.remoteVideoTrack).ignoresSafeArea())
                .contentShape(Rectangle())
                .onTapGesture { controlsHidden.toggle() }

            // затемнение сверху и снизу — чтобы имя и кнопки читались на любом кадре
            VStack {
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 180)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 220)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .opacity(controlsHidden ? 0 : 1)

            if call.localVideoTrack != nil {
                LocalPreview(track: call.localVideoTrack, bottomInset: controlsHidden ? 24 : 150)
            }
        }
    }

    private var videoHeader: some View {
        VStack(spacing: 1) {
            Text(call.peerName)
                .font(.system(size: 16, weight: .semibold)).lineLimit(1)
                .foregroundStyle(.white)
            Text(statusText)
                .font(.caption).monospacedDigit()
                .foregroundStyle(.white.opacity(0.75))
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 20).padding(.vertical, 6)
        .frame(minHeight: 44)
        .viewerGlass(Capsule())
    }

    // ===== статус =====

    private var statusText: String {
        switch call.phase {
        case .outgoing:  return L("Вызов…")
        case .incoming:  return call.isVideo ? L("Входящий видеозвонок") : L("Входящий звонок")
        case .active:
            // честные статусы (как в Telegram): «Соединение…» пока ICE не поднялся,
            // «Переподключение…» при потере, таймер — только когда медиа реально идёт
            if call.reconnecting { return L("Переподключение…") }
            guard call.connectedAt != nil else { return L("Соединение…") }
            return CallStatusText.timer(seconds)
        case .ended:     return endedText
        case .idle:      return ""
        }
    }

    private var endedText: String {
        switch call.endedReason {
        case "busy":     return L("Занято")
        case "timeout":  return L("Нет ответа")
        case "rejected", "declined": return L("Звонок отклонён")
        case "failed", "disconnected", "error":
            return L("Не удалось установить соединение")      // честная ошибка вместо «Звонок завершён»
        case "no_relay":
            // fail-closed по «Звонить через сервер»: называем причину и даём выход, а не глухое «ошибка»
            return L("Сервер для звонков недоступен.\nОтключите «Звонить через сервер» в настройках, чтобы позвонить напрямую.")
        default:         return L("Звонок завершён")
        }
    }

    // ===== кнопки =====

    @ViewBuilder private var controls: some View {
        switch call.phase {
        case .incoming:
            HStack(spacing: 56) {
                CallButton(icon: "phone.down.fill", title: L("Отклонить"), style: .destructive) { call.decline() }
                CallButton(icon: call.isVideo ? "video.fill" : "phone.fill", title: L("Принять"), style: .accept) {
                    call.accept()
                }
            }
        case .outgoing, .active:
            // Один и тот же ряд для дозвона и разговора: кнопка отбоя всегда справа. Раньше при
            // дозвоне она стояла в центре и в момент ответа уезжала в бок — ровно когда к ней тянется палец.
            HStack(spacing: 24) {
                CallButton(icon: call.muted ? "mic.slash.fill" : "mic.fill", title: L("Микрофон"),
                           style: .toggle(on: call.muted)) { call.toggleMute() }
                if call.isVideo {
                    CallButton(icon: "arrow.triangle.2.circlepath.camera.fill", title: L("Камера"),
                               style: .plain) { call.switchCamera() }   // фронт ↔ основная
                } else {
                    CallButton(icon: "speaker.wave.2.fill", title: L("Динамик"),
                               style: .toggle(on: call.speakerOn)) { call.toggleSpeaker() }
                }
                CallButton(icon: "phone.down.fill",
                           title: call.phase == .outgoing ? L("Отменить") : L("Завершить"),
                           style: .destructive) { call.hangup() }
            }
        case .ended, .idle:
            EmptyView()
        }
    }
}

// Круглая кнопка звонка с подписью. Обычные — на стекле; включённый переключатель (микрофон
// выключен, динамик включён) — белая заливка с тёмным значком, как в системном экране звонка.
private struct CallButton: View {
    enum Style: Equatable { case plain, toggle(on: Bool), destructive, accept }

    let icon: String
    let title: String
    let style: Style
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(foreground)
                    .frame(width: 68, height: 68)
                    .background { fill }
                    .contentShape(Circle())
            }
            .buttonStyle(CallButtonPress())
            .modifier(GlassIfNeeded(enabled: usesGlass))
            .animation(.easeInOut(duration: 0.15), value: style)

            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        // ширина не зависит от подписи: «Отменить» → «Завершить» при ответе не сдвигает ряд
        .frame(width: 92)
    }

    private var usesGlass: Bool {
        if case .toggle(let on) = style { return !on }
        return style == .plain
    }

    private var foreground: Color {
        if case .toggle(true) = style { return .black }
        return .white
    }

    @ViewBuilder private var fill: some View {
        switch style {
        case .destructive: Circle().fill(Color(red: 1, green: 0.23, blue: 0.19))
        case .accept:      Circle().fill(Color(red: 0.2, green: 0.78, blue: 0.35))
        case .toggle(true): Circle().fill(.white)
        default:           Color.clear
        }
    }
}

private struct GlassIfNeeded: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled { content.viewerGlass(Circle()) } else { content }
    }
}

private struct CallButtonPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// Крупная аватарка собеседника; пока идёт вызов — расходящиеся кольца.
private struct CallAvatar: View {
    let image: UIImage?
    let name: String
    let pulsing: Bool

    private let size: CGFloat = 132

    var body: some View {
        ZStack {
            if pulsing {
                // у каждого кольца своя анимация, запускается при ЕГО появлении: вызов начинается
                // позже, чем показывается аватарка, и общий флаг к этому моменту уже не менялся бы
                ForEach(0..<2) { i in PulseRing(size: size, delay: Double(i) * 0.9) }
            }
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    AppColor.brand
                        .overlay(Text(initial).font(.system(size: 52, weight: .semibold)).foregroundStyle(.white))
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
        }
    }

    private var initial: String {
        let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: "@ "))

        return trimmed.first.map { String($0).uppercased() } ?? "?"
    }
}

private struct PulseRing: View {
    let size: CGFloat
    let delay: Double
    @State private var on = false

    var body: some View {
        Circle()
            .stroke(.white.opacity(0.4), lineWidth: 1.5)
            .frame(width: size, height: size)
            .scaleEffect(on ? 1.6 : 1)
            .opacity(on ? 0 : 1)
            .onAppear {
                withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false).delay(delay)) { on = true }
            }
    }
}

// Своё видео в углу. Перетаскивается пальцем и прилипает к ближайшему углу, как в FaceTime и Telegram.
private struct LocalPreview: View {
    let track: RTCVideoTrack?
    let bottomInset: CGFloat           // снизу место под кнопки (когда они показаны)

    @State private var corner = Corner.topTrailing
    @State private var drag = CGSize.zero

    private enum Corner { case topLeading, topTrailing, bottomLeading, bottomTrailing }
    private let size = CGSize(width: 112, height: 160)
    private let margin: CGFloat = 16
    private let topInset: CGFloat = 64  // под капсулой с именем

    var body: some View {
        GeometryReader { geo in
            let origin = position(corner, in: geo.size)

            RTCVideoView(track: track)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.2), lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
                .position(x: origin.x + drag.width, y: origin.y + drag.height)
                .gesture(
                    DragGesture()
                        .onChanged { drag = $0.translation }
                        .onEnded { v in
                            // куда бросили (с учётом инерции) — к тому углу и прилипаем
                            let end = CGPoint(x: origin.x + v.predictedEndTranslation.width,
                                              y: origin.y + v.predictedEndTranslation.height)
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                corner = nearest(to: end, in: geo.size)
                                drag = .zero
                            }
                        }
                )
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: bottomInset)
        }
    }

    private func position(_ c: Corner, in s: CGSize) -> CGPoint {
        let left = margin + size.width / 2, right = s.width - margin - size.width / 2
        let top = topInset + size.height / 2, bottom = s.height - bottomInset - size.height / 2
        switch c {
        case .topLeading:     return CGPoint(x: left, y: top)
        case .topTrailing:    return CGPoint(x: right, y: top)
        case .bottomLeading:  return CGPoint(x: left, y: bottom)
        case .bottomTrailing: return CGPoint(x: right, y: bottom)
        }
    }

    private func nearest(to p: CGPoint, in s: CGSize) -> Corner {
        let leftSide = p.x < s.width / 2, topSide = p.y < s.height / 2
        switch (leftSide, topSide) {
        case (true, true): return .topLeading
        case (false, true): return .topTrailing
        case (true, false): return .bottomLeading
        case (false, false): return .bottomTrailing
        }
    }
}
