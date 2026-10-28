import SwiftUI
import GoogleSignIn

@main
struct MessengerApp: App {
    // ОДИН стор на всё приложение (singleton — тот же, что поднимает AppDelegate на VoIP-старте)
    @StateObject private var viewModel = AppViewModel.shared
    @StateObject private var themeStore = ThemeStore.shared
    @StateObject private var languageStore = LanguageStore.shared
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate   // APNs-регистрация/пуши
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
            WindowGroup {
                RootView()
                    .environmentObject(viewModel)
                    // Схема задаётся здесь, на корне: так она накрывает и модалки/шиты, которые
                    // живут в собственных окнах и настройку с отдельного экрана бы не увидели.
                    .preferredColorScheme(themeStore.theme.colorScheme)
                    // Локаль задаётся вместе с языком: иначе даты, «вчера» и названия месяцев
                    // остались бы на системном языке, даже когда интерфейс переключён вручную.
                    .environment(\.locale, languageStore.locale)
                    // Смена языка перерисовывает всё дерево: строки берутся из словаря в момент
                    // отрисовки, и без смены id часть экранов осталась бы на прежнем языке.
                    .id(languageStore.language)
                    // код-пароль включён → на холодном старте сразу блокировка (окно поверх всего, см. AppLock)
                    .onAppear { AppLock.shared.start() }
                    .onOpenURL { url in
                        GIDSignIn.sharedInstance.handle(url)   // отдаём возврат Google SDK
                        viewModel.handleDeepLink(url)
                    }
                    .onChange(of: scenePhase) { phase in
                        switch phase {
                        case .active:     viewModel.appBecameActive()   // уровень 1: повтор sync
                        case .background: viewModel.appWentToBackground()
                        // ⚠️ .inactive — НЕ фон. Сцена становится неактивной, когда поверх неё всплывает
                        // экран звонка CallKit, Пункт управления или шторка. Раньше это рвало WS: входящий
                        // по VoIP показывал CallKit → .inactive → сокет останавливался, пока фаза звонка
                        // ещё idle, — и accept/initiate следующих звонков уходили в никуда (calls-stability.md).
                        case .inactive:   break
                        @unknown default: break
                        }
                    }
                    // Обход блокировок: пути наружу нет совсем. Алерт висит на КОРНЕ, чтобы появиться
                    // на любом экране — проблема не привязана к тому, что пользователь сейчас делает.
                    .alert(L("Нет связи с сервером"), isPresented: $viewModel.showNoRouteAlert) {
                        Button(L("Понятно"), role: .cancel) {}
                    } message: {
                        Text(L("Похоже, доступ к Ringly ограничен вашим провайдером, а запасных точек входа приложение пока не знает.\n\nВключите VPN на одну минуту и откройте приложение — оно получит запасные адреса и дальше будет работать само. Либо откройте ссылку-приглашение от того, у кого Ringly работает."))
                    }
            }
        }
}
