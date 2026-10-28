import SwiftUI

// Волна на экране входа: несколько толстых синусоид, плывущих поперёк экрана.
//
// Canvas + TimelineView, а не анимация формы: перерисовка идёт одним слоем на GPU, без пересборки
// иерархии вью на каждом кадре. TimelineView(.animation) сам останавливается, когда экран не виден,
// поэтому фоном батарею это не ест.
struct WaveBanner: View {
    var color: Color = AppColor.brand

    // Линии идут ПАРАЛЛЕЛЬНО: общая амплитуда и общая скорость, разный только вертикальный уровень
    // и маленький сдвиг фазы. Из-за него волна кажется бегущей сверху вниз, но линии не сходятся.
    //
    // ⚠️ Разные скорости у линий выглядят соблазнительно «живее», но так делать нельзя: фазы
    // расходятся, и через несколько секунд линии пересекаются, превращая волну в клубок лент.
    // Разойтись они могут только на фиксированную величину — значит, сдвиг фазы, а не скорости.
    private let offsetsY: [Double] = [0.18, 0.38, 0.58, 0.78]   // доля от высоты полосы
    private let phaseStep = 0.18            // радиан между соседними линиями
    private let amplitude = 0.075           // доля от высоты полосы
    private let speed = 0.5                 // радиан в секунду, общая

    // Постоянное движение на экране физически неприятно части людей — при системном «Уменьшении
    // движения» волна замирает в статичной позе, а не исчезает: рисунок остаётся на месте.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                for (i, offsetY) in offsetsY.enumerated() {
                    let phase = Double(i) * phaseStep + t * speed
                    context.stroke(path(offsetY: offsetY, phase: phase, in: size),
                                   with: .color(color),
                                   style: StrokeStyle(lineWidth: size.height * 0.105,
                                                      lineCap: .round))
                }
            }
        }
        .allowsHitTesting(false)   // декорация: не перехватывает тапы у того, что под ней
        .accessibilityHidden(true)
    }

    private func path(offsetY: Double, phase: Double, in size: CGSize) -> Path {
        var path = Path()
        // Шаг в 6 точек: на глаз неотличимо от попиксельного, а работы вчетверо меньше.
        let step: CGFloat = 6
        // Одна полная волна на ширину экрана — так линии не выглядят рябью и не спорят с текстом.
        let waveLength = Double(size.width)
        let amplitude = Double(size.height) * self.amplitude
        let baseY = Double(size.height) * offsetY

        // Начинаем и заканчиваем ЗА краем: иначе на границах виден срез, и волна читается как
        // отрезок, а не как бесконечная линия.
        var x: CGFloat = -step
        while x <= size.width + step {
            let y = baseY + sin(Double(x) / waveLength * 2 * .pi + phase) * amplitude
            let point = CGPoint(x: x, y: y)
            if path.isEmpty { path.move(to: point) } else { path.addLine(to: point) }
            x += step
        }

        return path
    }
}
