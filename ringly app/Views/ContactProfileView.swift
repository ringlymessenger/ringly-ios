import SwiftUI

// Профиль собеседника: большая аватарка, имя + статус, 4 действия (аудио/видео/чат/звук), @username.
// Открывается тапом по имени в шапке чата. Кнопки звонка перенесены сюда из чата.
struct ContactProfileView: View {
    let recipientUserId: String
    let recipientUsername: String
    let conversationId: String?

    @EnvironmentObject var viewModel: AppViewModel
    @ObservedObject private var contacts = ContactProfileCache.shared
    @ObservedObject private var presence = PresenceStore.shared
    @ObservedObject private var blockStore = BlockState.shared
    @ObservedObject private var muteStore = MuteState.shared
    @Environment(\.dismiss) private var dismiss

    @State private var confirmDelete = false
    @State private var showReport = false
    @State private var linkCopied = false
    @State private var renaming = false
    @State private var aliasDraft = ""

    private var displayName: String { contacts.byUser[recipientUserId]?.name ?? "@\(recipientUsername)" }

    private var screenW: CGFloat { UIScreen.main.bounds.width }
    // квадратная (по ширине экрана) шапка, но не выше ~55% экрана — чтобы действия всегда были видны
    private var headerHeight: CGFloat {
        let b = UIScreen.main.bounds
        return min(b.width, b.height * 0.55)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                actions
                infoCard
            }
            .frame(width: screenW)          // жёстко фиксируем ширину контента = ширине экрана
            .padding(.bottom, 24)
        }
        .background(AppColor.background.ignoresSafeArea())
        // Нативная панель навигации, а не своя кнопка «назад». Скрытая панель
        // (`navigationBarHidden`) отключала системный свайп от края экрана, и вернуться можно было
        // только кнопкой, которая к тому же выглядела не как системная. Фон панели прозрачный —
        // шапка с фото по-прежнему уходит под неё на всю высоту.
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu { moreMenuItems } label: { Image(systemName: "ellipsis") }
            }
        }
        .ignoresSafeArea(edges: .top)
        .onAppear {
            contacts.ensure(recipientUserId)
            contacts.ensureHighRes(recipientUserId)         // догрузить чёткую (large) аватарку для профиля
            viewModel.presenceSubscribe(recipientUserId)   // статус живой и на профиле (отписку оставляем чату)
        }
        .sheet(isPresented: $showReport) {
            ReportView(reportedUserId: recipientUserId, reportedUsername: recipientUsername,
                       conversationId: conversationId)
        }
        // Своё имя контакта — как «имя в контактах» у Telegram, только без телефонной книги:
        // хранится на этом устройстве, собеседник и сервер его не видят.
        .alert(L("Имя контакта"), isPresented: $renaming) {
            TextField(contacts.byUser[recipientUserId]?.realName ?? "@\(recipientUsername)", text: $aliasDraft)
            Button(L("Сохранить")) { saveAlias(aliasDraft) }
            if contacts.byUser[recipientUserId]?.alias != nil {
                Button(L("Сбросить"), role: .destructive) { saveAlias(nil) }
            }
            Button(L("Отмена"), role: .cancel) {}
        } message: {
            Text(L("Это имя видите только вы, на этом устройстве."))
        }
        .alert(L("Удалить контакт?"), isPresented: $confirmDelete) {
            Button(L("Удалить"), role: .destructive) { deleteContact() }
            Button(L("Отмена"), role: .cancel) {}
        } message: {
            Text(L("Переписка будет удалена у вас и у собеседника. Это нельзя отменить."))
        }
    }

    // ===== шапка: аватар на всю ширину + имя/статус снизу (назад и «…» — в нативной панели) =====
    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let img = contacts.byUser[recipientUserId]?.avatar {
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
                Text(displayName).font(.title).bold().foregroundStyle(.white)
                // задано своё имя — под ним настоящее, чтобы не забыть, кто это
                if let c = contacts.byUser[recipientUserId], c.alias != nil {
                    Text(c.realName ?? "@\(recipientUsername)").font(.subheadline).foregroundStyle(.white.opacity(0.7))
                }
                let status = PresenceFormatter.text(presence.states[recipientUserId])
                if !status.isEmpty {
                    Text(status).font(.subheadline)
                        .foregroundStyle(presence.states[recipientUserId]?.online == true ? .white : .white.opacity(0.7))
                }
            }
            .padding(20)
        }
    }

    // Меню «…» в правом углу панели навигации.
    @ViewBuilder private var moreMenuItems: some View {
        Button {
            aliasDraft = contacts.byUser[recipientUserId]?.alias ?? ""
            renaming = true
        } label: {
            Label(L("Изменить имя"), systemImage: "pencil")
        }
        if blockStore.isBlocked(recipientUserId) {
            Button { blockStore.setBlocked(recipientUserId, username: recipientUsername, false) } label: {
                Label(L("Разблокировать"), systemImage: "hand.raised.slash")
            }
        } else {
            Button(role: .destructive) { blockStore.setBlocked(recipientUserId, username: recipientUsername, true) } label: {
                Label(L("Заблокировать"), systemImage: "hand.raised")
            }
        }
        // Жалоба — требование App Store для приложений с пользовательским контентом
        // (Guideline 1.2). Отдельно от «Заблокировать»: блокировка молчит, жалоба
        // доходит до оператора.
        Button(role: .destructive) { showReport = true } label: {
            Label(L("Пожаловаться"), systemImage: "exclamationmark.bubble")
        }
        Button(role: .destructive) { confirmDelete = true } label: {
            Label(L("Удалить контакт"), systemImage: "trash")
        }
    }

    private func saveAlias(_ name: String?) {
        let trimmed = String((name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        contacts.setAlias(recipientUserId, trimmed.isEmpty ? nil : trimmed)
    }

    // ===== 4 действия =====
    private var actions: some View {
        HStack(spacing: 10) {
            actionButton("phone.fill", L("Аудио")) { startCall(video: false) }
            actionButton("video.fill", L("Видео")) { startCall(video: true) }
            actionButton("message.fill", L("Чат")) { dismiss() }
            actionButton(muteStore.isMuted(recipientUserId) ? "bell.slash.fill" : "bell.fill",
                         muteStore.isMuted(recipientUserId) ? L("Вкл. звук") : L("Без звука")) {
                muteStore.setMuted(recipientUserId, !muteStore.isMuted(recipientUserId))
            }
        }
        .padding(.horizontal, 16)
    }

    // ===== плашка @username: тап копирует ссылку-приглашение на этого пользователя =====
    private var infoCard: some View {
        Button(action: copyInviteLink) {
            VStack(alignment: .leading, spacing: 2) {
                Text(linkCopied ? L("Ссылка скопирована") : L("Имя пользователя"))
                    .font(.caption).foregroundStyle(.secondary)
                Text("@\(recipientUsername)").foregroundStyle(.blue)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(AppColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
    }

    // Ссылка ведёт на профиль СОБЕСЕДНИКА — ею делятся, чтобы порекомендовать человека,
    // а не себя. Собирается там же, где ссылка на себя (AppConfig), иначе два места разъедутся.
    private func copyInviteLink() {
        UIPasteboard.general.string = AppConfig.inviteLink(username: recipientUsername)
        withAnimation { linkCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { linkCopied = false }
        }
    }

    private func actionButton(_ icon: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption2)
            }
            .foregroundStyle(AppColor.text)
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background(AppColor.fill)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func startCall(video: Bool) {
        CallManager.shared.startCall(calleeUserId: recipientUserId, calleeName: displayName, video: video)
    }

    private func deleteContact() {
        guard let cid = conversationId else { dismiss(); return }   // беседы ещё не было — просто выходим
        Task {
            await viewModel.messaging.deleteContact(conversationId: cid, recipientUserId: recipientUserId)
            await viewModel.loadConversations()
            NotificationCenter.default.post(name: .conversationDeleted, object: nil)   // чат закроется сам
        }
    }
}
