// файл: AppViewModel.swift
import SwiftUI
import Combine
import UIKit
import UserNotifications

enum AppState {
    case splash
    case auth
    case onboarding
    case home
}

@MainActor
final class AppViewModel: ObservableObject {
    static let shared = AppViewModel()   // singleton — чтобы AppDelegate (VoIP) мог поднять сессию на холодном старте
    @Published var state: AppState = .splash
    @Published var me: MeResponse? = nil           // сырые данные с сервера
    @Published var profile: ProfileData? = nil     // расшифрованные имя/фамилия (nil, если нет ключа)
    @Published var errorMessage: String? = nil     // для показа ошибок в UI
    @Published var avatarImage: UIImage? = nil
    @Published var needsKeyRecovery = false        // «шифр есть, ключа нет» → показать экран восстановления

    // статус подключения для шапки списка чатов (Telegram-style)
    enum ConnectionStatus { case connecting, updating, online }
    @Published private(set) var connStatus: ConnectionStatus = .connecting
    @Published var showBackupPrompt = false        // после онбординга: предложить задать PIN бэкапа (один раз)
    @Published var conversations: [ConversationItem] = []
    @Published var pendingChatRoute: ChatRoute?

    // Обход блокировок: пути наружу нет совсем (прямой не работает, мостиков не знаем).
    // Показывается алертом на корне сцены — то есть с любого экрана. См. relay-daemon.md §8.
    @Published var showNoRouteAlert = false

    private let auth = AuthService()
    private let profileService = ProfileService()
    private let keysService = KeysService()
    private let syncService = ProfileKeySyncService()
    private let historySync = HistorySyncService()   // синхронизация истории (docs/history-sync.md)
    private var syncTask: Task<Void, Never>?        // цикл синхронизации Profile Key (этапы 0/1)
    private let ws = WebSocketClient()
    private var messagingPollTask: Task<Void, Never>?   // периодический sync, пока приложение активно
    private var backgrounding = false                   // ушли в фон и ждём отложенный teardown WS
    private var badgeTask: Task<Void, Never>?           // обновление бейджа иконки при изменении непрочитанных
    
    let backupService = ProfileKeyBackupService()   // зовётся из UI восстановления
    let messaging = MessagingService()

