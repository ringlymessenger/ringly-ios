import SwiftUI

// Список устройств аккаунта с возможностью отвязать (аналог «Linked Devices» у Signal).
//
// Помимо гигиены это делает проблему ВИДИМОЙ: пока мёртвая строка Device жива, все отправители
// обязаны шифровать и под неё, а проявляется это для пользователя как «сообщения не отправляются»,
// без единой подсказки о причине. См. docs/keys-consistency-incident.md
struct DevicesView: View {
    @EnvironmentObject var viewModel: AppViewModel

    @State private var devices: [DeviceItem] = []
    @State private var loading = true
    @State private var pendingUnlink: DeviceItem?
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if loading {
                    ProgressView().tint(AppColor.subtext).padding(.top, 40)
                } else if devices.isEmpty {
                    Text(L("Устройства не найдены")).foregroundStyle(AppColor.subtext).padding(.top, 40)
                } else {
                    ForEach(devices, id: \.id) { d in row(d) }
                }

                if let errorText {
                    Text(errorText).font(.footnote).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text(L("Если вы переустанавливали приложение или меняли телефон, здесь могут остаться старые записи. Отвяжите их — иначе сообщения продолжат шифроваться и для них."))
                    .font(.caption).foregroundStyle(AppColor.subtext)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .background(AppColor.background.ignoresSafeArea())
        .navigationTitle(L("Устройства"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .alert(L("Отвязать устройство?"), isPresented: .constant(pendingUnlink != nil)) {
            Button(L("Отвязать"), role: .destructive) {
                if let d = pendingUnlink { Task { await unlink(d) } }
                pendingUnlink = nil
            }
            Button(L("Отмена"), role: .cancel) { pendingUnlink = nil }
        } message: {
            Text(L("Это устройство перестанет получать сообщения и звонки. Если им ещё пользуются, придётся войти в аккаунт заново."))
        }
    }

    private func row(_ d: DeviceItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: d.platform == "ANDROID" ? "candybarphone" : "iphone")
                .foregroundStyle(AppColor.subtext).frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(d.deviceName ?? L("Устройство")).foregroundStyle(AppColor.text)
                    if d.isCurrent == true {
                        Text(L("это устройство"))
                            .font(.caption2).foregroundStyle(.blue)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.blue.opacity(0.15), in: Capsule())
                    }
                }
                Text(subtitle(d)).font(.caption).foregroundStyle(AppColor.subtext)
                // Дата добавления различает записи, когда всё остальное совпадает: с iOS 16
                // UIDevice.current.name отдаёт МОДЕЛЬ, поэтому у одного телефона все записи
                // называются одинаково («iPhone»), и без этой строки старую от новой не отличить.
                if let added = addedText(d) {
                    Text(added).font(.caption2).foregroundStyle(AppColor.faint)
                }
            }

            Spacer()

            // текущее устройство отвязать нельзя — для этого выход из аккаунта (он ещё и чистит локальные данные)
            if d.isCurrent != true {
                Button { pendingUnlink = d } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red.opacity(0.8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // «никогда не выходило на связь» — важный сигнал: почти наверняка след переустановки
    private func subtitle(_ d: DeviceItem) -> String {
        guard let raw = d.lastSeenAt, let last = Self.parseISO(raw) else {
            return L("Ни разу не выходило на связь")
        }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ru_RU")

        return "Активность: \(f.localizedString(for: last, relativeTo: Date()))"
    }

    private func addedText(_ d: DeviceItem) -> String? {
        guard let raw = d.createdAt, let date = Self.parseISO(raw) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM, HH:mm"

        return "Добавлено \(f.string(from: date))"
    }

    // сервер отдаёт ISO-8601 с долями секунды; парсим здесь, а не в модели (см. DeviceItem)
    private static func parseISO(_ s: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }

        return ISO8601DateFormatter().date(from: s)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        await viewModel.reloadMe()
        devices = viewModel.me?.devices ?? []
    }

    private func unlink(_ d: DeviceItem) async {
        errorText = nil
        do {
            struct UnlinkResponse: Decodable { let unlinked: Bool }
            let _: UnlinkResponse = try await APIClient.shared.request("me/devices/\(d.id)", method: "DELETE")
            await DeviceResolver.shared.invalidateAll()   // девайс-листы устарели → иначе 409 на отправке
            await load()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
