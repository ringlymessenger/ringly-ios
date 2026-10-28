import SwiftUI
import PhotosUI

// Редактирование своего профиля: аватар, имя, фамилия, никнейм.
// Имя/фамилия едут в encryptedProfile (E2EE — сервер их не видит), аватар шифруется Profile Key'ом
// перед загрузкой, ник — единственное плейнтекст-поле (по нему ищут и работают инвайт-ссылки).
// Сохранение — один PUT /me через ProfileService.saveProfile (тот же путь, что в онбординге).
struct EditProfileView: View {
    @EnvironmentObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    private let profileService = ProfileService()

    @State private var firstName = ""
    @State private var lastName = ""
    @State private var username = ""

    @State private var selectedPhoto: PhotosPickerItem? = nil
    @State private var avatarImage: UIImage? = nil       // текущий или только что выбранный
    @State private var avatarChanged = false             // перезаливаем блобы ТОЛЬКО если фото трогали

    @State private var saving = false
    @State private var errorText: String? = nil
    @State private var loadedInitial = false             // префилл делаем один раз, чтобы не затирать ввод

    // ник по правилам сервера: 3–32, [a-z0-9_] (та же валидация, что в онбординге)
    private var usernameValid: Bool {
        username.range(of: "^[a-z0-9_]{3,32}$", options: .regularExpression) != nil
    }

    private var trimmedFirst: String { firstName.trimmingCharacters(in: .whitespaces) }
    private var trimmedLast: String { lastName.trimmingCharacters(in: .whitespaces) }

    private var hasChanges: Bool {
        avatarChanged
            || trimmedFirst != (viewModel.profile?.firstName ?? "")
            || trimmedLast != (viewModel.profile?.lastName ?? "")
            || username != (viewModel.me?.username ?? "")
    }

    private var canSave: Bool {
        !saving && hasChanges && usernameValid && !trimmedFirst.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    avatarPicker
                    fields
                    if let errorText {
                        Text(errorText)
                            .font(.footnote).foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                    }
                    hints
                }
                .padding(.vertical, 20)
            }
            .background(AppColor.background.ignoresSafeArea())
            .navigationTitle(L("Изменить профиль"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Отмена")) { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button(L("Готово")) { Task { await save() } }.disabled(!canSave)
                    }
                }
            }
            .onAppear(perform: prefill)
            .onChange(of: selectedPhoto) { _ in
                Task {
                    guard let data = try? await selectedPhoto?.loadTransferable(type: Data.self),
                          let ui = UIImage(data: data) else { return }
                    avatarImage = ui
                    avatarChanged = true
                }
            }
        }
    }

    // ===== аватар =====
    private var avatarPicker: some View {
        VStack(spacing: 10) {
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if let img = avatarImage {
                            Image(uiImage: img).resizable().scaledToFill()
                        } else {
                            Color.gray.opacity(0.3)
                                .overlay(Image(systemName: "person.fill")
                                    .font(.system(size: 44)).foregroundStyle(AppColor.subtext))
                        }
                    }
                    .frame(width: 120, height: 120)
                    .clipShape(Circle())

                    Image(systemName: "camera.fill")
                        .font(.footnote).foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.blue).clipShape(Circle())
                        .overlay(Circle().stroke(AppColor.background, lineWidth: 2))
                }
            }
            .disabled(saving)

            Text(L("Фото шифруется на устройстве")).font(.caption2).foregroundStyle(AppColor.subtext)
        }
    }

    // ===== поля =====
    private var fields: some View {
        VStack(spacing: 0) {
            labeledField(L("Имя"), text: $firstName)
            Divider().overlay(AppColor.hairline)
            labeledField(L("Фамилия"), text: $lastName)
            Divider().overlay(AppColor.hairline)
            labeledField(L("Имя пользователя"), text: $username, lowercased: true)
        }
        .padding(.vertical, 4)
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
    }

    private func labeledField(_ label: String, text: Binding<String>, lowercased: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(AppColor.subtext)
            TextField("", text: text)
                .foregroundStyle(AppColor.text)
                .textInputAutocapitalization(lowercased ? .never : .words)
                .autocorrectionDisabled(lowercased)
                .disabled(saving)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var hints: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !username.isEmpty && !usernameValid {
                Text(L("Имя пользователя: 3–32 символа, латиница, цифры и _"))
                    .font(.caption).foregroundStyle(.red)
            }
            Text(L("Имя и фамилия зашифрованы — сервер их не видит. Имя пользователя видно всем: по нему вас находят и работает ссылка-приглашение."))
                .font(.caption).foregroundStyle(AppColor.subtext)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
    }

    // ===== логика =====

    private func prefill() {
        guard !loadedInitial else { return }
        loadedInitial = true
        firstName = viewModel.profile?.firstName ?? ""
        lastName = viewModel.profile?.lastName ?? ""
        username = viewModel.me?.username ?? ""
        avatarImage = viewModel.avatarImage
    }

    private func save() async {
        saving = true
        errorText = nil
        defer { saving = false }

        do {
            // аватар не трогали → переиспользуем уже загруженные блобы (не тратим трафик и не плодим
            // осиротевшие вложения). Трогали → заливаем 3 новых размера, старые сервер подчистит сам.
            var avatarIds = viewModel.me?.avatarAttachmentIds ?? []
            if avatarChanged, let img = avatarImage {
                avatarIds = try await profileService.uploadAvatar(img)
            }

            try await profileService.saveProfile(
                firstName: trimmedFirst,
                lastName: trimmedLast,
                username: username,
                avatarIds: avatarIds
            )
            await viewModel.reloadMe()
            dismiss()
        } catch {
            errorText = message(for: error)
        }
    }

    // серверные ошибки → человеческий текст (сервер отвечает англоязычным AppError)
    private func message(for error: Error) -> String {
        if case APIError.server(let msg) = error {
            if msg.localizedCaseInsensitiveContains("already taken") {
                return "Имя пользователя @\(username) уже занято — выберите другое."
            }
            return msg
        }
        if case APIError.http(let code) = error, code == 429 {
            return L("Слишком часто. Подождите минуту и попробуйте снова.")
        }
        return error.localizedDescription
    }
}
