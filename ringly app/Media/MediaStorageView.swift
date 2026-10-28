import SwiftUI

// Медиа и хранилище. Заложено сразу, а не «потом»: медиа — единственная часть приложения, которая
// растёт без ограничений, и без этого экрана пользователь узнаёт о проблеме из настроек iOS, когда
// приложение уже съело гигабайты.
struct MediaStorageView: View {
    @ObservedObject private var settings = MediaSettings.shared

    @State private var usedBytes: Int64 = 0
    @State private var confirmClear = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                usageCard
                autoDownloadCard
                clearButton
                explanation
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .background(AppColor.background.ignoresSafeArea())
        .navigationTitle(L("Медиа и хранилище"))
        .navigationBarTitleDisplayMode(.inline)
        .task { usedBytes = MediaStore.totalBytes() }
        .alert(L("Удалить все медиафайлы?"), isPresented: $confirmClear) {
            Button(L("Удалить"), role: .destructive) {
                MediaStore.wipe()
                usedBytes = 0
            }
            Button(L("Отмена"), role: .cancel) {}
        } message: {
            Text(L("Фото и видео будут удалены с этого устройства. Те, что ещё хранятся на сервере, можно будет скачать повторно; более старые восстановить не получится."))
        }
    }

    private var usageCard: some View {
        VStack(spacing: 4) {
            Text(ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file))
                .font(.system(size: 34, weight: .semibold)).foregroundStyle(AppColor.text)
            Text(L("занято медиафайлами")).font(.caption).foregroundStyle(AppColor.subtext)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var autoDownloadCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("Автозагрузка"))
                .font(.caption).foregroundStyle(AppColor.subtext)
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)

            ForEach(MediaSettings.Policy.allCases) { p in
                Button { settings.policy = p } label: {
                    HStack {
                        Text(p.title).foregroundStyle(AppColor.text)
                        Spacer()
                        if settings.policy == p {
                            Image(systemName: "checkmark").foregroundStyle(.blue)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Divider().overlay(AppColor.hairline)

            HStack {
                Text(L("Не больше")).foregroundStyle(AppColor.text)
                Spacer()
                Picker("", selection: $settings.limitMB) {
                    ForEach([2, 5, 10, 25], id: \.self) { Text("\($0) МБ").tag($0) }
                }
                .tint(.blue)
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
        }
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var clearButton: some View {
        Button { confirmClear = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "trash.fill").foregroundStyle(.red).frame(width: 22)
                Text(L("Очистить медиафайлы")).foregroundStyle(.red)
                Spacer()
            }
            .padding(14)
            .background(AppColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // Пользователь должен понимать, что удаление здесь — не очистка кеша, а потеря данных.
    private var explanation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Фото и видео зашифрованы и хранятся на этом устройстве. Сервер держит их временно — только пока сообщение не доставлено."))
            Text(L("Поэтому старые файлы, удалённые здесь, восстановить будет невозможно, а при потере устройства медиа не сохранится."))
        }
        .font(.caption)
        .foregroundStyle(AppColor.subtext)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
