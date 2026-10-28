import UIKit
import IronSource

// Rewarded-реклама для заработка Rings — Unity LevelPlay (ironSource) SDK 9.x, без адаптеров
// сторонних сетей (реклама только ironSource Ads; медиация позже = адаптер-поды + сети в дашборде).
// AppLovin не принял аккаунт издателя (октябрь 2026), отсюда смена сети.
//
// Начисление делает СЕРВЕР по S2S-колбэку LevelPlay: userId из `withUserId` приезжает в колбэк как
// [USER_ID], LevelPlay подписывает его приватным ключом → GET /rings/levelplay-ssv → сервер сверяет
// подпись и начисляет. Колбэк didRewardAd на клиенте — только сигнал «пора поллить баланс», НЕ
// основание начисления.
//
// Приватность (решение владельца): окна ATT НЕТ — реклама без рекламного ID (IDFA), в манифесте
// «трекинга нет». ATS строгий, `NSAllowsArbitraryLoads` не включаем вопреки совету доки LevelPlay:
// часть старых http-креативов может не показаться — компромисс в пользу безопасности.
@MainActor
final class RewardedAdController: NSObject {
    static let shared = RewardedAdController()

    // Значения из дашборда LevelPlay (не секреты: ключ приложения и id блока зашиваются в любое
    // приложение с рекламой; секрет — только приватный ключ колбэка, и он на сервере).
    nonisolated private static let appKey = "29090eafd"
    nonisolated private static let adUnitID = "6s5v3e3k8j19vv14"

    // ЕДИНЫЙ рубильник фичи Rings: без рекламы заработать Rings нечем (IAP вне скоупа) → вся секция
    // нефункциональна, а App Review реджектит нерабочие фичи (Guideline 2.1). По этому флагу
    // скрыты точки входа в Rings (пилюля баланса в списке чатов и строка «Rings» в профиле).
    nonisolated static var adsAvailable: Bool { !appKey.isEmpty && !adUnitID.isEmpty }

    // Test Suite LevelPlay (скрытое меню → «Тест рекламы»): показывает идентификатор, который SDK
    // реально отправляет (нужен для Test devices в дашборде), и проверяет загрузку/показ. Флаг
    // `is_test_suite` SDK принимает только ДО инициализации, поэтому он запоминается на устройстве:
    // если SDK уже поднят без него, тест откроется после перезапуска приложения.
    nonisolated private static let testSuiteKey = "ads.testSuite"
    enum TestSuiteResult { case launching, needsRestart, unavailable }

    private var rewardedAd: LPMRewardedAd?
    private var initialized = false
    private var initializing = false
    private var testSuiteEnabled = false
    private weak var pendingTestSuite: UIViewController?
    private var retryDelay: TimeInterval = 2
    private var onRewardCb: (() -> Void)?

    var isReady: Bool { rewardedAd?.isAdReady() == true }

    // Идемпотентная инициализация → предзагрузка. Зовётся из RingsView.task.
    func prepare(from presenter: UIViewController) {
        guard Self.adsAvailable else { return }
        if initialized { load(); return }
        // пользователь из ЕС ещё не ответил на запрос согласия — SDK не поднимаем (RingsView спросит)
        guard !initializing, !AdConsent.needsAnswer, let userId = AuthState.myUserId else { return }
        initializing = true
        AdConsent.apply()

        if UserDefaults.standard.bool(forKey: Self.testSuiteKey) {
            LevelPlay.setMetaDataWithKey("is_test_suite", value: "enable")
            testSuiteEnabled = true
        }

        // userId → [USER_ID] в S2S-колбэке. Без него сервер не поймёт, кому начислить.
        let request = LPMInitRequestBuilder(appKey: Self.appKey)
            .withUserId(userId)
            .build()
        // контроллер — синглтон, поэтому в колбэке берём shared, а не захватываем self
        LevelPlay.initWith(request) { _, error in
            Task { @MainActor in
                let controller = RewardedAdController.shared
                controller.initializing = false
                if let error {
                    // Нет сети и т.п. — по доке «повторить позже»: следующий заход в Rings вызовет prepare снова
                    CallDiag.log("📺 реклама: инициализация не удалась — \(error.localizedDescription)")
                    controller.pendingTestSuite = nil
                    return
                }
                controller.initialized = true
                controller.load()
                if let presenter = controller.pendingTestSuite {
                    controller.pendingTestSuite = nil
                    LevelPlay.launchTestSuite(presenter)
                }
            }
        }
    }

