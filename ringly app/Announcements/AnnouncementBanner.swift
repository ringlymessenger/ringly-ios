import SwiftUI

// Баннер объявления вверху списка чатов: имя, текст со ссылками и крестик «закрыть».
// Ссылки — разметкой [текст](https://…); открываются в браузере. Любая другая схема (не http/https)
// показывается обычным текстом — сервер такие и не пропускает, это вторая линия.
struct AnnouncementBanner: View {
    let announcement: Announcement
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "megaphone.fill")
                .font(.subheadline)
                .foregroundStyle(AppColor.brand)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(announcement.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColor.text)
                Text(Self.attributed(announcement.text))
                    .font(.subheadline)
                    .foregroundStyle(AppColor.subtext)
                    .tint(AppColor.brand)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppColor.faint)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)     // внутри List: иначе тап по строке нажимал бы крестик
            .accessibilityLabel(L("Закрыть"))
        }
        .padding(12)
        .background(AppColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AppColor.brand.opacity(0.25))
        }
    }

    // [текст](адрес) → ссылка; переносы строк сохраняются. Строчная разметка Markdown (**жирный**,
    // *курсив*) тоже сработает, если её написать руками, — админка её не предлагает.
    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var s = try? AttributedString(markdown: text, options: options) else { return AttributedString(text) }
        for run in s.runs {
            if let url = run.link, !["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                s[run.range].link = nil
            }
        }
        return s
    }
}
