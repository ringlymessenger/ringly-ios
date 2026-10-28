import Foundation
import UIKit
import UserNotifications

// Регистрация push-токена на бэке + запрос разрешения на уведомления.
// Бэкенд шлёт пуши НАПРЯМУЮ через APNs (token-based .p8), поэтому на сервер уходит
// сырой APNs device token (hex) из didRegisterForRemoteNotificationsWithDeviceToken — без FCM SDK.
@MainActor
final class PushService {
    static let shared = PushService()

    private(set) var apnsToken: String?
    private var registeredToken: String?   // что уже успешно отправили на бэк (чтобы не дублировать)

    private(set) var voipToken: String?
    private var registeredVoip: String?
    var hasVoipToken: Bool { voipToken != nil }   // true только на реальном девайсе (PushKit) → путь CallKit

    // вызывается из AppDelegate при выдаче/обновлении APNs device token (hex-строка)
    func updateAPNsToken(_ token: String) {
        apnsToken = token
        Task { await registerIfPossible() }
    }

    // запрос разрешения на уведомления + регистрация в APNs (вызывать после логина/онбординга)
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    // POST /me/push-token — только если есть и APNs-токен, и авторизация на бэке
    func registerIfPossible() async {
        guard let apnsToken, TokenStore.shared.token != nil else { return }
        guard apnsToken != registeredToken else { return }     // не шлём один и тот же токен дважды
        do {
            let _: OkResponse = try await APIClient.shared.request(
                "me/push-token", method: "POST", body: PushTokenRequest(pushToken: apnsToken))
            registeredToken = apnsToken
        } catch {
            // best-effort: не получилось — попробуем при следующем foreground/refresh
        }
    }

    // ---- VoIP (PushKit) токен для звонков ----

    func updateVoipToken(_ token: String) {
        voipToken = token
        Task { await registerVoipIfPossible() }
    }

    func registerVoipIfPossible() async {
        guard let voipToken, TokenStore.shared.token != nil else { return }
        guard voipToken != registeredVoip else { return }
        do {
            let _: OkResponse = try await APIClient.shared.request(
                "me/voip-token", method: "POST", body: VoipTokenRequest(voipToken: voipToken))
            registeredVoip = voipToken
        } catch { /* best-effort */ }
    }

    // DELETE /me/push-token + /me/voip-token на логауте. Токен читаем синхронно ЗДЕСЬ.
    func clearOnLogout() {
        registeredToken = nil; registeredVoip = nil
        guard let token = TokenStore.shared.token else { return }
        for path in ["me/push-token", "me/voip-token"] {
            let url = AppConfig.apiBaseURL.appendingPathComponent(path)
            var req = URLRequest(url: url)
            req.httpMethod = "DELETE"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            URLSession.shared.dataTask(with: req).resume()   // best-effort
        }
    }
}
