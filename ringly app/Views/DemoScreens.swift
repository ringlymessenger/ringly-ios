#if DEBUG
import SwiftUI
import GRDB

// Стенд скриншотов для App Store (аргумент запуска `-demoScreens`): настоящие экраны приложения с
// вымышленными контактами и перепиской, без сети и аккаунта. Все имена выдуманы, аватары нарисованы
// здесь же — на скриншотах магазина не должно быть реальных людей.
struct DemoScreens: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        TabView {
            ChatListView()
                .tabItem { Label(L("Чаты"), systemImage: "message.fill") }
            Color.clear
                .tabItem { Label(L("Профиль"), systemImage: "person.fill") }
        }
        .modifier(CallPresentation())
        .onAppear {
            Self.seed()
            viewModel.conversations = Self.people.map {
                ConversationItem(conversationId: "demo-\($0.id)", otherUser: OtherUser(userId: $0.id, username: $0.username),
                                 lastMessageAt: nil)
            }
            viewModel.debugMarkOnline()
            RingsBalanceStore.shared.set(1250)   // на скриншоте «0» на пилюле выглядел бы грустно
            for p in Self.people where p.online { PresenceStore.shared.apply(userId: p.id, online: true, lastSeenAt: nil) }
        }
    }

    struct Person { let id, name, username: String; let colors: [UIColor]; let online: Bool }

    // Английский комплект скриншотов (`-AppleLanguages (en)`) — свои имена и переписка, иначе на
    // английской странице магазина висели бы «Анна Соколова» и русский текст.
    static var en: Bool { Localization.resolved == .en }
    private static func t(_ ru: String, _ en: String) -> String { Self.en ? en : ru }

    static var people: [Person] { en ? peopleEN : peopleRU }

    private static let peopleEN: [Person] = [
        Person(id: "anna", name: "Anna Collins", username: "anna_c", colors: [.systemPink, .systemOrange], online: true),
        Person(id: "mom", name: "Mom", username: "linda_c", colors: [.systemPurple, .systemIndigo], online: false),
        Person(id: "dmitry", name: "Daniel Brooks", username: "dbrooks", colors: [.systemTeal, .systemBlue], online: true),
        Person(id: "elena", name: "Emily Carter", username: "emily_c", colors: [.systemGreen, .systemTeal], online: false),
        Person(id: "maxim", name: "Max Turner", username: "maxt", colors: [.systemOrange, .systemRed], online: false),
        Person(id: "ilya", name: "Ethan Ward", username: "eward", colors: [.systemBlue, .systemIndigo], online: false),
        Person(id: "olga", name: "Olivia Hayes", username: "olivia_h", colors: [.systemYellow, .systemOrange], online: false),
        Person(id: "sergey", name: "Sam Foster", username: "sfoster", colors: [.systemIndigo, .systemPurple], online: false),
    ]

    private static let peopleRU: [Person] = [
        Person(id: "anna", name: "Анна Соколова", username: "anna_s", colors: [.systemPink, .systemOrange], online: true),
        Person(id: "mom", name: "Мама", username: "irina_v", colors: [.systemPurple, .systemIndigo], online: false),
        Person(id: "dmitry", name: "Дмитрий Орлов", username: "orlov", colors: [.systemTeal, .systemBlue], online: true),
        Person(id: "elena", name: "Елена Кузнецова", username: "lena_k", colors: [.systemGreen, .systemTeal], online: false),
        Person(id: "maxim", name: "Максим Петров", username: "maxp", colors: [.systemOrange, .systemRed], online: false),
        Person(id: "ilya", name: "Илья Новиков", username: "novikov", colors: [.systemBlue, .systemIndigo], online: false),
        Person(id: "olga", name: "Ольга Морозова", username: "olga_m", colors: [.systemYellow, .systemOrange], online: false),
        Person(id: "sergey", name: "Сергей Волков", username: "volkov", colors: [.systemIndigo, .systemPurple], online: false),
    ]

    // Градиентный круг с инициалами — вместо фотографий реальных людей
    static func avatarPNG(for name: String) -> Data? {
        let colors = people.first { $0.name == name }?.colors ?? [.systemTeal, .systemBlue]
        let size = CGSize(width: 512, height: 512)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: colors.map(\.cgColor) as CFArray, locations: [0, 1])!
            ctx.cgContext.drawLinearGradient(g, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 200, weight: .semibold),
                                                        .foregroundColor: UIColor.white]
            let t = initials as NSString
            let ts = t.size(withAttributes: attrs)
            t.draw(at: CGPoint(x: (size.width - ts.width) / 2, y: (size.height - ts.height) / 2), withAttributes: attrs)
        }

        return img.pngData()
    }

    // Время на скриншотах — от 9:41 сегодняшнего дня (как в строке статуса после `simctl status_bar`)
    private static var base: Int64 {
        let d = Calendar.current.date(bySettingHour: 9, minute: 41, second: 0, of: Date())!
        return Int64(d.timeIntervalSince1970 * 1000)
    }

    private static func seed() {
        if AuthState.myUserId == nil { AuthState.myUserId = "demo-me" }
        let me = AuthState.myUserId!
        let min: Int64 = 60_000, hour = 60 * min, day = 24 * hour

        for p in people {
            ChatStore.deleteConversation("demo-\(p.id)")
            ContactProfileStore.save(userId: p.id, name: p.name, avatar: avatarPNG(for: p.name))
        }

        var n = 0
        func add(_ who: String, mine: Bool, _ text: String, at: Int64, _ status: MessageStatus = .read,
                 kind: String = "text", caption: String? = nil, reply: (String, String, String)? = nil) {
            n += 1
            var m = LocalMessage(id: "d\(n)", conversationId: "demo-\(who)", senderUserId: mine ? me : who, isMine: mine,
                                 text: text, sentAt: at, status: status, serverMessageId: "sd\(n)")
            m.kind = kind
            m.caption = caption
            if let reply { m.replyToId = reply.0; m.replyAuthorUserId = reply.1; m.replyText = reply.2 }
            ChatStore.add(m)
        }

        // переписка, которую откроем на втором скриншоте
        let a = base - 50 * min
        let view = t("Вот здесь, вид просто невероятный", "Right here — the view is unreal")
        add("anna", mine: false, t("Привет! Ты уже решил насчёт выходных?", "Hey! Any plans for the weekend?"), at: a)
        add("anna", mine: true, t("Привет) Думаю, поедем в горы, если погода не подведёт",
                                  "Hi) Thinking of the mountains, if the weather holds up"), at: a + 2 * min)
        add("anna", mine: false, t("Звучит отлично! Я как раз нашла классное место",
                                   "Sounds great! I just found an amazing spot"), at: a + 3 * min)
        add("anna", mine: false, mountains(), at: a + 4 * min, kind: "media", caption: view)
        add("anna", mine: true, t("Вау 😍 Беру палатку и термос", "Wow 😍 I'll bring the tent and a thermos"),
            at: a + 6 * min, reply: ("sd4", "anna", view))
        ChatStore.applyReaction(targetId: "sd5", conversationId: "demo-anna", userId: "anna", emoji: "❤️", at: base)
        add("anna", mine: false, t("Выезжаем в субботу в 8 утра?", "Leave Saturday at 8 am?"), at: base - 6 * min)
        add("anna", mine: true, t("Да, заеду за тобой", "Yes, I'll pick you up"), at: base - 5 * min)
        add("anna", mine: false, t("Отлично, тогда до субботы 🙌", "Perfect, see you Saturday 🙌"), at: base - 3 * min)

        add("mom", mine: false, t("Позвони, когда освободишься", "Call me when you're free"), at: base - 40 * min)
        add("dmitry", mine: true, t("Скинул тебе документы по проекту, посмотри, когда будет время",
                                    "Sent you the project docs, take a look when you can"), at: base - 2 * hour)
        add("elena", mine: false, sunset(), at: base - 5 * hour, kind: "media",
            caption: t("Закат с балкона", "Sunset from the balcony"))
        add("maxim", mine: false, #"{"callId":"c1","media":"video","outcome":"unanswered"}"#, at: base - 20 * hour, kind: "call")
        add("ilya", mine: false, t("Спасибо, до встречи!", "Thanks, see you!"), at: base - 2 * day)
        add("olga", mine: true, t("С днём рождения! 🎉", "Happy birthday! 🎉"), at: base - 4 * day)
        add("sergey", mine: false, t("Договорились, созвонимся в понедельник", "Deal, let's talk on Monday"), at: base - 9 * day)

        // непрочитанные: у Анны — два последних, у мамы — одно
        try? AppDatabase.shared.dbQueue.write { db in
            for (cid, upTo) in [("demo-anna", base - 6 * min), ("demo-mom", base - 41 * min)] {
                try db.execute(sql: "INSERT OR REPLACE INTO conversation_read (conversationId, lastReadAt) VALUES (?, ?)",
                               arguments: [cid, upTo - 1])
            }
            for p in people where p.id != "anna" && p.id != "mom" {
                try db.execute(sql: "INSERT OR REPLACE INTO conversation_read (conversationId, lastReadAt) VALUES (?, ?)",
                               arguments: ["demo-\(p.id)", base])
            }
        }
    }

    // ---- нарисованные «фотографии» ----

    private static func mountains() -> String {
        photo("demo-mountains", CGSize(width: 1600, height: 1200)) { ctx, s in
            gradient(ctx, [UIColor(red: 0.45, green: 0.62, blue: 0.95, alpha: 1), UIColor(red: 0.98, green: 0.78, blue: 0.62, alpha: 1)], s)
            UIColor(red: 1, green: 0.95, blue: 0.8, alpha: 1).setFill()
            ctx.fillEllipse(in: CGRect(x: s.width * 0.68, y: s.height * 0.18, width: 160, height: 160))
            polygon(ctx, UIColor(red: 0.36, green: 0.42, blue: 0.62, alpha: 1),
                    [(0, 0.75), (0.25, 0.38), (0.45, 0.62), (0.65, 0.3), (1, 0.7), (1, 1), (0, 1)], s)
            polygon(ctx, UIColor.white.withAlphaComponent(0.9), [(0.6, 0.38), (0.65, 0.3), (0.7, 0.37), (0.66, 0.35)], s)
            polygon(ctx, UIColor(red: 0.2, green: 0.38, blue: 0.32, alpha: 1),
                    [(0, 0.85), (0.3, 0.68), (0.55, 0.8), (0.8, 0.66), (1, 0.8), (1, 1), (0, 1)], s)
        }
    }

    private static func sunset() -> String {
        photo("demo-sunset", CGSize(width: 1200, height: 1500)) { ctx, s in
            gradient(ctx, [UIColor(red: 0.35, green: 0.2, blue: 0.55, alpha: 1), UIColor(red: 0.98, green: 0.5, blue: 0.35, alpha: 1)], s)
            UIColor(red: 1, green: 0.85, blue: 0.5, alpha: 1).setFill()
            ctx.fillEllipse(in: CGRect(x: s.width * 0.35, y: s.height * 0.55, width: 360, height: 360))
            polygon(ctx, UIColor(red: 0.15, green: 0.1, blue: 0.25, alpha: 1),
                    [(0, 0.78), (0.2, 0.7), (0.2, 0.62), (0.32, 0.62), (0.32, 0.72), (0.6, 0.74), (0.6, 0.58),
                     (0.72, 0.58), (0.72, 0.7), (1, 0.72), (1, 1), (0, 1)], s)
        }
    }

    private static func gradient(_ ctx: CGContext, _ colors: [UIColor], _ s: CGSize) {
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors.map(\.cgColor) as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: s.height), options: [])
    }

    private static func polygon(_ ctx: CGContext, _ color: UIColor, _ pts: [(CGFloat, CGFloat)], _ s: CGSize) {
        color.setFill()
        ctx.beginPath()
        for (i, p) in pts.enumerated() {
            let pt = CGPoint(x: p.0 * s.width, y: p.1 * s.height)
            if i == 0 { ctx.move(to: pt) } else { ctx.addLine(to: pt) }
        }
        ctx.closePath()
        ctx.fillPath()
    }

    // Файл кладётся в хранилище медиа как «уже скачанный», в сообщение — MediaRef с миниатюрой
    private static func photo(_ id: String, _ size: CGSize, draw: (CGContext, CGSize) -> Void) -> String {
        let image = UIGraphicsImageRenderer(size: size).image { draw($0.cgContext, size) }
        let data = image.jpegData(compressionQuality: 0.9)!
        _ = try? MediaStore.write(data, attachmentId: id, ext: "jpg")
        let tw: CGFloat = 200, th = tw * size.height / size.width
        let thumb = UIGraphicsImageRenderer(size: CGSize(width: tw, height: th))
            .image { _ in image.draw(in: CGRect(x: 0, y: 0, width: tw, height: th)) }
            .jpegData(compressionQuality: 0.7)!.base64EncodedString()
        let ref = MediaRef(attachmentId: id, key: "", sha256: "", mime: "image/jpeg", width: Int(size.width),
                           height: Int(size.height), bytes: data.count, durationMs: nil, thumb: thumb)

        return MediaRef.encodeList([ref])
    }
}
#endif
