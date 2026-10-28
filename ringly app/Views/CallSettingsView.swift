import SwiftUI

// Настройки звонков. Пока единственная — маршрут медиа (напрямую или через сервер).
struct CallSettingsView: View {
    @State private var relayOnly = CallSettings.relayOnly

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                toggleCard
                explanation
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .background(AppColor.background.ignoresSafeArea())
        .navigationTitle(L("Звонки"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var toggleCard: some View {
        Toggle(isOn: $relayOnly) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(AppColor.subtext).frame(width: 22)
                Text(L("Звонить через сервер")).foregroundStyle(AppColor.text)
            }
        }
        .tint(.blue)
        .padding(14)
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onChange(of: relayOnly) { newValue in
            CallSettings.relayOnly = newValue
        }
    }

    // Формулировки выверены намеренно: тумблер прячет НАШ адрес от собеседника, но не наоборот —
    // обещать «анонимность» здесь было бы враньём. Последний абзац обязателен: без него
    // «через сервер» читается как «сервер слушает», и настройка начинает пугать вместо помощи.
    private var explanation: some View {
        VStack(alignment: .leading, spacing: 12) {
            paragraph(L("Обычно звонок идёт напрямую между устройствами — это быстрее и не нагружает сервер, но собеседник видит ваш IP-адрес."))
            paragraph(L("Если включить, звонки пойдут через сервер Ringly. Собеседник не увидит ваш IP-адрес. Задержка может немного вырасти."))
            paragraph(L("Содержимое звонка зашифровано в обоих случаях — сервер не может его слышать."))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(AppColor.subtext)
            .fixedSize(horizontal: false, vertical: true)
    }
}
