import SwiftUI

// Личный профиль: аватар во всю ширину + имя/статус, кнопка выхода сверху,
// карточка с Имя/Фамилия/@username (тап по нику копирует инвайт-ссылку), Чёрный список и PIN-бэкап.
struct ProfileView: View {
    @EnvironmentObject var viewModel: AppViewModel
    @ObservedObject private var themeStore = ThemeStore.shared   // иконка строки «Оформление»
    @State private var confirmLogout = false
    @State private var showBackup = false
    @State private var linkCopied = false
    @State private var showEdit = false
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var deleteFailed = false
    @State private var savingCopy = false       // досохраняем копию в iCloud перед выходом
    @State private var saveCopyFailed = false

    private var screenW: CGFloat { UIScreen.main.bounds.width }
    private var headerHeight: CGFloat {
        let b = UIScreen.main.bounds
        return min(b.width, b.height * 0.55)
    }

    private var fullName: String? {
        guard let p = viewModel.profile else { return nil }
        let n = "\(p.firstName) \(p.lastName)".trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? nil : n
    }
    private var username: String? { viewModel.me?.username }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    infoCard
                    rows
                }
                .frame(width: screenW)
                .padding(.bottom, 24)
            }
            .background(AppColor.background.ignoresSafeArea())
            .navigationBarHidden(true)
            .ignoresSafeArea(edges: .top)
            .sheet(isPresented: $showBackup) {
                if viewModel.profileKeyMissing { KeyRecoveryView() } else { BackupPinView() }
            }
            .sheet(isPresented: $showEdit) { EditProfileView() }
            // Текст зависит от копии в iCloud: «потеряна навсегда» — неправда, если история там лежит
            .alert(L("Выйти из аккаунта?"), isPresented: $confirmLogout) {
                Button(ICloudBackup.shared.savedCopyDate == nil ? L("Выйти и удалить данные") : L("Выйти"),
                       role: .destructive) {
                    savingCopy = true
                    Task {
                        let ok = await viewModel.logoutSavingBackup()
                        savingCopy = false
                        if !ok { saveCopyFailed = true }   // при успехе экран уже сменился на вход
                    }
                }
                Button(L("Отмена"), role: .cancel) {}
            } message: {
                if ICloudBackup.shared.savedCopyDate != nil {
                    Text(L("Перед выходом копия в iCloud обновится, и переписка вернётся при следующем входе после ввода PIN-кода. С этого устройства история будет удалена."))
                } else {
                    Text(L("История чатов будет удалена с этого устройства. Если у вас нет других устройств с этой перепиской, она будет потеряна навсегда. PIN-бэкап сохраняет только ключ профиля, не историю."))
                }
            }
            .alert(L("Не удалось обновить копию в iCloud"), isPresented: $saveCopyFailed) {
                Button(L("Выйти всё равно"), role: .destructive) { viewModel.logout(wipeLocal: true) }
                Button(L("Отмена"), role: .cancel) {}
            } message: {
                Text(L("Сообщения новее последней копии (%@) будут потеряны. Можно проверить подключение и попробовать ещё раз.",
                       (ICloudBackup.shared.savedCopyDate ?? Date()).formatted(date: .abbreviated, time: .shortened)))
            }
            .alert(L("Удалить аккаунт?"), isPresented: $confirmDelete) {
                Button(L("Удалить навсегда"), role: .destructive) {
                    deleting = true
                    Task {
                        let ok = await viewModel.deleteAccount()
                        deleting = false
                        if !ok { deleteFailed = true }   // при успехе экран уже сменился на вход
                    }
                }
                Button(L("Отмена"), role: .cancel) {}
            } message: {
                Text(L("Это действие необратимо. Будут удалены ваш профиль, имя пользователя @%@, все устройства, ключи шифрования и переписки. Восстановить аккаунт и историю будет невозможно — даже с PIN-кодом.", username ?? ""))
            }
            .alert(L("Не удалось удалить аккаунт"), isPresented: $deleteFailed) {
                Button(L("Понятно"), role: .cancel) {}
            } message: {
                Text(L("Проверьте подключение к интернету и попробуйте ещё раз. Данные не изменились."))
            }
            .overlay {
                if deleting || savingCopy {
                    ZStack {
                        Color.black.opacity(0.6).ignoresSafeArea()
                        ProgressView(deleting ? L("Удаление аккаунта…") : L("Сохраняем переписку в iCloud…"))
                            .tint(.white).foregroundStyle(.white)
                    }
                }
            }
        }
    }

    // ===== шапка: аватар на всю ширину + имя/статус снизу + кнопка выхода сверху =====
    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let img = viewModel.avatarImage {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    Color.gray.opacity(0.3)
                        .overlay(Image(systemName: "person.fill").font(.system(size: 80)).foregroundStyle(AppColor.subtext))
                }
            }
            .frame(width: screenW, height: headerHeight)
            .clipped()

            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                .frame(width: screenW, height: headerHeight)

            VStack(alignment: .leading, spacing: 2) {
                // имя необязательно (онбординг его не требует) — без него заголовком служит ник
                Text(fullName ?? username.map { "@\($0)" } ?? L("Имя недоступно")).font(.title).bold().foregroundStyle(.white)
                Text(L("В сети")).font(.subheadline).foregroundStyle(.white.opacity(0.7))
            }
            .padding(20)

            // выход из аккаунта (слева) + редактирование профиля (справа)
            VStack {
                HStack {
                    Button { confirmLogout = true } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.headline).foregroundStyle(.white)
                            .frame(width: 36, height: 36).background(.black.opacity(0.35)).clipShape(Circle())
                    }
                    Spacer()
                    // без Profile Key имя/фамилия не расшифрованы — сохранение затёрло бы их пустыми
                    Button { showEdit = true } label: {
                        Image(systemName: "pencil")
                            .font(.headline).foregroundStyle(.white)
                            .frame(width: 36, height: 36).background(.black.opacity(0.35)).clipShape(Circle())
                    }
                    .disabled(viewModel.profileKeyMissing)
                    .opacity(viewModel.profileKeyMissing ? 0.4 : 1)
                }
                .padding(.horizontal, 16)
                .padding(.top, 56)
                Spacer()
            }
            .frame(height: headerHeight)
        }
    }

    // ===== карточка Имя / Фамилия / @username =====
    private var infoCard: some View {
        VStack(spacing: 0) {
            if let p = viewModel.profile {
                field(L("Имя"), p.firstName)
                Divider().overlay(AppColor.hairline)
                field(L("Фамилия"), p.lastName)
                Divider().overlay(AppColor.hairline)
            }
            // тап по нику → копирует инвайт-ссылку https://ringlyapp.net/u/<username>
            Button(action: copyInviteLink) {
                fieldContent(linkCopied ? L("Ссылка скопирована") : L("Имя пользователя"),
                             username.map { "@\($0)" } ?? "—", valueColor: .blue)
            }
            .buttonStyle(.plain)
            .disabled(username == nil)
        }
        .padding(.vertical, 4)
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
    }

    private func field(_ label: String, _ value: String) -> some View {
        fieldContent(label, value.isEmpty ? "—" : value, valueColor: AppColor.text)
    }
    private func fieldContent(_ label: String, _ value: String, valueColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(AppColor.subtext)
            Text(value).foregroundStyle(valueColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    // ===== строки: Чёрный список + PIN-бэкап =====
    private var rows: some View {
        VStack(spacing: 12) {
            // Rings скрыт, пока нет боевых ключей AppLovin: без рекламы валюту не заработать,
            // а нерабочая фича — повод для реджекта App Review (Guideline 2.1)
            if RewardedAdController.adsAvailable {
                NavigationLink { RingsView() } label: {
                    rowLabel("Rings", icon: "circle.hexagongrid.fill", chevron: true)
                }
                .buttonStyle(.plain)
            }

            NavigationLink { MediaStorageView() } label: {
                rowLabel(L("Медиа и хранилище"), icon: "photo.on.rectangle.angled", chevron: true)
            }
            .buttonStyle(.plain)

            NavigationLink { DevicesView() } label: {
                rowLabel(L("Устройства"), icon: "laptopcomputer.and.iphone", chevron: true)
            }
            .buttonStyle(.plain)

            NavigationLink { CallSettingsView() } label: {
                rowLabel(L("Звонки"), icon: "phone.fill", chevron: true)
            }
            .buttonStyle(.plain)

            NavigationLink { AppearanceView() } label: {
                rowLabel(L("Оформление"), icon: themeStore.theme.icon, chevron: true)
            }
            .buttonStyle(.plain)

            NavigationLink { LanguageView() } label: {
                rowLabel(L("Язык"), icon: "globe", chevron: true)
            }
            .buttonStyle(.plain)

            NavigationLink { BypassView() } label: {
                rowLabel(L("Обход блокировок"), icon: "shield.lefthalf.filled", chevron: true)
            }
            .buttonStyle(.plain)

            NavigationLink { ICloudBackupView() } label: {
                rowLabel(L("Копия в iCloud"), icon: "icloud.fill", chevron: true)
            }
            .buttonStyle(.plain)

            NavigationLink { PasscodeSettingsView() } label: {
                rowLabel(L("Код-пароль"), icon: "lock.shield.fill", chevron: true)
            }
            .buttonStyle(.plain)

            NavigationLink { BlockedUsersView() } label: {
                rowLabel(L("Чёрный список"), icon: "lock.fill", chevron: true)
            }
            .buttonStyle(.plain)

            Button { showBackup = true } label: {
                rowLabel(viewModel.profileKeyMissing ? L("Восстановить профиль (PIN)") : L("Резервная копия (PIN)"),
                         icon: "key.fill", chevron: true)
            }
            .buttonStyle(.plain)

            // необратимое удаление — отделено отступом и красным, чтобы не нажали случайно
            Button { confirmDelete = true } label: {
                rowLabel(L("Удалить аккаунт"), icon: "trash.fill", chevron: false, tint: .red)
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
        }
        .padding(.horizontal, 16)
    }

    private func rowLabel(_ title: String, icon: String, chevron: Bool, tint: Color = AppColor.text) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(tint == AppColor.text ? AppColor.subtext : tint).frame(width: 22)
            Text(title).foregroundStyle(tint)
            Spacer()
            if chevron { Image(systemName: "chevron.right").font(.footnote).foregroundStyle(AppColor.faint) }
        }
        .padding(14)
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func copyInviteLink() {
        guard let username else { return }
        UIPasteboard.general.string = AppConfig.inviteLink(username: username)
        withAnimation { linkCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { linkCopied = false }
        }
    }
}
