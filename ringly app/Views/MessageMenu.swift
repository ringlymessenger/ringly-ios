import SwiftUI

// Меню сообщения по долгому нажатию — своё, по образцу Telegram: фон размывается, сообщение
// остаётся на своём месте (или подвигается, чтобы под ним поместилось меню), меню выезжает под ним.
//
// ⚠️ Системный .contextMenu здесь использовать нельзя. Лента чата перевёрнута (см. chatFlipped),
// и на «подъёме» сообщения система снимает его вместе с отражением: оно переворачивалось вверх
// ногами. Явное превью меню спасало только итоговый кадр, сам подъём всё равно шёл перевёрнутым.

struct MessageMenuItem: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    var destructive = false
    let action: () -> Void
}

struct MessageMenuRequest: Identifiable {
    let id = UUID()
    let messageId: String
    let frame: CGRect                // где сообщение на экране (координаты окна)
    let isMine: Bool
    let preview: AnyView             // копия сообщения, НЕ перевёрнутая
    let items: [MessageMenuItem]
    var myReaction: String? = nil    // текущая своя реакция — подсвечивается в полосе
    var onReact: ((String) -> Void)? = nil   // nil — реагировать нельзя (сообщение ещё не ушло)
}

// Быстрые реакции в полосе над сообщением — набор из Telegram.
enum Reactions {
    static let quick = ["❤️", "👍", "🥰", "😭", "😍", "😢", "😁"]

    // Полный выбор (стрелка в полосе). Системного пикера эмодзи для такого случая нет, поэтому
    // список собирается из таблиц Юникода: только символы, которые сами по себе рисуются как эмодзи
    // (isEmojiPresentation). Лица и жесты — первыми, как в любой клавиатуре эмодзи.
    static let all: [String] = {
        let ranges: [ClosedRange<UInt32>] = [
            0x1F600...0x1F64F, 0x1F910...0x1F92F, 0x1F970...0x1F97F, 0x1F9D0...0x1F9FF,
            0x1F44A...0x1F4FF, 0x1F930...0x1F96F, 0x1F980...0x1F9CF, 0x1F300...0x1F449,
            0x1F680...0x1F6FF, 0x1FA70...0x1FAFF, 0x2600...0x27BF,
        ]
        var seen = Set(quick)
        var out = quick
        for r in ranges {
            for v in r {
                guard let scalar = Unicode.Scalar(v), scalar.properties.isEmojiPresentation else { continue }
                let e = String(Character(scalar))
                if seen.insert(e).inserted { out.append(e) }
            }
        }

        return out
    }()
}

// Где сейчас каждое сообщение. Обычный словарь, а не @State: рамки меняются каждый кадр прокрутки,
// а нужны лишь в момент долгого нажатия (тот же приём, что у MediaFrames).
@MainActor
enum MessageFrames {
    static var frames: [String: CGRect] = [:]
}

// Долгое нажатие на сообщение: по срабатыванию — вибро и меню. Заодно запоминает рамку сообщения.
// Бабл под пальцем НЕ сжимается: сжатие срабатывало и в начале свайпа-ответа (облачко «проседало»
// при каждом жесте), и каждое касание перерисовывало строку.
struct MessageLongPress: ViewModifier {
    // Порог долгого нажатия — ОДИН на все сообщения (текст, медиа — см. MediaPress).
    static let minimumDuration: Double = 0.25
    static let maximumDistance: CGFloat = 12

    let id: String
    let enabled: Bool
    let onPress: (CGRect) -> Void

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect in
                MessageFrames.frames[id] = rect
            }
            .onLongPressGesture(minimumDuration: Self.minimumDuration, maximumDistance: Self.maximumDistance) {
                guard enabled else { return }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                if let rect = MessageFrames.frames[id] { onPress(rect) }
            }
    }
}

