import SwiftUI
import PhotosUI

// Онбординг после первого входа: базовые данные → аватар. Два шага, а не одна длинная форма:
// аватар необязателен, и на отдельном экране это видно, а не теряется среди обязательных полей.
struct OnboardingView: View {
    @EnvironmentObject var viewModel: AppViewModel

    private let profileService = ProfileService()

    // общий стейт обоих под-шагов
    @State private var step = 1
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var username = ""

    @State private var selectedPhoto: PhotosPickerItem? = nil
    @State private var avatarUIImage: UIImage? = nil
    @State private var isSubmitting = false

    private enum Field { case first, last, username }
    @FocusState private var focused: Field?

    var body: some View {
        VStack(spacing: 0) {
            if step == 1 { profileStep } else { avatarStep }
        }
        // имя из Sign in with Apple — уже заполнено, пользователь вводит только ник
        .onAppear {
            if firstName.isEmpty, lastName.isEmpty, let hint = AppleNameHint.load() {
                firstName = hint.first
                lastName = hint.last
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Клавиатура убирается тапом по пустому месту. Жест висит на ФОНОВОМ слое, а не на корне:
        // `.simultaneousGesture` на корне срабатывает ОДНОВРЕМЕННО с тапом по полю и может снять
        // фокус сразу после того, как поле его получило (в ленте чата тот же приём безопасен —
        // там под жестом нет полей ввода).
        .background(
            AppColor.background
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { focused = nil }
        )
        .alert(L("Не получилось"),
               isPresented: .constant(viewModel.errorMessage != nil),
               actions: { Button("OK") { viewModel.errorMessage = nil } },
               message: { Text(viewModel.errorMessage ?? "") })
    }

    // ===== общие блоки =====

    private func header(_ subtitle: String) -> some View {
        VStack(spacing: 8) {
            Text(L("Создание аккаунта"))
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(AppColor.text)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(AppColor.subtext)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 28)
    }

    // Главная кнопка шага. Неактивная не прячется, а гаснет: исчезающая кнопка оставляет
    // пользователя гадать, куда делся переход, — а так видно, что он есть, но чего-то не хватает.
    private func primaryButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isSubmitting {
                    ProgressView().tint(.white)
                } else {
                    Text(title).font(.system(size: 17, weight: .semibold))
                    Image(systemName: "arrow.right").font(.system(size: 15, weight: .semibold))
                }
            }
            .foregroundStyle(.white)                      // на фиолетовой заливке — в любой теме
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(AppColor.brand.opacity(enabled ? 1 : 0.35),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled || isSubmitting)
        .animation(.easeInOut(duration: 0.15), value: enabled)
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    // ===== ШАГ 1: имя / фамилия / ник =====

    private var profileStep: some View {
        VStack(spacing: 0) {
            header(L("Укажите свои базовые данные, чтобы вашим друзьям было удобно вас найти"))

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field(L("Имя"), placeholder: L("Имя"), text: $firstName, field: .first)
                    field(L("Фамилия"), placeholder: L("Фамилия"), text: $lastName, field: .last)
                    field(L("Никнейм"), placeholder: L("Никнейм"), text: $username, field: .username,
                          lowercased: true)

                    // Подсказку по нику показываем только когда что-то введено: пустое поле не
                    // ошибка, и красный текст на старте выглядел бы как претензия ни за что.
                    if !username.isEmpty && !usernameValid {
                        Text(L("Никнейм: 3–32 символа, латиница, цифры и _"))
                            .font(.caption).foregroundStyle(.red)
                            .padding(.top, -10)
                    }

                    // Пустая зона под полями — явно тапабельная: фоновый слой сюда не достаёт, а именно
                    // здесь пользователь и тыкает, чтобы убрать клавиатуру.
                    //
                    // ⚠️ Она ВНУТРИ скролла, а не рядом с ним. Снаружи, с `frame(maxHeight: .infinity)`,
                    // получались ДВА растягивающихся соседа в одном VStack: с поднятой клавиатурой
                    // SwiftUI делил между ними остаток высоты, скролл сжимался (верхнее поле уезжало
                    // за край), а на освободившемся месте зияла чёрная полоса над кнопкой.
                    Color.clear
                        .frame(height: 180)
                        .contentShape(Rectangle())
                        .onTapGesture { focused = nil }
                }
                .padding(.horizontal, 24)
            }
            .scrollDismissesKeyboard(.interactively)

            primaryButton(L("Далее"), enabled: canContinue) {
                focused = nil
                step = 2
            }
        }
    }

    private func field(_ label: String, placeholder: String, text: Binding<String>,
                       field: Field, lowercased: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 15, weight: .semibold)).foregroundStyle(AppColor.text)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .focused($focused, equals: field)
                .foregroundStyle(AppColor.text)
                .tint(AppColor.brand)
                .textInputAutocapitalization(lowercased ? .never : .words)
                .autocorrectionDisabled(lowercased)
                .padding(.horizontal, 16)
                .frame(height: 56)
                .background(AppColor.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                // активное поле обводится фирменным — единственный индикатор фокуса,
                // потому что заливка у всех полей одинаковая
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(focused == field ? AppColor.brand : .clear, lineWidth: 1.5))
                .animation(.easeInOut(duration: 0.15), value: focused)
        }
    }

    // ник по правилам сервера: 3–32, [a-z0-9_]
    private var usernameValid: Bool {
        username.range(of: "^[a-z0-9_]{3,32}$", options: .regularExpression) != nil
    }

    // Имя необязательно (Guideline 4: после входа через Apple нельзя требовать имя). Без имени
    // собеседники видят @ник.
    private var canContinue: Bool {
        usernameValid
    }

    // ===== ШАГ 2: аватар (необязательный) =====

    private var avatarStep: some View {
        VStack(spacing: 0) {
            // Возврат к полям. В макете его нет, но без него опечатку в нике уже не исправить —
            // а ник уникален и меняется потом только через отдельный экран.
            HStack {
                Button { step = 1 } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AppColor.subtext)
                        .frame(width: 44, height: 44, alignment: .leading)
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting)
                Spacer()
            }
            .padding(.horizontal, 16)

            header(L("Вы можете загрузить свою аватарку, шаг не обязательный"))

            avatarPicker

            Spacer(minLength: 0)
            primaryButton(L("Готово"), enabled: true) { Task { await submit() } }
        }
        .onChange(of: selectedPhoto) {
            Task {
                if let data = try? await selectedPhoto?.loadTransferable(type: Data.self),
                   let ui = UIImage(data: data) {
                    avatarUIImage = ui
                }
            }
        }
    }

    private var avatarPicker: some View {
        VStack(spacing: 20) {
            // тапабельно и само кольцо, и кнопка под ним: в круг целиться привычнее
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Group {
                    if let img = avatarUIImage {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        AppColor.fill
                            .overlay(Image(systemName: "camera.fill")
                                .font(.system(size: 44))
                                .foregroundStyle(AppColor.subtext))
                    }
                }
                .frame(width: 220, height: 220)
                .clipShape(Circle())
                .overlay(Circle().stroke(AppColor.stroke, lineWidth: 1))
            }
            .disabled(isSubmitting)

            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Text(avatarUIImage == nil ? L("Добавить") : L("Изменить"))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(AppColor.text)
                    .padding(.horizontal, 22).padding(.vertical, 11)
                    .background(AppColor.fill, in: Capsule())
            }
            .disabled(isSubmitting)
        }
    }

    // финальная отправка
    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            var avatarIds: [String] = []
            if let img = avatarUIImage {
                avatarIds = try await profileService.uploadAvatar(img)
            }
            try await profileService.saveProfile(
                firstName: firstName, lastName: lastName,
                username: username, avatarIds: avatarIds,
                invitedByUsername: InviteOrigin.pending
            )
            // гасим только после успеха: на ошибке сети пользователь нажмёт «ещё раз», и ник
            // пригласившего должен дожить до повторной попытки
            InviteOrigin.clear()
            await viewModel.finishOnboarding()       // → Home
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }
}
