import UIKit
import UserNotifications
import PushKit
import CallKit

// Имена нотификаций, через которые AppDelegate сообщает AppViewModel о пуш-будильниках.
extension Notification.Name {
    static let pushSyncRequested = Notification.Name("pushSyncRequested")   // profile_key_sync
    static let pushNewMessage    = Notification.Name("pushNewMessage")      // new_message
    static let callWake          = Notification.Name("callWake")            // VoIP-пуш → поднять WS
    static let conversationDeleted = Notification.Name("conversationDeleted") // «удалить контакт» → закрыть чат
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, PKPushRegistryDelegate {

    private let voipRegistry = PKPushRegistry(queue: .main)

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        ICloudBackup.registerBackgroundTask()   // регистрировать обязательно до конца запуска
        EndpointResolver.shared.log = { CallDiag.log($0) }   // мостики → журнал скрытого меню
        // VoIP/CallKit временно ОТКЛЮЧЕНЫ: входящий идёт через WS + внутренний экран (один источник правды,
        // без устаревших VoIP-пушей и десинхрона callId). CallKit вернём отдельной задачей, когда ядро стабильно.
        if Calls.useCallKit && Platform.supportsCallKit {
            voipRegistry.delegate = self
            voipRegistry.desiredPushTypes = [.voIP]
        }
        return true
    }

    // ---- PushKit (VoIP) ----
    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        let hex = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in PushService.shared.updateVoipToken(hex) }
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {}

    // VoIP-пуш входящего звонка → ОБЯЗАНЫ немедленно показать CallKit, иначе iOS убьёт приложение.
    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
                      for type: PKPushType, completion: @escaping () -> Void) {
        let p = payload.dictionaryPayload
        CallDiag.log("📲 VoIP push: callId=\((p["callId"] as? String)?.prefix(8) ?? "nil")")
        let media = (p["media"] as? String) ?? "audio"
        guard let callId = p["callId"] as? String,
              let callerUserId = p["callerUserId"] as? String,
              let callerDeviceId = p["callerDeviceId"] as? String,
              let conversationId = p["conversationId"] as? String,
              let uuid = UUID(uuidString: callId) else {
            // некорректный payload — всё равно обязаны отрепортить и тут же завершить
            let stub = UUID()
            CallProvider.shared.reportIncoming(uuid: stub, caller: "Звонок", hasVideo: false) {
                CallProvider.shared.reportEnded(uuid: stub, reason: .failed); completion()
            }
            return
        }
        let caller = ContactProfileStore.load(callerUserId)?.name ?? "Входящий звонок"
        CallProvider.shared.reportIncoming(uuid: uuid, caller: caller, hasVideo: media == "video") {
            Task { @MainActor in
                AppViewModel.shared.ensureReadyForCall()   // холодный старт: поднять сессию+WS ДО ответа
                CallManager.shared.prepareIncomingFromVoIP(
                    callId: callId, callerUserId: callerUserId, callerDeviceId: callerDeviceId,
                    conversationId: conversationId, media: media)
                completion()
            }
        }
    }

    // APNs device token получен → шлём его НА БЭК как есть (бэкенд шлёт прямо через APNs, без FCM).
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in PushService.shared.updateAPNsToken(hex) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // тихо: на симуляторе/без entitlement APNs может не подняться — пуши просто не приедут
    }

    // Фоновое пробуждение: content-free new_message (если пришло как silent) и silent profile_key_sync.
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        switch userInfo["type"] as? String {
        case "profile_key_sync":
            NotificationCenter.default.post(name: .pushSyncRequested, object: nil)
        case "new_message":
            NotificationCenter.default.post(name: .pushNewMessage, object: nil)
        default:
            break
        }
        completionHandler(.newData)
    }

    // Foreground-политика показа (Signal-style). Пуш при активном приложении — это всегда гонка
    // (протухший presence, пуш-фолбэк, зомби-сокет): само сообщение приложение уже получило/получит
    // по WS/поллингу. Поэтому:
    //  - баннер про ОТКРЫТЫЙ чат гасим — сообщение уже на экране (conversationId проставляет NSE);
    //  - неатрибутированный new_message (NSE не нашёл ничего нового — доставку уже обработало
    //    приложение, типичный ложный фолбэк-пуш) при активном приложении тоже гасим;
    //  - баннеры про ДРУГИЕ чаты показываем как раньше.
    // При закрытом/фоновом приложении willPresent не вызывается — там всё показывается как обычно.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let info = notification.request.content.userInfo
        if info["type"] as? String == "new_message" {
            let convId = info["conversationId"] as? String
            if convId == nil || convId == CurrentChat.shared.openConversationId {
                completionHandler([])
                return
            }
        }
        completionHandler([.banner, .sound])
    }

    // Тап по уведомлению → сразу в тот чат, откуда оно пришло (conversationId проставляет NSE).
    // Неатрибутированный generic-пуш («New message», NSE не успел расшифровать) чата не знает —
    // для него остаётся просто открытие приложения.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let conversationId = info["conversationId"] as? String {
            let sender = info["senderUserId"] as? String
            Task { @MainActor in AppViewModel.shared.openChat(conversationId: conversationId, senderUserId: sender) }
        }
        completionHandler()
    }
}