    func load() {
        guard initialized else { return }
        if rewardedAd == nil {
            // объект многоразовый: один на блок, грузим и показываем через него же
            let ad = LPMRewardedAd(adUnitId: Self.adUnitID)
            ad.setDelegate(self)
            rewardedAd = ad
        }
        if rewardedAd?.isAdReady() == false { rewardedAd?.loadAd() }
    }

    // показать рекламу; onReward() — пользователь досмотрел (UI после этого поллит баланс).
    @discardableResult
    func show(from presenter: UIViewController, onReward: @escaping () -> Void,
              onUnavailable: @escaping () -> Void) -> Bool {
        guard let ad = rewardedAd, ad.isAdReady() else {
            CallDiag.log("📺 реклама: показать нечего — SDK \(initialized ? "запущен" : (initializing ? "запускается" : "не запущен")), блок \(rewardedAd == nil ? "не создан" : "не загружен")")
            onUnavailable()
            load()
            return false
        }
        onRewardCb = onReward
        ad.showAd(viewController: presenter, placementName: nil)
        return true
    }

    func openTestSuite(from presenter: UIViewController) -> TestSuiteResult {
        // для ЕС без ответа на запрос согласия SDK не поднимается — сначала открыть экран Rings
        guard Self.adsAvailable, !AdConsent.needsAnswer, AuthState.myUserId != nil else { return .unavailable }
        UserDefaults.standard.set(true, forKey: Self.testSuiteKey)
        // SDK уже поднят (или поднимается) без флага — включить тест можно только перезапуском
        if (initialized || initializing) && !testSuiteEnabled { return .needsRestart }
        if initialized {
            LevelPlay.launchTestSuite(presenter)
        } else {
            pendingTestSuite = presenter
            prepare(from: presenter)
        }
        return .launching
    }
}

// Колбэки SDK приходят на главном потоке (так в заголовке LPMRewardedAdDelegate).
extension RewardedAdController: LPMRewardedAdDelegate {
    // == загрузка ==
    nonisolated func didLoadAd(with adInfo: LPMAdInfo) {
        MainActor.assumeIsolated {
            retryDelay = 2
            CallDiag.log("📺 реклама: загружена (\(adInfo.adNetwork))")
        }
    }

    nonisolated func didFailToLoadAd(withAdUnitId adUnitId: String, error: Error) {
        MainActor.assumeIsolated {
            let e = error as NSError
            CallDiag.log("📺 реклама: не загрузилась — \(e.code) \(e.localizedDescription), повтор через \(Int(retryDelay)) с")
            // экспоненциальный ретрай (не крутим load в тайтовом цикле)
            let delay = retryDelay
            retryDelay = min(retryDelay * 2, 60)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                self.load()
            }
        }
    }

    // == показ ==
    // По доке следующую рекламу грузят после успешного показа; объект тот же.
    nonisolated func didDisplayAd(with adInfo: LPMAdInfo) {
        MainActor.assumeIsolated { load() }
    }

    nonisolated func didFailToDisplayAd(with adInfo: LPMAdInfo, error: Error) {
        MainActor.assumeIsolated {
            let e = error as NSError
            CallDiag.log("📺 реклама: не показалась — \(e.code) \(e.localizedDescription)")
            onRewardCb = nil
            load()
        }
    }

    // == награда (клиентский сигнал; начисление — по S2S-колбэку на сервере) ==
    // ⚠️ Может прийти и ПОСЛЕ didCloseAd (по доке они асинхронны) — поэтому сигнал не привязан к закрытию.
    nonisolated func didRewardAd(with adInfo: LPMAdInfo, reward: LPMReward) {
        MainActor.assumeIsolated {
            onRewardCb?()
            onRewardCb = nil
        }
    }
}
