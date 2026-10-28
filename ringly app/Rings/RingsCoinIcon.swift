import SwiftUI

// Иконка монеты Rings. Если в ассетах есть брендовый PNG "RingsCoin" — показываем его,
// иначе graceful-фолбэк на SF Symbol (чтобы UI не был пустым, пока ассет не добавлен).
struct RingsCoinIcon: View {
    var size: CGFloat = 22

    var body: some View {
        if UIImage(named: "RingsCoin") != nil {
            Image("RingsCoin")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "r.circle.fill")
                .font(.system(size: size))
                .foregroundStyle(.white, Color.purple)
        }
    }
}