// Тап по элементу ВНУТРИ сообщения (цитата, миниатюра) + долгое нажатие на нём же — тем же порогом,
// что у всего сообщения. ⚠️ Без этого долгое нажатие сообщения ждало, пока тап вложенного элемента
// «сдастся», и на цитате или фото меню открывалось заметно позже, чем на простом тексте.
// Порядок важен: долгое нажатие — внутренний жест (срабатывает по порогу), тап — внешний.
struct TapOrMenuPress: ViewModifier {
    let messageId: String?            // nil — элемент не в ленте (превью меню, полёт): только тап
    let onTap: () -> Void
    let onMenu: (() -> Void)?

    func body(content: Content) -> some View {
        if let onMenu, messageId != nil {
            content
                .onLongPressGesture(minimumDuration: MessageLongPress.minimumDuration,
                                    maximumDistance: MessageLongPress.maximumDistance) {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onMenu()
                }
                .onTapGesture { onTap() }
        } else {
            content.onTapGesture { onTap() }
        }
    }
}

struct MessageMenuView: View {
    let request: MessageMenuRequest
    let onFinish: (MessageMenuItem?) -> Void

    @State private var shown = false
    @State private var closing = false
    @State private var expanded = false              // открыт полный выбор эмодзи

    private static let menuWidth: CGFloat = 250
    private static let rowHeight: CGFloat = 46
    private static let gap: CGFloat = 10
    private static let spring = Animation.spring(response: 0.24, dampingFraction: 0.84)

    var body: some View {
        GeometryReader { geo in
            let layout = layout(in: geo.size)

            ZStack(alignment: .topLeading) {
                // размытая переписка за меню; тап мимо — закрыть
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(Color.black.opacity(0.2))
                    .opacity(shown ? 1 : 0)
                    .onTapGesture { close(nil) }

                request.preview
                    .frame(width: request.frame.width, height: request.frame.height)
                    .position(x: (shown ? layout.bubble : request.frame).midX,
                              y: (shown ? layout.bubble : request.frame).midY)
                    .allowsHitTesting(false)

                menu
                    .frame(width: Self.menuWidth)
                    .scaleEffect(shown ? 1 : 0.35, anchor: layout.anchor)
                    .opacity(shown && !expanded ? 1 : 0)
                    .allowsHitTesting(!expanded)
                    .position(x: layout.menu.midX, y: layout.menu.midY)

                if request.onReact != nil {
                    if expanded {
                        picker
                            .frame(width: layout.picker.width, height: layout.picker.height)
                            .position(x: layout.picker.midX, y: layout.picker.midY)
                            .transition(.scale(scale: 0.6, anchor: request.isMine ? .bottomTrailing : .bottomLeading)
                                .combined(with: .opacity))
                    } else {
                        reactionBar
                            .scaleEffect(shown ? 1 : 0.35, anchor: request.isMine ? .bottomTrailing : .bottomLeading)
                            .opacity(shown ? 1 : 0)
                            .position(x: layout.bar.midX, y: layout.bar.midY)
                    }
                }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(Self.spring) { shown = true }
        }
    }

    private var menu: some View {
        VStack(spacing: 0) {
            ForEach(Array(request.items.enumerated()), id: \.element.id) { i, item in
                if i > 0 { Divider().opacity(0.5) }
                Button { close(item) } label: {
                    HStack {
                        Text(item.title)
                        Spacer()
                        Image(systemName: item.icon)
                    }
                    .font(.body)
                    .foregroundStyle(item.destructive ? Color.red : AppColor.text)
                    .padding(.horizontal, 16)
                    .frame(height: Self.rowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(MenuRowStyle())
            }
        }
        .viewerGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
    }

    // ---- полоса реакций и полный выбор ----

    private var reactionBar: some View {
        HStack(spacing: 2) {
            ForEach(Reactions.quick, id: \.self) { e in
                Button { react(e) } label: {
                    Text(e)
                        .font(.system(size: 28))
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(request.myReaction == e ? Color.primary.opacity(0.18) : .clear))
                }
                .buttonStyle(ReactionButtonStyle())
            }
            Button {
                withAnimation(Self.spring) { expanded = true }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppColor.text)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.primary.opacity(0.12)))
            }
            .buttonStyle(ReactionButtonStyle())
            .padding(.leading, 2)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .viewerGlass(Capsule())
        .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
    }

