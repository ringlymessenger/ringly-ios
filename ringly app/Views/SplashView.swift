import SwiftUI

struct SplashView: View {
    @EnvironmentObject var viewModel: AppViewModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Text("Ringly")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(.white)
        }
        .task {
            await viewModel.bootstrap()
        }
    }
}
