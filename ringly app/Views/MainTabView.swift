import SwiftUI

struct MainTabView: View {
    @ObservedObject private var backup = ICloudBackup.shared
    @EnvironmentObject var viewModel: AppViewModel
    @ObservedObject private var call = CallManager.shared

    private enum Tab { case chats, profile }
    @State private var selection: Tab = .chats
    @State private var profileTaps = 0
    @State private var lastProfileTap = Date.distantPast
    @State private var showDebug = false

    var body: some View {
        // повторный тап по уже выбранной вкладке SwiftUI прокидывает в set(:) то же значение —
        // на этом ловим «10 быстрых тапов по Профилю» → скрытое служебное меню
        TabView(selection: Binding(get: { selection }, set: handleSelect)) {
            ChatListView()
                .tabItem { Label(L("Чаты"), systemImage: "message.fill") }
                .tag(Tab.chats)
            ProfileView()
                .tabItem { Label(L("Профиль"), systemImage: "person.fill") }
                .tag(Tab.profile)
        }
        .sheet(isPresented: $showDebug) { HiddenDebugMenuView() }
        // переход в чат (уведомление, ссылка) — с любой вкладки: маршрут разбирает список чатов
        .onChange(of: viewModel.pendingChatRoute) { r in if r != nil { selection = .chats } }
        // восстановление ключа: PIN задан → экран ОБЯЗАТЕЛЬНЫЙ (fullScreenCover не смахивается,
        // «Пропустить» нет, состояние переживает перезапуск) — иначе пользователь останется
        // с нерасшифруемым профилем и не найдёт путь назад
        .fullScreenCover(isPresented: $viewModel.needsKeyRecovery) { KeyRecoveryView(mandatory: true) }
        // предложение задать PIN бэкапа после онбординга (взаимоисключимо с восстановлением)
        .sheet(isPresented: $viewModel.showBackupPrompt) { BackupPinView() }
        // однократно: задать PIN (или ввести старый), чтобы копия в iCloud заработала (docs/icloud-backup.md §2).
        // Не поверх онбордингового предложения PIN и не поверх обязательного восстановления.
        .sheet(item: Binding(get: { viewModel.showBackupPrompt || viewModel.needsKeyRecovery ? nil : backup.pinPrompt },
                             set: { backup.pinPrompt = $0 }),
               onDismiss: { Task { await backup.restoreIfAvailable(); await backup.backupNow() } }) { prompt in
            switch prompt {
            case .set:   BackupPinView()
            case .enter: ICloudPinSheet()
            }
        }
        // копия из iCloud восстанавливается сама и молча (ICloudBackup.restoreIfAvailable); вслух —
        // только если не получилось
        .alert(backup.restoreResult ?? "",
               isPresented: Binding(get: { backup.restoreResult != nil }, set: { if !$0 { backup.restoreResult = nil } })) {
            Button("OK") { backup.restoreResult = nil }
        }
        // Пока идёт восстановление — лоадер по центру поверх всего, нажатия перекрыты: открыть
        // полупустой чат или написать в него, пока история ещё не легла, — путаница
        .overlay {
            if backup.restoring {
                ZStack {
                    Color.black.opacity(0.6).ignoresSafeArea()
                    ProgressView(L("Восстанавливаем переписку…")).tint(.white).foregroundStyle(.white)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: backup.restoring)
        // экран звонка поверх всего — полный или свёрнутый (полоса / окошко), см. CallPresentation
        .modifier(CallPresentation())
    }

    private func handleSelect(_ newValue: Tab) {
        if newValue == .profile {
            let now = Date()
            if now.timeIntervalSince(lastProfileTap) > 1.5 { profileTaps = 0 }   // серия прервалась → сброс
            lastProfileTap = now
            profileTaps += 1
            if profileTaps >= 10 { profileTaps = 0; showDebug = true }
        } else {
            profileTaps = 0
        }
        selection = newValue
    }
}