    private var picker: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 8), spacing: 4) {
                ForEach(Reactions.all, id: \.self) { e in
                    Button { react(e) } label: {
                        Text(e)
                            .font(.system(size: 28))
                            .frame(maxWidth: .infinity, minHeight: 42)
                            .background(Circle().fill(request.myReaction == e ? Color.primary.opacity(0.18) : .clear))
                    }
                    .buttonStyle(ReactionButtonStyle())
                }
            }
            .padding(10)
        }
        .scrollIndicators(.hidden)
        .viewerGlass(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
    }

    private func react(_ emoji: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let onReact = request.onReact
        close(nil) { onReact?(emoji) }
    }

    // ---- раскладка ----

    private struct Layout {
        let bubble: CGRect
        let menu: CGRect
        let bar: CGRect
        let picker: CGRect
        let anchor: UnitPoint
    }

    private static let barSize = CGSize(width: 358, height: 52)

    private func layout(in size: CGSize) -> Layout {
        let insets = Self.windowInsets
        let top = insets.top + 8
        let bottom = size.height - insets.bottom - 8
        let menuHeight = CGFloat(request.items.count) * Self.rowHeight
        let barSpace = request.onReact != nil ? Self.barSize.height + Self.gap : 0
        var bubble = request.frame

        // Под сообщением не хватает места — поднимаем его ровно настолько, насколько нужно.
        // Не помещается и так (длинное сообщение) — прижимаем к верху, меню ложится поверх низа.
        let overflow = bubble.maxY + Self.gap + menuHeight - bottom
        if overflow > 0 { bubble.origin.y = max(top + barSpace, bubble.minY - overflow) }
        // над сообщением должна поместиться полоса реакций — у самого верха экрана опускаем его
        if bubble.minY - barSpace < top { bubble.origin.y = top + barSpace }
        let menuY = min(bubble.maxY + Self.gap, bottom - menuHeight)

        // меню и полоса выравниваются по краю бабла: у своих — по правому, у чужих — по левому
        func alignedX(_ width: CGFloat) -> CGFloat {
            let raw = request.isMine ? bubble.maxX - width : bubble.minX
            return min(max(12, raw), size.width - 12 - width)
        }
        let barWidth = min(Self.barSize.width, size.width - 24)
        let bar = CGRect(x: alignedX(barWidth), y: bubble.minY - barSpace,
                         width: barWidth, height: Self.barSize.height)
        // полный выбор раскрывается из полосы ВВЕРХ: сообщение под ним остаётся на виду. Места над
        // полосой мало (сообщение у верха экрана) — сдвигается вниз, но в экран целиком.
        let pickerHeight = min(320, bottom - top)
        let pickerY = min(max(top, bar.maxY - pickerHeight), bottom - pickerHeight)
        let picker = CGRect(x: 12, y: pickerY, width: size.width - 24, height: pickerHeight)

        return Layout(bubble: bubble,
                      menu: CGRect(x: alignedX(Self.menuWidth), y: menuY, width: Self.menuWidth, height: menuHeight),
                      bar: bar, picker: picker,
                      anchor: request.isMine ? .topTrailing : .topLeading)
    }

    private static var windowInsets: UIEdgeInsets {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets }.first ?? .zero
    }

    // ---- закрытие ----

    private func close(_ item: MessageMenuItem?, then: (() -> Void)? = nil) {
        guard !closing else { return }
        closing = true
        withAnimation(.spring(response: 0.18, dampingFraction: 1)) {
            shown = false
            expanded = false
        } completion: {
            onFinish(item)
            then?()
        }
    }
}

// эмодзи в полосе чуть сжимается под пальцем
private struct ReactionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.82 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// подсветка строки меню при нажатии
private struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.primary.opacity(0.1) : .clear)
    }
}
