#if DEBUG
import SwiftUI
import UserNotifications
import AVFoundation
import GRDB

// ВРЕМЕННЫЙ стенд для проверки ленты чата без входа в аккаунт: тот же ChatView, но с фейковой
// перепиской из локальной базы и входящим «от собеседника» каждые 5 секунд. Запуск — с аргументом
// `-chatHarness`. Сети и авторизации не касается.
struct ChatHarness: View {
    static let conv = "harness-conversation"

    @State private var seeded = false
    @State private var timer: Timer?

    @State private var chatOpen = false

    // Повторяет устройство приложения: вкладки, список со СКРЫТОЙ панелью навигации, чат поверх
    // него — иначе не воспроизвести ни свайп назад, ни поведение шапки при переходе.
    @EnvironmentObject private var viewModel: AppViewModel
    private let listMode = ProcessInfo.processInfo.arguments.contains("-listHarness")

    var body: some View {
        if listMode { listBody } else { chatBody }
    }

    // `-listHarness` — настоящий список чатов с поддельными беседами: превью, время, галочки, счётчики
    // и таб-бар при переходе в чат.
    private var listBody: some View {
        TabView {
            ChatListView()
                .tabItem { Label(L("Чаты"), systemImage: "message.fill") }
            Text("Профиль")
                .tabItem { Label(L("Профиль"), systemImage: "person.fill") }
        }
        .onAppear {
            seed()
            seedOtherChats()
            viewModel.conversations = Self.fakeConversations
        }
    }

    private static let fakeConversations: [ConversationItem] = [
        ConversationItem(conversationId: conv, otherUser: OtherUser(userId: "harness-peer", username: "harness"), lastMessageAt: nil),
        ConversationItem(conversationId: "list-mine-read", otherUser: OtherUser(userId: "list-a", username: "alina"), lastMessageAt: nil),
        ConversationItem(conversationId: "list-unread", otherUser: OtherUser(userId: "list-b", username: "mama"), lastMessageAt: nil),
        ConversationItem(conversationId: "list-call", otherUser: OtherUser(userId: "list-c", username: "sergey"), lastMessageAt: nil),
        ConversationItem(conversationId: "list-failed", otherUser: OtherUser(userId: "list-d", username: "team"), lastMessageAt: nil),
        ConversationItem(conversationId: "list-empty", otherUser: OtherUser(userId: "list-e", username: "newbie"), lastMessageAt: nil),
    ]

