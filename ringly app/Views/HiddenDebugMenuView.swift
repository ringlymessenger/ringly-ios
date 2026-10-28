import SwiftUI

// Скрытое служебное меню: открывается 10 быстрыми тапами по вкладке «Профиль» в таб-баре.
// Сюда перенесены отладочные инструменты, убранные из обычного UI: журнал звонков и полный сброс.
struct HiddenDebugMenuView: View {
    @EnvironmentObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false
    @State private var simulateBlock = EndpointResolver.shared.simulateBlock
    @State private var simulateCallBlock = CallSettings.simulateBlock
    @State private var adTestAlert: String?

    var body: some View {
        NavigationStack {
            List {
                Section(L("Диагностика")) {
                    NavigationLink { callLogs } label: {
                        Label(L("Логи"), systemImage: "ladybug")
                    }
                }
                Section {
                    Toggle(isOn: $simulateBlock) {
                        Label(L("Имитировать блокировку"), systemImage: "network.slash")
                    }
                    .onChange(of: simulateBlock) { _, on in EndpointResolver.shared.setSimulateBlock(on) }
                } header: {
                    Text(L("Обход блокировок"))
                } footer: {
                    Text(L("Прямой путь к серверу перестаёт работать, мостики — нет. Так можно проверить переключение на мостик там, где Ringly не заблокирован. Сначала выбери «Напрямую» в Профиль → Обход блокировок. Не забудь выключить."))
                }
                Section {
                    Toggle(isOn: $simulateCallBlock) {
                        Label(L("Имитировать блокировку звонков"), systemImage: "phone.down")
                    }
                    .onChange(of: simulateCallBlock) { _, on in
                        CallSettings.simulateBlock = on
                        CallManager.shared.warmUpIce()   // сразу перезапросить TURN под новый режим
                    }
                } footer: {
                    Text(L("Звонок идёт только через волонтёрский TURN или через мостик: центральный сервер напрямую и прямое соединение недоступны, как в худшем случае при блокировке. Если нет ни того, ни другого, звонок не соединится. Какой путь выдан — в логах (🧊)."))
                }
                Section {
                    Button { openAdTestSuite() } label: {
                        Label(L("Тест рекламы"), systemImage: "play.rectangle")
                    }
                } footer: {
                    Text(L("Экран LevelPlay: идентификатор этого устройства для тестовых устройств в дашборде и проверка загрузки и показа рекламы."))
                }
                Section {
                    Button(role: .destructive) { confirmReset = true } label: {
                        Label(L("Полный сброс…"), systemImage: "trash")
                    }
                } footer: {
                    Text(L("Удалит ключи, профиль и историю чатов на этом устройстве. Приложение закроется — открой его заново."))
                }
            }
            .navigationTitle(L("Служебное меню"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button(L("Готово")) { dismiss() } }
            }
            .alert(L("Стереть всё с этого устройства?"), isPresented: $confirmReset) {
                Button(L("Стереть"), role: .destructive) { viewModel.fullReset() }
                Button(L("Отмена"), role: .cancel) {}
            } message: {
                Text(L("Удалит ключи, профиль и историю чатов на этом устройстве. Приложение закроется — открой его заново."))
            }
            .alert(adTestAlert ?? "", isPresented: Binding(get: { adTestAlert != nil }, set: { if !$0 { adTestAlert = nil } })) {
                Button(L("Готово"), role: .cancel) {}
            }
        }
    }

    private func openAdTestSuite() {
        guard let presenter = topViewController() else { return }
        switch RewardedAdController.shared.openTestSuite(from: presenter) {
        case .launching: break
        case .needsRestart:
            adTestAlert = L("Реклама уже запущена без тестового режима. Закрой приложение полностью, открой снова и нажми ещё раз.")
        case .unavailable:
            adTestAlert = L("Реклама недоступна.")
        }
    }

    private var callLogs: some View {
        CallDiagView()
            .navigationTitle(L("Логи"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(L("Очистить")) { CallDiag.shared.clear() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { UIPasteboard.general.string = CallDiag.shared.fullText } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
            }
    }
}
