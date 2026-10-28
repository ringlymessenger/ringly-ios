import SwiftUI

// Выбор языка интерфейса. Список с галочкой, как «Оформление»: по тумблеру не понять, какой
// вариант включён сейчас, а вариантов тут три.
struct LanguageView: View {
    @ObservedObject private var store = LanguageStore.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(AppLanguage.allCases.enumerated()), id: \.element.id) { idx, item in
                    Button { store.language = item } label: { row(item) }
                        .buttonStyle(.plain)

                    if idx < AppLanguage.allCases.count - 1 { Divider().overlay(AppColor.hairline) }
                }
            }
            .background(AppColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Text(L("Язык интерфейса. «Системный» следует настройкам телефона; если системный язык не русский, интерфейс будет английским."))
                .font(.caption).foregroundStyle(AppColor.subtext)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.top, 10)
        }
        .background(AppColor.background.ignoresSafeArea())
        .navigationTitle(L("Язык"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ item: AppLanguage) -> some View {
        HStack(spacing: 12) {
            Text(item.title).foregroundStyle(AppColor.text)
            Spacer()
            if store.language == item {
                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
            }
        }
        .padding(14)
        .contentShape(Rectangle())
    }
}
