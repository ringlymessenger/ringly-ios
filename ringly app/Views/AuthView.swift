import SwiftUI
import AuthenticationServices   // для SignInWithAppleButton
import GoogleSignIn

// Экран входа. Всегда тёмный, независимо от выбранной темы: это брендовый момент, тот же чёрный,
// что у launch screen и splash — без него на старте была бы смена тона. Поэтому цвета здесь заданы
// явно, а не через палитру, и кнопка Apple жёстко белая (на чёрном чёрная кнопка исчезла бы).
struct AuthView: View {
    @EnvironmentObject var viewModel: AppViewModel

    private static let buttonRadius: CGFloat = 12
    private static let buttonHeight: CGFloat = 52

    // Вход в демо-аккаунт для App Review: 5 нажатий на «Ringly» открывают форму логина и пароля —
    // но только пока демо-вход включён на сервере (его включают на время ревью). Иначе нажатия
    // ничего не делают. Подробности — docs/app-review-demo.md.
    @State private var logoTaps = 0
    @State private var checkingDemo = false
    @State private var showDemoLogin = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Ringly")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .onTapGesture {
                    logoTaps += 1
                    guard logoTaps >= 5, !checkingDemo else { return }
                    logoTaps = 0
                    checkingDemo = true
                    Task {
                        showDemoLogin = await viewModel.demoLoginEnabled()
                        checkingDemo = false
                    }
                }

            Spacer()

            // во всю ширину, с уходом за края — так волна читается как бесконечная линия
            WaveBanner()
                .frame(height: 240)

            Spacer()

            Text(L("Безопасные звонки\nв любую точку мира"))
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)

            appleButton
            googleButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color.black.ignoresSafeArea())
        .sheet(isPresented: $showDemoLogin) {
            DemoLoginSheet { username, password in
                Task { await viewModel.signInDemo(username: username, password: password) }
            }
        }
        .alert(L("Ошибка входа"),
               isPresented: .constant(viewModel.errorMessage != nil),
               actions: {
                   Button("OK") { viewModel.errorMessage = nil }
               },
               message: {
                   Text(viewModel.errorMessage ?? "")
               })
    }

    // ===== кнопки провайдеров =====
    // Вид кнопок задают Apple и Google, а не наш макет: перекрашивать их и рисовать свои логотипы
    // нельзя. Из макета взята только формулировка «Продолжить через …» — у Apple для этого есть
    // штатный тип `.continue` (локализуется системой), у Google такой текст разрешён гайдлайном.

    private var appleButton: some View {
        SignInWithAppleButton(.continue) { request in
            // что просим у Apple. Имя нам не нужно — его юзер введёт в онбординге.
            request.requestedScopes = [.fullName, .email]   // имя — чтобы онбординг не спрашивал его заново (Guideline 4)
        } onCompletion: { result in
            handleApple(result)
        }
        .signInWithAppleButtonStyle(.white)   // на чёрном фоне чёрная кнопка исчезла бы
        .frame(height: Self.buttonHeight)
        .clipShape(RoundedRectangle(cornerRadius: Self.buttonRadius))
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    private var googleButton: some View {
        Button {
            Task { await handleGoogle() }
        } label: {
            HStack(spacing: 10) {
                // официальный ассет из брендбука Google; SVG в каталоге хранится с векторным
                // представлением, поэтому не мылится ни на каком масштабе
                Image("GoogleLogo")
                    .resizable().scaledToFit()
                    .frame(width: 20, height: 20)
                Text(L("Продолжить через Google"))
                    .font(.system(size: 17, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: Self.buttonHeight)
            .background(.white)
            .foregroundStyle(.black)
            .clipShape(RoundedRectangle(cornerRadius: Self.buttonRadius))
            .overlay(RoundedRectangle(cornerRadius: Self.buttonRadius).stroke(.gray.opacity(0.4)))
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }

    // разбираем ответ Apple
    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let idToken = String(data: tokenData, encoding: .utf8)
            else {
                print("Apple: не удалось достать identityToken")
                return
            }
            // Apple отдаёт имя только при ПЕРВОЙ авторизации — запоминаем его для онбординга.
            // Guideline 4: после входа через Apple нельзя заставлять вводить имя повторно.
            if let name = credential.fullName {
                AppleNameHint.save(first: name.givenName, last: name.familyName)
            }
            // отдаём токен во ViewModel — он дёрнет бэкенд (полностью в шаге 7)
            Task { await viewModel.signIn(provider: "apple", idToken: idToken) }

        case .failure(let error):
            // юзер отменил или ошибка — просто не двигаемся дальше
            print("Apple sign in error:", error.localizedDescription)
        }
    }
    
    @MainActor
    private func handleGoogle() async {
        guard let presenter = rootViewController() else { return }
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
            guard let idToken = result.user.idToken?.tokenString else {
                print("Google: нет idToken в ответе")
                return
            }
            await viewModel.signIn(provider: "google", idToken: idToken)
        } catch {
            // юзер закрыл окно или ошибка
            print("Google sign in error:", error.localizedDescription)
        }
    }
}

// Форма входа в демо-аккаунт. Только системные элементы: Form, поля и кнопки панели.
private struct DemoLoginSheet: View {
    let onSubmit: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""

    private var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("Логин"), text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(L("Пароль"), text: $password)
                        .textContentType(.password)
                        .onSubmit(submit)
                } footer: {
                    Text(L("Вход по паролю есть только у демо-аккаунта для проверки приложения."))
                }
            }
            .navigationTitle(L("Демо-аккаунт"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Отмена")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Войти"), action: submit).disabled(!canSubmit)
                }
            }
        }
    }

    // Ошибку покажет алерт экрана входа, поэтому форму закрываем сразу.
    private func submit() {
        guard canSubmit else { return }
        onSubmit(username.trimmingCharacters(in: .whitespaces), password)
        dismiss()
    }
}

// Имя из Sign in with Apple до онбординга. Apple присылает его один раз, поэтому храним локально,
// пока онбординг его не использует.
enum AppleNameHint {
    private static let key = "appleNameHint"

    static func save(first: String?, last: String?) {
        let f = first?.trimmingCharacters(in: .whitespaces) ?? "", l = last?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !f.isEmpty || !l.isEmpty else { return }
        UserDefaults.standard.set([f, l], forKey: key)
    }

    static func load() -> (first: String, last: String)? {
        guard let a = UserDefaults.standard.stringArray(forKey: key), a.count == 2 else { return nil }
        return (a[0], a[1])
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}
