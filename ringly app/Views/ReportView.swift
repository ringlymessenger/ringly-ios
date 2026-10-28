import SwiftUI

// Жалоба на собеседника. Открывается из профиля контакта.
//
// Отправленная жалоба ВСЕГДА блокирует того, на кого жалуются: разбор на стороне оператора занимает
// время, а пострадавшему помощь нужна сейчас. Блокировка у нас локальная, так что это бесплатно и
// работает мгновенно — даже если жалобу никто не откроет.
struct ReportView: View {
    let reportedUserId: String
    let reportedUsername: String
    let conversationId: String?

    @Environment(\.dismiss) private var dismiss

    @State private var reason: ReportReason = .spam
    @State private var comment = ""
    @State private var attachMessages = true
    @State private var sending = false
    @State private var error: String?

    private let service = ReportService()

    // сколько сообщений реально приложится — показываем число, а не абстрактное «последние»
    private var evidenceCount: Int {
        guard let cid = conversationId else { return 0 }
        return ReportService.lastMessages(conversationId: cid, myUserId: AuthState.myUserId).count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    reasons
                    commentField
                    if evidenceCount > 0 { evidenceToggle }
                    note
                }
                .padding(16)
            }
            .background(AppColor.background.ignoresSafeArea())
            .navigationTitle(L("Пожаловаться"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L("Отмена")) { dismiss() }.disabled(sending)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("Отправить")) { Task { await send() } }
                        .bold()
                        .disabled(sending)
                }
            }
            .alert(L("Не удалось отправить"), isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
    }

    private var reasons: some View {
        VStack(spacing: 0) {
            ForEach(Array(ReportReason.allCases.enumerated()), id: \.element.id) { idx, item in
                Button { reason = item } label: {
                    HStack {
                        Text(item.title).foregroundStyle(AppColor.text)
                        Spacer()
                        if reason == item {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if idx < ReportReason.allCases.count - 1 { Divider().overlay(AppColor.hairline) }
            }
        }
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var commentField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Что произошло (необязательно)"))
                .font(.caption).foregroundStyle(AppColor.subtext)
            TextField(L("Опишите ситуацию"), text: $comment, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(3...6)
                .foregroundStyle(AppColor.text)
                .padding(12)
                .background(AppColor.fill, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var evidenceToggle: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $attachMessages) {
                Text(L("Приложить последние %@", Plural.messages(evidenceCount))).foregroundStyle(AppColor.text)
            }
            .padding(14)
            .background(AppColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // Здесь пользователь единственный раз в приложении осознанно снимает шифрование с куска
            // переписки — формулировка обязана быть прямой, без «мы заботимся о вашей приватности».
            // Про медиа сказано явно: молчание читалось бы как «фото тоже уйдут».
            Text(L("Переписка зашифрована, и сервер её не видит. Эти сообщения будут отправлены в открытом виде — только они, только по вашему выбору. Фото и видео не прикладываются."))
                .font(.caption).foregroundStyle(AppColor.subtext)
        }
    }

    private var note: some View {
        Text("Пользователь @\(reportedUsername) будет заблокирован: он не сможет писать и звонить вам. Разблокировать можно в профиле.")
            .font(.caption).foregroundStyle(AppColor.subtext)
    }

    private func send() async {
        sending = true
        defer { sending = false }

        let evidence: [ReportEvidenceMessage]? = {
            guard attachMessages, let cid = conversationId else { return nil }
            let list = ReportService.lastMessages(conversationId: cid, myUserId: AuthState.myUserId)

            return list.isEmpty ? nil : list
        }()

        do {
            try await service.send(reportedUserId: reportedUserId, reason: reason,
                                   comment: comment, evidence: evidence)
            // Блокируем ПОСЛЕ успешной отправки: иначе при сетевой ошибке пользователь остался бы
            // с заблокированным контактом и без поданной жалобы, не понимая, что именно случилось.
            BlockState.shared.setBlocked(reportedUserId, username: reportedUsername, true)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
