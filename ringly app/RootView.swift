import SwiftUI

struct RootView: View {
    @EnvironmentObject var viewModel: AppViewModel

    var body: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-demoScreens") {
            DemoScreens()                             // стенд скриншотов для App Store
        } else if ProcessInfo.processInfo.arguments.contains("-chatHarness") {
            ChatHarness()
        } else if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-callHarness") {
            // стенд экрана звонка: режим — следующий аргумент
            let args = ProcessInfo.processInfo.arguments
            let mode = i + 1 < args.count ? args[i + 1] : "active"
            CallOverlayView().onAppear { CallManager.shared.debugPreview(mode) }
        } else if ProcessInfo.processInfo.arguments.contains("-backupPinHarness") {
            Color.black.ignoresSafeArea().sheet(isPresented: .constant(true)) { BackupPinView() }   // стенд шита PIN
        } else if ProcessInfo.processInfo.arguments.contains("-onboardingHarness") {
            // стенд онбординга: имя «пришло» из Sign in with Apple
            OnboardingView().onAppear { AppleNameHint.save(first: "Анна", last: "Соколова") }
        } else if ProcessInfo.processInfo.arguments.contains("-passcodeHarness") {
            NavigationStack { PasscodeSettingsView() }   // стенд настроек код-пароля (без аккаунта)
        } else if ProcessInfo.processInfo.arguments.contains("-backupHarness") {
            NavigationStack { ICloudBackupView() }    // стенд настроек копии в iCloud (без аккаунта)
        } else if ProcessInfo.processInfo.arguments.contains("-bypassHarness") {
            NavigationStack { BypassView() }          // стенд экрана обхода блокировок (без аккаунта)
        } else if ProcessInfo.processInfo.arguments.contains("-keyRecoveryHarness") {
            KeyRecoveryView(mandatory: true)          // стенд экрана восстановления (без аккаунта)
        } else if ProcessInfo.processInfo.arguments.contains("-announcementHarness") {
            // стенд баннера объявления вверху списка (без сервера и аккаунта)
            List {
                AnnouncementBanner(announcement: Announcement(
                    id: "h", name: "Команда Ringly",
                    text: "Вышло обновление 1.1: свой гудок вместо гудков и Rings за рекламу. Подробности [на сайте](https://ringlyapp.net).",
                    expiresAt: "2099-01-01T00:00:00.000Z")) {}
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                ForEach(["Анна", "Дмитрий", "Елена"], id: \.self) { Text($0).padding(.vertical, 14) }
            }
            .listStyle(.plain)
            .background(AppColor.background.ignoresSafeArea())
            .scrollContentBackground(.hidden)
        } else if ProcessInfo.processInfo.arguments.contains("-trimHarness") {
            // стенд редактора фрагмента гудка: синтетический 3-минутный трек (без файлов и аккаунта)
            Color.black.ignoresSafeArea().sheet(isPresented: .constant(true)) {
                RingbackTrimView(fileURL: RingbackTrimHarness.makeTrack(), fileName: "Тестовый трек",
                                 onDone: { _ in }, onCancel: {})
            }
        } else {
            content
        }
        #else
        content
        #endif
    }

    @ViewBuilder private var content: some View {
        switch viewModel.state {
        case .splash:
            SplashView()
        case .auth:
            AuthView()
        case .onboarding:
            OnboardingView()
        case .home:
            MainTabView()
        }
    }
}