    private func seedOtherChats() {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let day: Int64 = 86_400_000
        func add(_ cid: String, _ id: String, mine: Bool, _ text: String, at: Int64, _ status: MessageStatus, kind: String = "text") {
            var m = LocalMessage(id: id, conversationId: cid, senderUserId: mine ? "me" : "x", isMine: mine,
                                 text: text, sentAt: at, status: status, serverMessageId: "s-\(id)")
            m.kind = kind
            ChatStore.add(m)
        }
        for cid in ["list-mine-read", "list-unread", "list-call", "list-failed"] { ChatStore.deleteConversation(cid) }
        add("list-mine-read", "l1", mine: true, "https://example.com/catalog/item/1234567890 посмотри вот это, очень длинная ссылка с текстом", at: now - 2 * 3_600_000, .read)
        add("list-unread", "l2", mine: false, "Привет!", at: now - 3 * day, .read)
        add("list-unread", "l3", mine: false, "Ты где?\nПерезвони", at: now - 3 * day + 60_000, .read)
        let log = #"{"callId":"c1","media":"video","outcome":"unanswered"}"#
        add("list-call", "l4", mine: false, log, at: now - 10 * day, .read, kind: "call")
        add("list-failed", "l5", mine: true, "Не ушло", at: now - 5 * 60_000, .failed)
        try? AppDatabase.shared.dbQueue.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO conversation_read (conversationId, lastReadAt) VALUES (?, ?)",
                           arguments: ["list-unread", 0])
        }
    }

    private var chatBody: some View {
        TabView {
            NavigationStack {
                VStack {
                    Spacer()
                    Button("Открыть чат") { chatOpen = true }
                    Spacer()
                }
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(isPresented: $chatOpen) {
                    ChatView(recipientUserId: "harness-peer", recipientUsername: "harness",
                             conversationId: Self.conv)
                }
            }
            .tabItem { Label("Чаты", systemImage: "message.fill") }
        }
        // `-fakeCall` — фиктивный звонок поверх стенда: проверить сворачивание экрана звонка
        .modifier(CallPresentation())
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-fakeCall") { CallManager.shared.debugPreview("active") }
        }
        .onChange(of: seeded) { _, now in if now && !listMode { chatOpen = true } }
        .onAppear {
            // разрешение на уведомления — проверить уборку прочитанных из шторки (simctl push)
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
            seed()
            startIncoming()
        }
    }

    private func seed() {
        ChatStore.deleteConversation(Self.conv)
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        for i in 0..<40 {
            let mine = i % 3 == 0
            ChatStore.add(LocalMessage(
                id: "h\(i)", conversationId: Self.conv,
                senderUserId: mine ? "me" : "harness-peer", isMine: mine,
                text: "Сообщение \(i) " + String(repeating: "текст ", count: i % 6 + 1),
                sentAt: now - Int64((40 - i) * 3_600_000),   // по часу — захватим пару дат
                status: .read, serverMessageId: "s\(i)"))
        }
        seedMedia(now: now)
        seedVideo(now: now)
        // строка, заканчивающаяся почти у края: на ней время раньше наезжало на текст
        ChatStore.add(LocalMessage(
            id: "h-edge", conversationId: Self.conv, senderUserId: "me", isMine: true,
            text: "Обновление вышло\nТеперь стало ещё круче",
            sentAt: now - 60_000, status: .delivered, serverMessageId: "s-edge"))
        // слова у края бабла — проверить, что переносятся целиком, без «сооб-щение»
        let wraps = ["Я отправил тебе сообщение, посмотри пожалуйста внимательно",
                     "Нужно проверить, как переносится длинное сообщение в облачке",
                     "Привет, получил твоё сообщение про документы и договорённости",
                     "Ещё один пример: синхронизация, конфиденциальность, переподключение",
                     "Another example of wrapping: synchronization, confidentiality, reconnection"]
        for (i, t) in wraps.enumerated() {
            ChatStore.add(LocalMessage(
                id: "h-wrap\(i)", conversationId: Self.conv, senderUserId: i % 2 == 0 ? "harness-peer" : "me",
                isMine: i % 2 != 0, text: t, sentAt: now - 50_000 + Int64(i) * 1000, status: .read,
                serverMessageId: "s-wrap\(i)"))
        }
        // ответ на старое сообщение — проверить переход по цитате и кнопку «вниз» после него
        ChatStore.add(LocalMessage(
            id: "h-reply", conversationId: Self.conv, senderUserId: "harness-peer", isMine: false,
            text: "Отвечаю на совсем старое", sentAt: now - 30_000, status: .read, serverMessageId: "s-reply",
            replyToId: "s3", replyAuthorUserId: "me", replyText: "Сообщение 3 текст текст текст текст"))
        // свой ответ на фото — цитата с миниатюрой
        ChatStore.add(LocalMessage(
            id: "h-reply-media", conversationId: Self.conv, senderUserId: "me", isMine: true,
            text: "Тест", sentAt: now - 20_000, status: .read, serverMessageId: "s-reply-media",
            replyToId: "sm1", replyAuthorUserId: "harness-peer", replyText: "Фото"))
        // готовые реакции: на тексте — от собеседника, на фото с подписью — от обоих одинаковая
        let me = AuthState.myUserId ?? ""
        ChatStore.applyReaction(targetId: "s39", conversationId: Self.conv, userId: "harness-peer", emoji: "❤️", at: now)
        ChatStore.applyReaction(targetId: "sm1", conversationId: Self.conv, userId: "harness-peer", emoji: "👍", at: now)
        ChatStore.applyReaction(targetId: "sm1", conversationId: Self.conv, userId: me, emoji: "👍", at: now)
        ChatStore.applyReaction(targetId: "sm2", conversationId: Self.conv, userId: "harness-peer", emoji: "😍", at: now)
        seeded = true
    }

    // Пара медиа-сообщений с уже «скачанными» файлами — для проверки просмотрщика: одиночное фото
    // и альбом из трёх. Картинки рисуются на месте, сети не нужно.
    // Короткий ролик для проверки автопроигрывания в ленте: кадры рисуются на месте, без сети.
    private func seedVideo(now: Int64) {
        let id = "harness-video"
        let url = MediaStore.file(id, ext: "mp4")
        if !MediaStore.exists(id, ext: "mp4") { Self.writeTestVideo(to: url) }
        let thumb = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 112)).image { ctx in
            UIColor.systemGreen.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 112))
        }.jpegData(compressionQuality: 0.6)!.base64EncodedString()
        let ref = MediaRef(attachmentId: id, key: "", sha256: "", mime: "video/mp4",
                           width: 640, height: 360, bytes: 1, durationMs: 3000, thumb: thumb)
        var msg = LocalMessage(
            id: "hv1", conversationId: Self.conv, senderUserId: "harness-peer", isMine: false,
            text: MediaRef.encodeList([ref]), sentAt: now - 10_000, status: .read, serverMessageId: "sv1")
        msg.kind = "media"
        ChatStore.add(msg)

        // вертикальное видео, отправленное ДО исправления поворота: размеры записаны горизонтальными
        // (1920×1080), а миниатюра — вертикальная. Бабл и просмотрщик должны быть вертикальными.
        let tall = UIGraphicsImageRenderer(size: CGSize(width: 112, height: 200)).image { ctx in
            UIColor.systemPink.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 112, height: 200))
            UIColor.white.setFill(); ctx.fill(CGRect(x: 36, y: 80, width: 40, height: 40))
        }.jpegData(compressionQuality: 0.6)!.base64EncodedString()
        let rotated = MediaRef(attachmentId: "harness-rotated", key: "", sha256: "", mime: "video/mp4",
                               width: 1920, height: 1080, bytes: 1, durationMs: 8000, thumb: tall)
        var rot = LocalMessage(
            id: "hv2", conversationId: Self.conv, senderUserId: "me", isMine: true,
            text: MediaRef.encodeList([rotated]), sentAt: now - 5_000, status: .read, serverMessageId: "sv2")
        rot.kind = "media"
        ChatStore.add(rot)
    }

    private static func writeTestVideo(to url: URL) {
        let size = CGSize(width: 640, height: 360)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for i in 0..<90 {                                   // 3 секунды по 30 кадров
            while !input.isReadyForMoreMediaData { usleep(1000) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { break }
            CVPixelBufferLockBaseAddress(pb, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: 640, height: 360, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
            ctx?.setFillColor(UIColor.systemGreen.cgColor); ctx?.fill(CGRect(origin: .zero, size: size))
            ctx?.setFillColor(UIColor.white.cgColor)
            ctx?.fill(CGRect(x: CGFloat(i) * 6, y: 140, width: 80, height: 80))   // бегущий квадрат
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
    }

    private func seedMedia(now: Int64) {
        func photo(_ name: String, _ color: UIColor, _ size: CGSize) -> MediaRef {
            let image = UIGraphicsImageRenderer(size: size).image { ctx in
                color.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
                UIColor.white.withAlphaComponent(0.35).setFill()
                for i in 0..<8 {        // клетка — чтобы было видно зум
                    ctx.fill(CGRect(x: CGFloat(i) * size.width / 8, y: 0, width: 4, height: size.height))
                    ctx.fill(CGRect(x: 0, y: CGFloat(i) * size.height / 8, width: size.width, height: 4))
                }
                let text = name as NSString
                text.draw(at: CGPoint(x: 40, y: 40), withAttributes: [
                    .font: UIFont.boldSystemFont(ofSize: size.width / 8), .foregroundColor: UIColor.white])
            }
            let data = image.jpegData(compressionQuality: 0.85)!
            let id = "harness-\(name)"
            _ = try? MediaStore.write(data, attachmentId: id, ext: "jpg")
            let thumb = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200 * size.height / size.width))
                .image { _ in image.draw(in: CGRect(x: 0, y: 0, width: 200, height: 200 * size.height / size.width)) }
                .jpegData(compressionQuality: 0.6)!.base64EncodedString()

            return MediaRef(attachmentId: id, key: "", sha256: "", mime: "image/jpeg",
                            width: Int(size.width), height: Int(size.height), bytes: data.count,
                            durationMs: nil, thumb: thumb)
        }

        var single = LocalMessage(
            id: "hm1", conversationId: Self.conv, senderUserId: "harness-peer", isMine: false,
            text: MediaRef.encodeList([photo("A", .systemTeal, CGSize(width: 1200, height: 900))]),
            sentAt: now - 30 * 60_000, status: .read, serverMessageId: "sm1")
        single.kind = "media"
        single.caption = "Подпись к фото — проверить, что медиа и текст в одном бабле"
        ChatStore.add(single)

        // вертикальное одиночное — проверить, что бабл высокий и узкий, а не полоса во всю ширину
        var portrait = LocalMessage(
            id: "hm3", conversationId: Self.conv, senderUserId: "harness-peer", isMine: false,
            text: MediaRef.encodeList([photo("E", .systemPurple, CGSize(width: 900, height: 1600))]),
            sentAt: now - 25 * 60_000, status: .read, serverMessageId: "sm3")
        portrait.kind = "media"
        ChatStore.add(portrait)

        var album = LocalMessage(
            id: "hm2", conversationId: Self.conv, senderUserId: "me", isMine: true,
            text: MediaRef.encodeList([
                photo("B", .systemPink, CGSize(width: 900, height: 1600)),
                photo("C", .systemOrange, CGSize(width: 1200, height: 1200)),
                photo("D", .systemIndigo, CGSize(width: 1600, height: 900)),
            ]),
            sentAt: now - 20 * 60_000, status: ProcessInfo.processInfo.arguments.contains("-failedMedia") ? .failed : .read, serverMessageId: "sm2")
        album.kind = "media"
        ChatStore.add(album)
    }

    private func startIncoming() {
        // `-harnessQuiet` — без входящих: для проверок, которым нужна неподвижная лента
        guard timer == nil, !ProcessInfo.processInfo.arguments.contains("-harnessQuiet") else { return }
        var n = 0
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            n += 1
            ChatStore.add(LocalMessage(
                id: "in-\(UUID().uuidString)", conversationId: Self.conv,
                senderUserId: "harness-peer", isMine: false,
                text: "Новое входящее \(n)",
                sentAt: Int64(Date().timeIntervalSince1970 * 1000),
                status: .read, serverMessageId: nil))
        }
    }
}
#endif
