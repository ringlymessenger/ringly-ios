import SwiftUI

// Вспышка ❤️ в точке двойного нажатия по сообщению: сердце выскакивает с пружиной, чуть
// поднимается и гаснет (~0.7 с), затем само убирается через onDone. Касаний не перехватывает.
// При «Уменьшении движения» — без масштаба и подъёма, только короткое появление.
struct HeartBurst: View {
    struct Spot: Equatable {
        let id = UUID()            // повторное двойное нажатие перезапускает вспышку
        let messageId: String
        let location: CGPoint      // в координатах бабла
    }

    let spot: Spot
    let onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var popped = false
    @State private var fading = false

    var body: some View {
        Text("❤️")
            .font(.system(size: 44))
            .scaleEffect(reduceMotion ? 1 : (popped ? (fading ? 1.15 : 1) : 0.3))
            .offset(y: reduceMotion || !fading ? 0 : -18)
            .opacity(fading ? 0 : 1)
            .position(spot.location)
            .allowsHitTesting(false)
            .task(id: spot.id) {
                popped = false; fading = false
                withAnimation(.spring(response: 0.28, dampingFraction: 0.5)) { popped = true }
                try? await Task.sleep(nanoseconds: 350_000_000)
                withAnimation(.easeOut(duration: 0.35)) { fading = true }
                try? await Task.sleep(nanoseconds: 360_000_000)
                onDone()
            }
    }
}