    init() {
        // пуш-будильники от AppDelegate (silent profile_key_sync / content-free new_message)
        NotificationCenter.default.addObserver(forName: .pushSyncRequested, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.startKeySync() }
        }
        NotificationCenter.default.addObserver(forName: .pushNewMessage, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.messaging.sync(); await self?.loadConversations() }
        }
        // NSE записал сообщение из своего процесса → перечитать БД (ValueObservation чужой процесс не видит)
        CrossProcessNotifier.shared.onNewMessage = {
            NotificationCenter.default.post(name: .pushNewMessage, object: nil)
        }
        CrossProcessNotifier.shared.startObserving()
        // VoIP-пуш входящего звонка → поднять WS, чтобы accept/сигналинг ушли (в т.ч. на холодном старте)
        NotificationCenter.default.addObserver(forName: .callWake, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.me != nil { self.startMessaging() } else { await self.bootstrap() }
            }
        }
        // Обход блокировок: пути наружу нет вообще (ни прямого, ни мостиков) — показать алерт.
        // Частоту ограничивает сам резолвер (не чаще раза в 10 минут), здесь только показ.
        NotificationCenter.default.addObserver(forName: EndpointResolver.strandedNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.showNoRouteAlert = true }
        }
        // Сменился транспорт (напрямую ↔ мостик) — обновить ICE-серверы: на мостике к ним добавляется
        // TURN через мостик, без него — убирается. Без смены warmUpIce ничего не делает (список свежий).
        NotificationCenter.default.addObserver(forName: EndpointResolver.stateChangedNotification,
                                               object: nil, queue: .main) { _ in
            Task { @MainActor in CallManager.shared.warmUpIce() }
        }
    }

    // VoIP-пуш (в т.ч. холодный старт): поднять WS + CallManager, чтобы accept/сигналинг звонка ушли.
    // Полный профиль (fetchMe) не ждём — для звонка достаточно токена (keychain) + AuthState (App Group).
    #if DEBUG
    // стенд скриншотов для App Store: шапка «Ringly», а не «Соединение…» (сети на стенде нет)
    func debugMarkOnline() { connStatus = .online }
    #endif

    func ensureReadyForCall() {
        backgrounding = false          // звонок важнее: отложенный teardown фона больше не рвёт сокет
        startMessaging()
    }

    // запросить разрешение на уведомления + зарегистрировать APNs- и VoIP-токены на бэке (идемпотентно)
    private func enablePush() {
        PushService.shared.requestAuthorization()
        Task { await PushService.shared.registerIfPossible() }
        Task { await PushService.shared.registerVoipIfPossible() }   // VoIP-токен мог уже прийти от PushKit
    }

    // 1. СПЛЕШ: проверяем сохранённый токен
    func bootstrap() async {
        SignalProtocolStore.shared.migrateIfNeeded()   // разовый перенос крипто-стора Keychain → SQLCipher
        guard TokenStore.shared.token != nil else {
            state = .auth                          // токена нет → вход
            return
        }
        // Очередь исходящих поднимаем ДО fetchMe и вне do/catch: именно запуск без сети — тот
        // случай, ради которого она и существует. Внутри do она не стартовала бы, потому что
        // fetchMe упал бы первым, и накопленные сообщения ждали бы удачного запуска.
        OutboxWorker.shared.start()

        // Как в Telegram: если этот аккаунт здесь уже был, показываем то, что знаем, СРАЗУ — и только
        // потом идём в сеть. Раньше запуск ждал ответа /me на сплеше, а без сети это не мгновенная
        // ошибка, а таймаут запроса: человек смотрел на сплеш, потом на пустой список с «Соединение…»,
        // хотя вся переписка лежала в локальной базе.
        //
        // Безопасно, потому что ровно этот режим уже существует — офлайн-ветка ниже давно ведёт на
        // главный экран без /me. Разница только в том, что теперь не нужно сперва дождаться отказа.
        // Если токен на самом деле отозван, /me ответит 401 и ветка catch разлогинит, как и раньше.
        if Self.isOnboardedLocally {
            if conversations.isEmpty { conversations = ConversationCache.load() }
            if state != .home { state = .home }
            startMessaging()                       // идемпотентно: повторы ниже лишь проверят сокет

            // ⚠️ Сеть — в НЕЗАВИСИМОЙ задаче, а не здесь же через await. bootstrap запускается из
            // `.task` сплеша; смена state на .home убирает сплеш с экрана, и SwiftUI ОТМЕНЯЕТ его
            // задачу. Останься /me в ней, запрос падал бы с отменой на каждом запуске — даже при
            // живой сети, — уходил в офлайн-ветку, и приложение жило бы без /me, регистрации ключей
            // и пушей. Неструктурированный Task наследует главный актор, но не отмену родителя.
            Task { await self.refreshSession() }

            return
        }

        await refreshSession()
    }

    // Сетевая половина запуска: узнать, кто мы, и поднять всё, что требует сервера.
    private func refreshSession() async {
        do {
            let me = try await auth.fetchMe()      // токен есть → кто мы?
            setMe(me)
            state = (me.onboardingState == .completed) ? .home : .onboarding
            if me.onboardingState == .completed { Self.markOnboardedLocally() }
            startKeySync()                         // этап 0/1: регистрация ключей + sync Profile Key
            startMessaging()                       // realtime + первый синк сообщений
            // обход блокировок: подтянуть свежие мостики (в фоне, не блокируя запуск). Зовётся на
            // старте и на каждом foreground (bootstrap повторяется в appBecameActive).
            Task { await EndpointResolver.shared.refreshBridges() }
            if state == .home { enablePush() }     // разрешение + регистрация FCM-токена
        } catch {
            if CallManager.shared.phase != .idle { return }   // во время звонка не логаутимся на временной ошибке сети
            if Self.isAuthFailure(error) {
                logout(wipeLocal: false)   // токен отозван → на вход; данные НЕ трогаем (Signal-поведение:
                                           // сервер не может удалённо уничтожить локальную историю)
            } else {
                // временная ошибка (нет сети / бэкенд недоступен) — РАНЬШЕ здесь был logout() с wipe'ом
                // всей истории («запустил без сети → чаты стёрты»). Теперь работаем офлайн с тем, что есть;
                // /me доберём на следующем foreground (appBecameActive → повторный bootstrap).
                state = AuthState.myUserId != nil ? .home : .auth
                startMessaging()       // локальная история доступна; сеть подтянется — синк догонит
            }
        }
    }

    // Знаем ли мы ЛОКАЛЬНО, что этот аккаунт уже прошёл онбординг. Одного `myUserId` мало: он
    // выставляется на первом же /me, ещё ДО онбординга, и по нему недоделавший регистрацию попал бы
    // на главный экран мимо создания профиля. Флаг привязан к id, поэтому вход другим аккаунтом его
    // не унаследует (а wipeAccountLocalData снимает его явно).
    private static let onboardedKey = "onboardedUserId"

    private static var isOnboardedLocally: Bool {
        guard let id = AuthState.myUserId else { return false }

        return AppGroup.defaults.string(forKey: onboardedKey) == id
    }

    private static func markOnboardedLocally() {
        AppGroup.defaults.set(AuthState.myUserId, forKey: onboardedKey)
    }

    // настоящий отказ авторизации (токен отозван) — в отличие от сетевых/серверных сбоев
    private static func isAuthFailure(_ error: Error) -> Bool {
        if case APIError.server(let msg) = error {
            return msg.contains("Invalid token") || msg.contains("Missing bearer token")
        }
        if case APIError.http(let code) = error { return code == 401 }
        return false
    }

    // 2. ВХОД через Google/Apple (зовётся из AuthView)
    func signIn(provider: String, idToken: String) async {
        await completeSignIn { try await self.auth.oauth(provider: provider, idToken: idToken) }
    }

    // вход в демо-аккаунт для App Review (скрытая форма на экране входа)
    func signInDemo(username: String, password: String) async {
        await completeSignIn { try await self.auth.demoLogin(username: username, password: password) }
    }

    func demoLoginEnabled() async -> Bool { await auth.demoLoginEnabled() }

    private func completeSignIn(_ login: () async throws -> OAuthResponse) async {
        errorMessage = nil
        do {
            let res = try await login()
            switch res.onboardingState {
            case .completed:
                setMe(try await auth.fetchMe())    // подтянуть профиль для Home
                state = .home
                startKeySync()                     // этап 0/1: регистрация ключей + sync Profile Key
                startMessaging()                   // realtime + первый синк сообщений
                enablePush()                       // разрешение + регистрация FCM-токена
            case .pendingProfile:
                state = .onboarding                // новый юзер → онбординг
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // 3. КОНЕЦ ОНБОРДИНГА (зовётся из OnboardingView)
    func finishOnboarding() async {
        if let me = try? await auth.fetchMe() {
            setMe(me)
        }
        state = .home
        Self.markOnboardedLocally()
        startKeySync()                             // первое устройство: регистрируем его ключи (станет «донором»)
        startMessaging()                           // realtime + первый синк сообщений
        enablePush()                               // разрешение + регистрация FCM-токена
        // только что создали Profile Key → предложим задать PIN для бэкапа (можно «Позже»)
        if ProfileKeyStore.shared.existingKey() != nil {
            showBackupPrompt = true
            ICloudBackup.shared.markPinPromptShown()   // этот же PIN включает копию в iCloud — не спрашивать дважды
        }
    }

    // ПОЛИТИКА УДАЛЕНИЯ (согласована, полная таблица — ios-profile-key-sync.md):
    //   wipeLocal: true  — явный «Выйти» из Профиля: удаляем ВСЁ аккаунтное сразу (Telegram-поведение).
    //   wipeLocal: false — 401 на старте / выход с экрана PIN: данные ОСТАЮТСЯ зашифрованными;
    //                      тот же аккаунт вернётся → история цела (Signal-поведение для deregistered);
    //                      другой аккаунт войдёт → wipeIfAccountChanged подчистит (страховка приватности).
    // Выход из профиля: если есть копия в iCloud — сначала досохранить её, чтобы при выходе не пропали
    // сообщения новее последней копии. false — досохранить не вышло, выход НЕ выполнен: дальше решает
    // пользователь («выйти всё равно» — обычный logout).
    func logoutSavingBackup() async -> Bool {
        guard await ICloudBackup.shared.backupBeforeLogout() else { return false }
        logout(wipeLocal: true)
        return true
    }

    func logout(wipeLocal: Bool = true) {
        PushService.shared.clearOnLogout()   // DELETE /me/push-token (читает токен до его очистки ниже)
        stopKeySync()
        stopMessaging()
        if wipeLocal {
            wipeAccountLocalData()
        }
        Task { await DeviceResolver.shared.invalidateAll() }   // девайс-листы прошлой сессии
        auth.logout()
        me = nil
        profile = nil
        avatarImage = nil
        conversations = []
        needsKeyRecovery = false
        refreshBadge()   // очистить бейдж иконки (после wipe непрочитанных нет)
        state = .auth
    }

    // Retry receipts (аналог DecryptionErrorMessage у Signal): рассинхронизированную сессию не чинит
    // ничто, кроме её замены, поэтому обе стороны выбрасывают её и отправитель шлёт содержимое заново.
    // Хуки ставит ТОЛЬКО приложение: MessageIngest общий с NSE, а расширению нельзя затевать сетевую
    // работу — у него секунды на баннер. Идемпотентно (startMessaging зовётся многократно).
    private func wireRetryReceipts() {
        MessageIngest.requestRetry = { [weak self] senderUserId, senderDeviceId, messageId, conversationId in
            await self?.messaging.sendRetryRequest(toUserId: senderUserId, toDeviceId: senderDeviceId,
                                                   messageId: messageId, conversationId: conversationId)
        }
        MessageIngest.handleRetry = { [weak self] req, fromUserId, fromDeviceId, conversationId in
            await self?.messaging.handleRetryRequest(req, fromUserId: fromUserId, fromDeviceId: fromDeviceId,
                                                     conversationId: conversationId)
        }
    }

    // Перечитать /me с сервера и пересобрать производное состояние (расшифрованный профиль, аватар).
    // Зовётся после сохранения профиля — единственный источник правды остаётся серверным.
    func reloadMe() async {
        if let me = try? await auth.fetchMe() { setMe(me) }
    }

    // Необратимое удаление аккаунта: сервер сносит профиль/устройства/ключи/беседы и блобы,
    // затем локально делаем ровно то же, что при явном «Выйти» (полная подчистка + экран входа).
    // Возвращает false, если серверу не удалось удалить — тогда локальные данные НЕ трогаем.
    func deleteAccount() async -> Bool {
        struct DeletedResponse: Decodable { let deleted: Bool }
        // копию в iCloud удаляем сами и ДО сервера: сервер до неё дотянуться не может, а после
        // удаления аккаунта копия осталась бы в iCloud навсегда (docs/icloud-backup.md §6)
        await ICloudBackup.shared.deleteRemoteCopy()
        do {
            let _: DeletedResponse = try await APIClient.shared.request("me", method: "DELETE")
        } catch {
            return false
        }
        logout(wipeLocal: true)
        return true
    }

    // Полная подчистка аккаунтных данных (SQL-уровень: файл БД не трогаем — он открыт, удаление файла
    // под живыми хэндлами и есть причина exit(0) в fullReset). Единая точка для «Выйти» и смены аккаунта.
    private func wipeAccountLocalData() {
        ChatStore.wipe()                       // история чатов
        ConversationCache.wipe()               // снимок списка бесед (запуск без сети)
        AppGroup.defaults.removeObject(forKey: Self.onboardedKey)   // мгновенный старт — только для своего аккаунта
        MediaStore.wipe()                      // фото/видео сообщений (лежат файлами, не в БД)
        ReadStore.wipe()                       // read-состояние бесед (непрочитанные)
        ContactProfileStore.wipe()             // имена/аватары контактов
        ContactKeyStore.wipeAll()              // Profile Key контактов
        ProfileKeyStore.shared.clear()         // свой Profile Key
        SignalProtocolStore.shared.wipeAll()   // identity/сессии/prekeys — не переживают смену владельца
        RingsBalanceStore.shared.clear()       // баланс Rings прошлого аккаунта (пилюля на главной)
        AnnouncementStore.shared.clear()       // закрытое объявление прошлого аккаунта
        HistorySyncService.resetFlags()
        ICloudBackup.shared.resetForLogout()   // локальные флаги и половина ключа; сама копия в iCloud остаётся
        AppLock.shared.reset()                 // код-пароль прошлого аккаунта (см. AppLock)
        // флаги регистрации ключей + device-identity: следующий вход зарегистрирует НОВУЮ identity
        UserDefaults.standard.removeObject(forKey: "signalKeysGeneration")
        UserDefaults.standard.removeObject(forKey: "signalRegisteredHost")
        // protocolDeviceId НЕ трогаем: это идентичность физического устройства, она живёт в Keychain
        // и должна пережить выход из аккаунта — иначе повторный вход заведёт на сервере НОВУЮ строку
        // Device, а прежняя останется призраком в fan-out навсегда (см. DeviceIdentity).
        // registrationId, наоборот, сбрасываем: libsignal-стор стёрт, значит регистрация новая.
        AppGroup.defaults.removeObject(forKey: "registrationId")
        AppGroup.defaults.removeObject(forKey: "lastAccountUserId")
    }

    // Полный сброс устройства: стереть ВСЁ локальное состояние и выйти (чистый старт при следующем запуске).
    // exit(0) — намеренно: гарантирует, что не останется залипших синглтонов (открытая БД, AuthState и т.п.).
    func fullReset() {
        stopKeySync()
        stopMessaging()
        DeviceReset.wipeEverything()
        exit(0)
    }

    // --- хуки жизненного цикла сцены (из MessengerApp) ---

    // Уровень 1: при каждом возврате в foreground повторяем sync (постоянная вещь даже после серверного пуша:
    // wake-up может потеряться, поэтому всегда сверяемся с источником правды на сервере).
    func appBecameActive() {
        Task { await AnnouncementStore.shared.refresh() }   // новое объявление — без перезапуска
        backgrounding = false          // вернулись в foreground — отменяем отложенный teardown (если был)
        EndpointResolver.shared.appBecameActive()   // туннель на свежем сокете + повтор своего мостика
        SecurityEvents.drainLog().forEach { CallDiag.log($0) }   // смены ключей собеседников (в т.ч. из NSE)
        CallManager.shared.appBecameActive()        // то же для локального порта TURN через мостик
        if state == .home {
            if CallManager.shared.phase != .idle { return }   // во время звонка ничего не дёргаем (WS не рвём)
            if me == nil {             // офлайн-старт (bootstrap не добрался до /me) → добираем профиль
                Task { await bootstrap() }
                return
            }
            Task { await DeviceResolver.shared.invalidateAll() }   // пока были в фоне, девайс-листы могли измениться
            startKeySync()
            startMessaging()        // перезапустить WS + опрос (идемпотентно)
            ws.notifyActive()       // presence: снова на переднем плане → «в сети»
            ws.resubscribePresence()   // обновить статус собеседника в уже открытом чате (не ждать переоткрытия)
            Task { await PushService.shared.registerIfPossible() }   // токен мог обновиться
            // разбудили из suspend (тап по пушу): Darwin-уведомление мы пропустили — перечитываем БД
            NotificationCenter.default.post(name: .pushNewMessage, object: nil)
            refreshBadge()   // NSE мог выставить бейдж в фоне — синхронизируем с реальным состоянием БД
        }
    }

    func appWentToBackground() {
        if state == .home { ICloudBackup.shared.backupInBackground() }   // досдать изменения в копию iCloud
        if CallManager.shared.phase != .idle { return }       // во время звонка WS держим живым (иначе бэк завершит звонок)
        backgrounding = true
        // presence_inactive — асинхронный WS-кадр; iOS может усыпить апп раньше, чем он уйдёт. Держим апп
        // живым background-task'ом и рвём сокет ТОЛЬКО в колбэке отправки (кадр гарантированно ушёл) —
        // иначе offline не доходит и «залоченный собеседник висит в сети», пока не переоткроешь чат.
        var bg: UIBackgroundTaskIdentifier = .invalid
        bg = UIApplication.shared.beginBackgroundTask(withName: "presence-inactive") {
            if bg != .invalid { UIApplication.shared.endBackgroundTask(bg); bg = .invalid }
        }
        ws.notifyInactiveFlush { [weak self] in
            defer { if bg != .invalid { UIApplication.shared.endBackgroundTask(bg); bg = .invalid } }
            guard let self, self.backgrounding else { return }   // успели вернуться в foreground — WS не рвём
            // пока кадр уходил, мог начаться звонок (VoIP-пуш) — тогда сокет ему нужен
            guard CallManager.shared.phase == .idle else {
                CallDiag.log("🔌 WS: уход в фон отменён — идёт звонок")
                return
            }
            self.stopKeySync()
            self.stopMessaging()
        }
    }

    // зовётся из экрана восстановления (KeyRecoveryView) после успешного restore по PIN
    func reloadAfterKeyRecovered() async {
        if let fresh = try? await auth.fetchMe() { setMe(fresh) }  // profile расшифруется → needsKeyRecovery = false
        HistorySyncService.resetFlags()   // ключ вернулся → перезапросить историю (если есть устройство-донор)
        await ICloudBackup.shared.restoreIfAvailable()   // с PIN пришла и половина ключа копии в iCloud
        startKeySync()                                            // заодно раздадим ключ ждущим соседям
    }

    // --- приватное ---

    // «профиль есть, а ключа нет» — состояние, требующее восстановления (PIN или синк с другого устройства)
    var profileKeyMissing: Bool { me?.encryptedProfile != nil && profile == nil }

    // Отложенная страховка приватности для путей «не удаляем» (401 / выход с экрана PIN): данные
    // прошлого аккаунта стираются, когда на устройство РЕАЛЬНО вошёл другой аккаунт. Повторный вход
    // тем же аккаунтом сохраняет историю.
    private func wipeIfAccountChanged(_ newUserId: String) {
        let key = "lastAccountUserId"
        let last = AppGroup.defaults.string(forKey: key)
        if let last, last != newUserId {
            wipeAccountLocalData()           // та же полная подчистка, что при явном «Выйти»
        }
        AppGroup.defaults.set(newUserId, forKey: key)
    }

    // сохранить ответ /me и сразу попытаться расшифровать профиль
    private func setMe(_ me: MeResponse) {
        wipeIfAccountChanged(me.id)         // отложенный wipe: вход другим аккаунтом → чистим данные прошлого
        self.me = me
        AuthState.myUserId = me.id          // нужен SignalSession для адресации крипты
        if let enc = me.encryptedProfile {
            profile = try? ProfileCrypto.decrypt(enc)   // try? → nil, если ключа нет
        } else {
            profile = nil
        }
        loadAvatar(from: me.avatars)
        if profile != nil {
            needsKeyRecovery = false        // ключ на месте → восстановление не нужно (экран закроется сам)
        } else {
            evaluateKeyRecovery()           // проверяем ПРИ КАЖДОМ setMe → переживает перезапуск приложения
        }
    }

    // Если профиль не расшифровывается И на сервере ЕСТЬ PIN-бэкап → восстановление ОБЯЗАТЕЛЬНО:
    // needsKeyRecovery поднимает несмахиваемый fullScreenCover без «Пропустить» (MainTabView).
    // Иначе (бэкапа нет) ключ может приехать только синком с другого устройства — экран не навязываем.
    // Вычисляется из состояния, а не хранится → «скрыть навсегда» невозможно даже перезапуском.
    private func evaluateKeyRecovery() {
        guard profileKeyMissing, !needsKeyRecovery else { return }
        Task {
            if await backupService.backupExists() == true, profileKeyMissing {
                needsKeyRecovery = true
            }
        }
    }

    // файл: AppViewModel.swift — заменить loadAvatar
    private func loadAvatar(from avatars: [AvatarItem]) {
        avatarImage = nil
        guard !avatars.isEmpty else { return }

        Task {
            // 1. сначала маленькая (small) — качается быстро, показываем сразу
            if let small = avatars.first,
               let img = try? await profileService.loadAvatar(from: small.url) {
                avatarImage = img
            }
            // 2. потом крупная (large) — заменяем на чёткую, когда докачается
            if let large = avatars.last,
               large.id != avatars.first?.id,                      // если размер один — не качаем повторно
               let img = try? await profileService.loadAvatar(from: large.url) {
                avatarImage = img
            }
        }
    }
    
    // Единый цикл синхронизации Profile Key (этапы 0/1).
    // - один немедленный проход + повтор, пока приложение активно (уровень 2 — временный опрос вместо пуша);
    // - перезапускается на старте/логине и на каждый foreground (уровень 1).
    func startKeySync() {
        guard let current = me, current.onboardingState == .completed else { return }
        stopKeySync()
        syncTask = Task {
            await keysService.registerIfNeeded()     // этап 0: наши ключи на сервере
            await keysService.topUpIfLow()
            if ProfileKeyStore.shared.existingKey() == nil {
                await syncService.requestKey()       // новичок: попросить ключ (один раз; на сервере upsert)
            }

            var misses = 0
            while !Task.isCancelled {
                guard let me, me.onboardingState == .completed else { break }

                // история переписки (Signal linked-device sync): донор отдаёт архив, новое
                // устройство просит и забирает. Все вызовы дёшевы и идемпотентны (guard'ы внутри).
                await historySync.serveRequests(myUserId: me.id)
                await historySync.requestIfNeeded()
                await historySync.fetchAndImport(myUserId: me.id, devices: me.devices ?? [])

                if ProfileKeyStore.shared.existingKey() != nil {
                    // ДОНОР: раздаём ключ запросившим соседям
                    await syncService.serveRequests(myUserId: me.id)
                } else {
                    // НОВИЧОК: не пришёл ли конверт
                    let got = await syncService.fetchAndDecrypt(myUserId: me.id, devices: me.devices ?? [])
                    if got {
                        if let fresh = try? await auth.fetchMe() { setMe(fresh) }   // перерисуем с расшифровкой
                    } else {
                        misses += 1
                        // ~30с (3×10с) никто не ответил и профиль зашифрован → проверить необходимость
                        // PIN-восстановления (>=, а не ==: сетевой сбой проверки не должен потерять экран).
                        // Цикл при этом продолжается: если донор появится позже, ключ всё равно подтянется.
                        if misses >= 3, me.encryptedProfile != nil { evaluateKeyRecovery() }
                    }
                }

                // TODO(уровень 3): заменить серверным пушем (FCM/WS wake-up). Пока — лёгкий периодический опрос.
                try? await Task.sleep(nanoseconds: 10_000_000_000)   // 10с
            }
        }
    }

    func stopKeySync() {
        syncTask?.cancel()
        syncTask = nil
    }
    
    // вызвать после входа/бутстрапа (когда state == .home). Стартует realtime + первый синк.
    // бейдж иконки = число непрочитанных (от не-замьюченных). Считается локально (E2EE: сервер не знает).
    func refreshBadge() {
        UNUserNotificationCenter.current().setBadgeCount(ReadStore.totalUnreadBadge())
    }

    func startMessaging() {
        guard TokenStore.shared.token != nil else { return }   // токена достаточно (для холодного старта звонка без fetchMe)
        CallManager.shared.warmUpIce()   // TURN-креды заранее: иначе ПЕРВЫЙ звонок сессии идёт без релея
        wireRetryReceipts()              // самовосстановление сессий (только приложение, не NSE)
        ICloudBackup.shared.start()      // копия переписки в iCloud: предложить восстановление + раз в 30 мин
        // app-wide наблюдатель непрочитанных → живое обновление бейджа (новое сообщение / открыл чат). Один раз.
        if badgeTask == nil {
            badgeTask = Task { [weak self] in
                for await _ in ReadStore.observeSummaries() { self?.refreshBadge() }
            }
        }
        if messagingPollTask != nil {                // уже запущено — НЕ пересоздаём (иначе рвём WS = бэк рушит звонки)
            ws.connect()                              // только убедимся, что сокет жив (идемпотентно)
            return
        }
        // статус для шапки: сокет открылся → «Обновление…» на время дренажа очереди, затем «Чаты»;
        // сокет упал/реконнект с бэкоффом → «Соединение…»
        ws.onConnectionState = { [weak self] open in
            Task { @MainActor in
                guard let self else { return }
                if open {
                    self.connStatus = .updating
                    Task {
                        await self.messaging.sync()
                        await self.loadConversations()
                        await MainActor.run { if self.connStatus == .updating { self.connStatus = .online } }
                    }
                } else {
                    self.connStatus = .connecting
                }
            }
        }
        ws.onDeliver = { [weak self] in Task { await self?.messaging.sync(); await self?.loadConversations() } }
        // конверт пришёл целиком по сокету — расшифровываем без GET /messages
        ws.onEnvelope = { [weak self] d in Task { await self?.messaging.ingest(d); await self?.loadConversations() } }
        ws.onStatus = { messageId, state in          // delivered от сервера → апдейт статуса
            if state == "delivered" { ChatStore.applyStatus(serverMessageId: messageId, .delivered) }
        }
        ws.onSync = { [weak self] in Task { @MainActor in self?.startKeySync() } }   // {type:"sync"} → синк Profile Key
        ws.onCallEvent = { type, payload in Task { @MainActor in CallManager.shared.handleEvent(type, payload) } }
        ws.onPresence = { userId, online, seen in Task { @MainActor in PresenceStore.shared.apply(userId: userId, online: online, lastSeenAt: seen) } }
        // дать CallManager отправлять call_* по WS и сигналинг через messaging
        CallManager.shared.messaging = messaging
        CallManager.shared.sendWSEvent = { [weak self] event, data in self?.ws.send(event: event, data: data) }
        ws.connect()
        // периодический опрос — страховка от потерянного WS-пинга, пока приложение активно
        messagingPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.messaging.sync()
                await self.loadConversations()
                try? await Task.sleep(nanoseconds: 10_000_000_000)   // 10с
            }
        }
    }

    func stopMessaging() {
        CallDiag.log("🔌 WS остановлен (фон/выход)")
        ICloudBackup.shared.stop()
        messagingPollTask?.cancel()
        messagingPollTask = nil
        ws.disconnect()
    }

    // presence собеседника: подписка при открытии чата, отписка при выходе (проброс в WS)
    func presenceSubscribe(_ userId: String) { ws.subscribePresence(userId) }
    func presenceUnsubscribe(_ userId: String) { ws.unsubscribePresence(userId) }

    func loadConversations() async {
        if let resp: ConversationsResponse = try? await APIClient.shared.request("conversations") {
            conversations = resp.conversations
            // снимок для запуска без сети: следующий старт покажет список сразу, не дожидаясь сервера
            ConversationCache.save(resp.conversations)
        }
    }
    
    // Открыть чат по тапу на уведомление. Собеседника ищем в списке бесед: на холодном старте там
    // может быть лишь снимок из кеша, и новой беседы в нём нет — тогда перечитываем список, а не
    // нашли и после этого — спрашиваем карточку отправителя (ник нужен шапке чата).
    func openChat(conversationId: String, senderUserId: String?) {
        Task {
            let find = { [weak self] in self?.conversations.first { $0.conversationId == conversationId }?.otherUser }
            if find() == nil { await loadConversations() }

            if let p = find() {
                pendingChatRoute = ChatRoute(userId: p.userId, username: p.username, conversationId: conversationId)
            } else if let sender = senderUserId, let card = try? await UserService().card(sender) {
                pendingChatRoute = ChatRoute(userId: card.userId, username: card.username, conversationId: conversationId)
            }
        }
    }

    func handleDeepLink(_ url: URL) {
        // Ссылка-мостик от волонтёра (приватный режим демона): ringly-bridge://<base64>.
        // Не ведёт ни в какой чат — только добавляет точку входа.
        if url.absoluteString.hasPrefix(BridgeLink.scheme) {
            // то же, что «Подключить» на экране «Обход блокировок»: добавить (если новый) и подключиться
            if let bridge = BridgeLink.parse(url.absoluteString) {
                EndpointResolver.shared.acceptBridgeLink(url.absoluteString)
                EndpointResolver.shared.connect(host: bridge.host, port: bridge.port)
            }
            return
        }

        // Холодный старт: инвайт-ссылка может нести живой мостик (?b=...) — забираем ДО резолва имени,
        // потому что сам резолв может не пройти при заблокированном прямом пути (relay-daemon.md §8).
        if let hint = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "b" })?.value {
            EndpointResolver.shared.acceptBridgeHint(hint)
        }

        // ждём .../u/<username> (Universal Link https://ringlyapp.net/u/<username> и схема ringly://u/<username>)
        let parts = url.path.split(separator: "/").map(String.init)
        guard let uIndex = parts.firstIndex(of: "u"), uIndex + 1 < parts.count else {
            // для ringly://u/<ник> username может быть в host
            if url.scheme == "ringly", url.host == "u",
               let username = url.path.split(separator: "/").first.map(String.init) {
                resolveAndOpen(username: username); return
            }
            return
        }
        resolveAndOpen(username: parts[uIndex + 1])
    }

    private func resolveAndOpen(username: String) {
        // Ещё не зарегистрированы — значит по этой ссылке нас и позвали. Запоминаем ник, чтобы
        // отправить его вместе с профилем в конце онбординга (InviteOrigin): резолв ниже требует
        // сети и авторизации, а ребро графа доверия записывается только один раз и позже
        // невосстановимо.
        if me?.onboardingState != .completed {
            InviteOrigin.remember(username)
        }

        Task {
            if let r = try? await UserService().findByUsername(username) {
                // своя же инвайт-ссылка (её открывают, чтобы проверить/поделиться) — чата с самим собой нет,
                // а открытый «чат с собой» становится тупиком без выхода. Просто игнорируем.
                guard r.userId != AuthState.myUserId else { return }
                pendingChatRoute = ChatRoute(userId: r.userId, username: r.username, conversationId: nil)
            }
        }
    }
}
