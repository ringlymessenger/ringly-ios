import SwiftUI

// Свайп по сообщению → ответить.
//
// Направление — справа налево для всех сообщений, своих и чужих (как в Telegram). Чужие раньше
// тянули слева направо, но на iOS 26 этот жест с любого места экрана перехватывает системное
// «назад», и вместо ответа экран чата уезжал к списку.
//
// ⚠️ Главная сложность — не анимация, а сосуществование с вертикальной прокруткой ленты.
// Горизонтальный жест на строке конкурирует со скроллом ScrollView, и наивная реализация
// делает ленту дёрганой или вовсе неподвижной. Поэтому здесь:
//   1) minimumDistance больше порога скролла — короткие движения достаются ленте;
//   2) жест игнорируется, пока горизонтальная составляющая не превысила вертикальную —
//      диагональные и вертикальные протяжки остаются прокруткой.
struct SwipeToReply<Content: View>: View {
    let enabled: Bool
    /// свайп справа налево (для своих сообщений)
    let mirrored: Bool
    let onReply: () -> Void
    // ⚠️ Содержимое строится ОДИН раз, при создании, а не в body. Раньше здесь было замыкание,
    // и на каждом кадре свайпа (progress меняется от пальца) заново собиралась вся строка
    // сообщения — бабл, цитата, реакции, медиа. Отсюда дёрганый свайп.
    private let content: Content

    init(enabled: Bool, mirrored: Bool = false, onReply: @escaping () -> Void,
         @ViewBuilder content: () -> Content) {
        self.enabled = enabled
        self.mirrored = mirrored
        self.onReply = onReply
        self.content = content()
    }

    @State private var progress: CGFloat = 0     // всегда ≥ 0, знак добавляется при отрисовке
    @State private var armed = false             // порог пройден — на отпускании сработает ответ

    private let threshold: CGFloat = 55
    private let maxProgress: CGFloat = 70

    private var sign: CGFloat { mirrored ? -1 : 1 }

    var body: some View {
        content
            // Без contentShape жест ловится только там, где реально нарисован бабл. У своих
            // сообщений слева стоит пустой Spacer (у чужих — справа), и свайп, начатый в этой
            // половине, не начинался вовсе. Растягиваем область попадания на всю ширину строки.
            .contentShape(Rectangle())
            .offset(x: progress * sign)
            .overlay(alignment: mirrored ? .trailing : .leading) { arrow }
            // ⚠️ Неявной анимации по `progress` здесь быть НЕ должно. Палец и так даёт координаты
            // каждый кадр; добавленная поверх пружина заставляет SwiftUI интерполировать между
            // значениями и перерисовывать содержимое строки на каждом шаге. На тексте незаметно,
            // а на медиа-бабле (картинка с clipped/blur) это оборачивалось заметными рывками.
            // Анимируем только возврат — явно, в onEnded.
            .gesture(enabled ? drag : nil)
    }

    private var arrow: some View {
        // в фирменный цвет облачков; за порогом — залитый круг, как в Telegram
        Image(systemName: "arrowshape.turn.up.left.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(armed ? Color.white : ChatView.sendTint)
            .frame(width: 30, height: 30)
            .background(Circle().fill(armed ? ChatView.sendTint : ChatView.sendTint.opacity(0.18)))
            .scaleEffect(armed ? 1 : 0.85)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: armed)
            .opacity(Double(min(progress / threshold, 1)))
            .offset(x: 34 * sign)      // за пределами бабла, со стороны, откуда пришёл жест
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 25)
            .onChanged { v in
                // вертикальное движение — не наше дело, отдаём ленте
                guard abs(v.translation.width) > abs(v.translation.height) else { return }

                // приводим к «своей» стороне: для зеркального жеста тянут в минус
                let raw = v.translation.width * sign
                guard raw > 0 else { return }

                // За порогом тянется всё туже: движение не упирается в стену, но и не уезжает
                // за половину экрана.
                let value = raw > threshold ? threshold + (raw - threshold) * 0.25 : raw
                progress = min(value, maxProgress)

                if !armed && progress >= threshold {
                    armed = true
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
            .onEnded { _ in
                let reply = armed
                armed = false
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) { progress = 0 }
                // Ответ (плашка + клавиатура) — следующим кадром, после старта возврата облачка:
                // в одном проходе раскладки возврат, плашка и клавиатура мешали друг другу.
                if reply { DispatchQueue.main.async { onReply() } }
            }
    }
}
