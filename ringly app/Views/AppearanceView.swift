import SwiftUI

// Выбор оформления. Список с галочкой, а не тумблер «Светлая тема»: тумблер называет одну из двух
// тем, и по нему не понять, какая сейчас включена, если пользователь не помнит исходное состояние.
struct AppearanceView: View {
    @ObservedObject private var themeStore = ThemeStore.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(AppTheme.allCases.enumerated()), id: \.element.id) { idx, theme in
                    Button {
                        // Без анимации: перекраска всего окна вместе с навигацией и таб-баром
                        // средствами SwiftUI не анимируется целиком, и попытка выглядит как рывок.
                        themeStore.theme = theme
                    } label: {
                        row(theme)
                    }
                    .buttonStyle(.plain)

                    if idx < AppTheme.allCases.count - 1 { Divider().overlay(AppColor.hairline) }
                }
            }
            .background(AppColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Text(L("Тёмная тема включена по умолчанию. Выбор сохраняется только на этом устройстве."))
                .font(.caption).foregroundStyle(AppColor.subtext)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.top, 10)
        }
        .background(AppColor.background.ignoresSafeArea())
        .navigationTitle(L("Оформление"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ theme: AppTheme) -> some View {
        HStack(spacing: 12) {
            Image(systemName: theme.icon).foregroundStyle(AppColor.subtext).frame(width: 22)
            Text(theme.title).foregroundStyle(AppColor.text)
            Spacer()
            if themeStore.theme == theme {
                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
            }
        }
        .padding(14)
        .contentShape(Rectangle())      // тап по всей строке, а не только по тексту
    }
}
