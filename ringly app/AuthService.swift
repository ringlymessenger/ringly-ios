import Foundation
import UIKit   // нужен для UIDevice.current.name

final class AuthService {

    // Вход/регистрация: SDK Google/Apple дал idToken → шлём на бэкенд.
    // Возвращаем OAuthResponse, чтобы ViewModel решил, куда роутить (онбординг или home).
    func oauth(provider: String, idToken: String) async throws -> OAuthResponse {
        let body = OAuthRequest(provider: provider, idToken: idToken, device: await deviceInfo())
        return try await login("auth/oauth", body: body)
    }

    // Демо-аккаунт для App Review: логин и пароль — только у него (docs/app-review-demo.md)
    func demoLogin(username: String, password: String) async throws -> OAuthResponse {
        let body = DemoLoginRequest(username: username, password: password, device: await deviceInfo())
        return try await login("auth/demo", body: body)
    }

    // Открыт ли демо-вход сейчас. Любая ошибка — «нет»: форма без работающего входа бесполезна.
    func demoLoginEnabled() async -> Bool {
        let status: DemoStatus? = try? await APIClient.shared.request("auth/demo", authorized: false)
        return status?.enabled ?? false
    }

    private func deviceInfo() async -> OAuthRequest.DeviceInfo {
        .init(
            platform: "IOS",
            deviceName: await UIDevice.current.name,   // напр. "iPhone"
            registrationId: DeviceIdentity.registrationId,
            protocolDeviceId: DeviceIdentity.protocolDeviceId
        )
    }

    private func login<Body: Encodable>(_ path: String, body: Body) async throws -> OAuthResponse {
        // authorized: false — токена ещё нет, эндпоинт без гарда (раздел 3 дока)
        let res: OAuthResponse = try await APIClient.shared.request(
            path,
            method: "POST",
            body: body,
            authorized: false
        )

        // сохраняем device-токен — дальше им подписываются ВСЕ запросы
        TokenStore.shared.save(res.token)
        return res
    }

    // Текущий пользователь — для бутстрапа на сплеше и для Home.
    func fetchMe() async throws -> MeResponse {
        try await APIClient.shared.request("me")   // GET + authorized по умолчанию
    }

    func logout() {
        TokenStore.shared.clear()
    }
}
