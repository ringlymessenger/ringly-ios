import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

// Раздел «Rings»: баланс + заработок рекламой + услуга «кастомный гудок» (покупка тарифа + мелодия).
struct RingsView: View {
    var showsDone = false                 // true при показе в sheet (с главной) → кнопка «Готово»
    @StateObject private var vm = RingsViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var showImporter = false
    @State private var processing = false
    @State private var askConsent = false
    @State private var pendingPlan: PendingPlan?   // тариф ждёт подтверждения (покупка списывает Rings)

    private struct PendingPlan {
        let title: String, price: Int, plan: String, days: Int
    }

    @State private var trimSource: TrimSource?     // длинный трек ждёт выбора фрагмента

    private struct TrimSource: Identifiable {
        let id = UUID()
        let url: URL                               // tmp-копия выбранного файла
        let name: String
    }
    @State private var personalizedAds = AdConsent.granted ?? false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                balanceCard
                earnCard
                ringbackCard
            }
            .padding(16)
        }
        .background(AppColor.background.ignoresSafeArea())
        .navigationTitle("Rings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            if showsDone {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("Готово")) { dismiss() }
                }
            }
        }
        .task {
            await vm.load()
            if AdConsent.needsAnswer { askConsent = true } else { prepareAds() }
        }
        // GDPR: спрашиваем ДО запуска рекламного SDK, иначе первый запрос ушёл бы без ответа
        .alert(L("Персонализированная реклама"), isPresented: $askConsent) {
            Button(L("Разрешить")) { answerConsent(true) }
            Button(L("Не разрешать")) { answerConsent(false) }
        } message: {
            Text(L("Rings зарабатываются просмотром рекламы от Unity. Разрешить подбирать её по данным об устройстве и о том, как вы смотрите рекламу? Реклама будет в любом случае, выбор можно изменить на этом экране."))
        }
        // Покупка списывает Rings и вернуть их нельзя — без подтверждения случайное нажатие на соседний
        // тариф молча тратило баланс. Тариф не «переключается», а ДОБАВЛЯЕТ дни к текущему сроку.
        .alert(pendingPlanTitle, isPresented: Binding(get: { pendingPlan != nil }, set: { if !$0 { pendingPlan = nil } }),
               presenting: pendingPlan) { p in
            Button(L("Купить")) { Task { await vm.purchase(plan: p.plan) } }
            Button(L("Отмена"), role: .cancel) {}
        } message: { p in
            Text(L("Спишется %@ Rings. Гудок будет работать до %@.", "\(p.price)", vm.expiryText(afterBuying: p.days)))
        }
        .refreshable { await vm.load() }
        .overlay(alignment: .bottom) { toastView }
        .alert(L("Ошибка"), isPresented: Binding(get: { vm.errorMessage != nil }, set: { if !$0 { vm.errorMessage = nil } })) {
            Button("OK") { vm.errorMessage = nil }
        } message: { Text(vm.errorMessage ?? "") }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.mp3], allowsMultipleSelection: false) { result in
            handlePickedFile(result)
        }
        .sheet(item: $trimSource) { source in
            RingbackTrimView(fileURL: source.url, fileName: source.name,
                             onDone: { finishTrim(source, start: $0) },
                             onCancel: { finishTrim(source, start: nil) })
                .interactiveDismissDisabled()     // закрытие только кнопками — иначе tmp-файл не убрать
        }
    }

    // ===== баланс =====
    private var balanceCard: some View {
        VStack(spacing: 6) {
            Text(L("Баланс")).font(.subheadline).foregroundStyle(AppColor.subtext)
            HStack(spacing: 8) {
                RingsCoinIcon(size: 34)
                Text("\(vm.balance)").font(.system(size: 40, weight: .bold)).foregroundStyle(AppColor.text)
                Text("Rings").font(.title3).foregroundStyle(AppColor.subtext)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // ===== заработок рекламой =====
    private var earnCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Получить Rings")).font(.headline).foregroundStyle(AppColor.text)
            if let s = vm.status {
                Text("Смотрите рекламу: +\(s.adReward) Rings за просмотр. Осталось сегодня: \(vm.adsLeftToday) из \(s.adDailyLimit).")
                    .font(.subheadline).foregroundStyle(AppColor.subtext)
            }
            Button { watchAd() } label: {
                HStack {
                    Image(systemName: "play.rectangle.fill")
                    Text(L("Посмотреть рекламу")).bold()
                }
                .frame(maxWidth: .infinity, minHeight: 46)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .disabled(vm.busy || vm.adsLeftToday == 0)

            if AdConsent.required {
                Divider().overlay(AppColor.hairline)
                Toggle(L("Персонализированная реклама"), isOn: $personalizedAds)
                    .foregroundStyle(AppColor.text)
                    .onChange(of: personalizedAds) { _, on in
                        // тот же переключатель отражает и ответ в алерте — не пишем повторно то же значение
                        if AdConsent.granted != on { AdConsent.set(on) }
                    }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // ===== кастомный гудок =====
    private var ringbackCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "music.note").foregroundStyle(.pink)
                Text(L("Кастомный гудок")).font(.headline).foregroundStyle(AppColor.text)
            }
            Text(L("Пока вам звонят, собеседник слышит вашу мелодию вместо стандартного гудка."))
                .font(.subheadline).foregroundStyle(AppColor.subtext)

            if vm.active {
                if let until = vm.expiresAtText {
                    Label("Активно до \(until)", systemImage: "checkmark.seal.fill")
                        .font(.subheadline).foregroundStyle(.green)
                }
                audioControls
                Divider().overlay(AppColor.hairline)
                Text(L("Продлить")).font(.subheadline).foregroundStyle(AppColor.subtext)
                plans
            } else {
                Text(L("Услуга неактивна. Выберите период, чтобы включить:"))
                    .font(.subheadline).foregroundStyle(AppColor.subtext)
                plans
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var audioControls: some View {
        VStack(spacing: 10) {
            let hasMelody = vm.status?.ringback?.attachmentId != nil
            Button { showImporter = true } label: {
                HStack {
                    if processing { ProgressView().tint(.white) }   // внутри залитой кнопки
                    else { Image(systemName: "arrow.up.doc.fill") }
                    Text(processing ? L("Обработка…") : (hasMelody ? L("Заменить мелодию") : L("Загрузить мелодию (MP3)"))).bold()
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent).tint(.pink)
            .disabled(vm.busy || processing)

            if hasMelody {
                Button(role: .destructive) {
                    Task { await vm.deleteAudio() }
                } label: {
                    Text(L("Удалить мелодию")).frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.bordered).tint(.red)
                .disabled(vm.busy || processing)
            }
            Text(L("MP3 любой длины. Звонящий услышит первые 45 секунд — столько длится дозвон. Громкость выровняется автоматически."))
                .font(.caption).foregroundStyle(AppColor.subtext)
        }
    }

    private var plans: some View {
        VStack(spacing: 8) {
            if let p = vm.status?.prices {
                planRow(title: L("7 дней"), price: p.d7, plan: "7d", days: 7)
                planRow(title: L("30 дней"), price: p.d30, plan: "30d", days: 30)
                planRow(title: L("90 дней"), price: p.d90, plan: "90d", days: 90)
            }
        }
    }

    private var pendingPlanTitle: String {
        guard let p = pendingPlan else { return "" }
        return vm.active ? L("Продлить на %@?", p.title) : L("Включить на %@?", p.title)
    }

    private func planRow(title: String, price: Int, plan: String, days: Int) -> some View {
        Button {
            pendingPlan = PendingPlan(title: title, price: price, plan: plan, days: days)
        } label: {
            HStack {
                Text(title).foregroundStyle(AppColor.text)
                Spacer()
                Text("\(price) Rings")
                    .font(.subheadline.bold())
                    .foregroundStyle(vm.balance >= price ? Color.yellow : AppColor.faint)
            }
            .padding(.vertical, 12).padding(.horizontal, 14)
            .background(AppColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(vm.busy || vm.balance < price)
    }

    @ViewBuilder private var toastView: some View {
        if let toast = vm.toast {
            Text(toast)
                .font(.subheadline.bold()).foregroundStyle(AppColor.text)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // ===== действия =====

    private func prepareAds() {
        if let presenter = topViewController() { RewardedAdController.shared.prepare(from: presenter) }
    }

    private func answerConsent(_ granted: Bool) {
        AdConsent.set(granted)
        personalizedAds = granted
        prepareAds()
    }

    private func watchAd() {
        // алерт закрыли, не ответив (например, свернули приложение) — спрашиваем снова
        if AdConsent.needsAnswer { askConsent = true; return }
        // ВЕРХНИЙ контроллер, не корневой: с главной экран Rings открыт шитом, корень уже занят им,
        // и Unity Ads молча не мог показать рекламу поверх («already presenting») → таймаут показа
        guard let presenter = topViewController() else { return }
        RewardedAdController.shared.show(
            from: presenter,
            onReward: { Task { await vm.pollAfterAd() } },
            onUnavailable: { vm.errorMessage = L("Реклама сейчас недоступна. Попробуйте позже.") }
        )
    }

    // Трек длиннее 45 с → сначала редактор фрагмента (RingbackTrimView), короче — сразу в обработку.
    private func handlePickedFile(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let picked = urls.first else { return }
        Task {
            do {
                // копируем из security-scoped источника в tmp, дальше работаем с локальной копией
                let needsScope = picked.startAccessingSecurityScopedResource()
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("pick-\(UUID().uuidString).mp3")
                try FileManager.default.copyItem(at: picked, to: tmp)
                if needsScope { picked.stopAccessingSecurityScopedResource() }

                let duration = CMTimeGetSeconds(try await AVURLAsset(url: tmp).load(.duration))
                if duration > RingbackStudio.maxDuration + 0.5 {
                    trimSource = TrimSource(url: tmp, name: picked.deletingPathExtension().lastPathComponent)
                } else {
                    await processAndUpload(tmp, start: 0)
                }
            } catch {
                CallDiag.log("🎵 мелодия: файл не открылся — \(error)")
                vm.errorMessage = error.localizedDescription
            }
        }
    }

    // tmp-копию удаляем здесь в любом исходе — и после отмены редактора (finishTrim)
    private func processAndUpload(_ tmp: URL, start: Double) async {
        processing = true
        defer {
            processing = false
            try? FileManager.default.removeItem(at: tmp)
        }
        do {
            let processed = try await RingbackStudio.process(inputURL: tmp, start: start)
            await vm.uploadProcessed(processed)
        } catch {
            CallDiag.log("🎵 мелодия: обработка не удалась — \(error)")
            vm.errorMessage = error.localizedDescription
        }
    }

    private func finishTrim(_ source: TrimSource, start: Double?) {
        trimSource = nil
        if let start {
            Task { await processAndUpload(source.url, start: start) }
        } else {
            try? FileManager.default.removeItem(at: source.url)
        }
    }
}
