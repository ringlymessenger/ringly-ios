import SwiftUI

struct ChatListView: View {
    @EnvironmentObject var viewModel: AppViewModel
    @ObservedObject private var contacts = ContactProfileCache.shared
    @ObservedObject private var presence = PresenceStore.shared
    @ObservedObject private var muteStore = MuteState.shared
    @ObservedObject private var ringsBalance = RingsBalanceStore.shared
    @ObservedObject private var announcements = AnnouncementStore.shared
    @Environment(\.locale) private var locale
    private let users = UserService()

    @State private var route: ChatRoute?
    @State private var showRings = false
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @State private var lookupResult: UserLookupResponse?     // найденный по нику новый пользователь
    @State private var lookupNotFound = false                // ввели ник ≥3, но точного совпадения нет
    @State private var summaries: [String: ConvSummary] = [:]  // conversationId → {lastAt, unread}

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header          // «Ringly» слева + пилюля справа, на одном уровне
                searchField     // свой поиск (левый заголовок несовместим с системным navbar-title)
                chatList
            }
            .background(AppColor.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)   // прячем системный navbar — используем свой хедер
            .background(KeyboardDismissTap(active: searchFocused))
            .background(TabBarFollowsList().frame(width: 0, height: 0))
            .navigationDestination(item: $route) { r in
                ChatView(recipientUserId: r.userId, recipientUsername: r.username, conversationId: r.conversationId)
                    // ⚠️ Своя идентичность на каждый чат. Переход из уведомления меняет маршрут, пока
                    // открыт ДРУГОЙ чат, и без id SwiftUI переиспользовал бы тот же ChatView: его
                    // @State (conversationId, лента) остался бы от прежнего собеседника.
                    .id(r.id)
            }
            .sheet(isPresented: $showRings) {
                NavigationStack { RingsView(showsDone: true) }
            }
            .task { await viewModel.loadConversations(); subscribeAllPresence() }
            .task { if RewardedAdController.adsAvailable { await ringsBalance.refresh() } }
            .task { await announcements.refresh() }
            .onAppear { subscribeAllPresence(); summaries = ReadStore.snapshot() }   // вернулись из чата → точки + свежие бейджи
            .onChange(of: viewModel.conversations.map(\.conversationId)) { _ in subscribeAllPresence() }
            .task { for await s in ReadStore.observeSummaries() { summaries = s } }   // живой поток непрочитанных/активности
            .onReceive(NotificationCenter.default.publisher(for: .pushNewMessage)) { _ in
                summaries = ReadStore.snapshot()   // NSE дописала в БД в фоне — ValueObservation её не видит
            }
            // поиск нового пользователя по точному нику (дебаунс через .task(id:) — сам отменяется при вводе)
            .task(id: searchText) {
                lookupResult = nil; lookupNotFound = false
                guard normalizedQuery.count >= 3 else { return }
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
                await performLookup()
            }
            .onChange(of: viewModel.pendingChatRoute) { newValue in
                if let r = newValue { route = r; viewModel.pendingChatRoute = nil }
            }
            // Маршрут мог прийти РАНЬШЕ, чем появился список (холодный старт по тапу на уведомление
            // или по ссылке): onChange такое не видит — он срабатывает только на последующие изменения.
            .onAppear {
                if let r = viewModel.pendingChatRoute { route = r; viewModel.pendingChatRoute = nil }
            }
        }
    }

    // ===== хедер: «Ringly» строго слева + пилюля справа на одном уровне =====
    private var header: some View {
        HStack {
            Text(titleText)
                .font(.title.weight(.bold))       // меньше крупного largeTitle, но читаемый бренд-текст
                .foregroundStyle(AppColor.text)
                .lineLimit(1)
            Spacer()
            ringsPill
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    // ===== свой поиск (замена .searchable, чтобы заголовок мог быть слева) =====
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L("Поиск"), text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
                .onSubmit { Task { await performLookup() } }
                .foregroundStyle(AppColor.text)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(AppColor.fill, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var chatList: some View {
        List {
            // объявление администратора — самой первой строкой, над чатами; при поиске не мешает
            if searchText.isEmpty, let a = announcements.visible {
                Section {
                    AnnouncementBanner(announcement: a) {
                        withAnimation(.easeInOut(duration: 0.25)) { announcements.dismiss() }
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
            // глобальный поиск нового пользователя по точному нику (если его ещё нет в чатах)
            if !searchText.isEmpty, let r = lookupResult, !hasConversation(with: r.userId) {
                Section(L("Пользователи")) { lookupRow(r) }
            } else if lookupNotFound, displayedConversations.isEmpty {
                Section(L("Пользователи")) {
                    Text(L("Пользователь не найден. Введите точный @username целиком."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(displayedConversations, id: \.conversationId) { c in
                    if let other = c.otherUser {
                        Button {
                            route = ChatRoute(userId: other.userId, username: other.username,
                                              conversationId: c.conversationId)
                        } label: { row(other, summary: summaries[c.conversationId]) }
                    }
                }
            }
        }
        .listStyle(.plain)
        .refreshable {
            async let conversations: Void = viewModel.loadConversations()
            await announcements.refresh()
            await conversations
        }
        // клавиатура поиска уходит при прокрутке списка
        .scrollDismissesKeyboard(.immediately)
        // ⚠️ НЕ вешать на список SwiftUI-жест тапа (даже simultaneousGesture): он перехватывал
        // нажатия на строки, и чаты переставали открываться. Тап мимо поля — KeyboardDismissTap.
    }

    // нормализованный запрос: без пробелов, lowercase, без ведущего @ (юзер часто вводит @nick)
    private var normalizedQuery: String {
        var q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if q.hasPrefix("@") { q.removeFirst() }
        return q
    }

    // точный lookup по нику → секция «Пользователи» или подсказка «не найден»
    private func performLookup() async {
        let q = normalizedQuery
        guard q.count >= 3 else { lookupResult = nil; lookupNotFound = false; return }
        if let r = try? await users.findByUsername(q) { lookupResult = r; lookupNotFound = false }
        else { lookupResult = nil; lookupNotFound = true }
    }

    // пилюля баланса Rings справа от заголовка → открывает экран Rings (получение коинов).
    // Хедер кастомный (вне тулбара), поэтому стеклянную капсулу рисуем сами через .ultraThinMaterial
    // (тот самый «стеклянный» фон; один блок, без вложенных).
    // Скрыта, пока нет боевых ключей AppLovin (см. RewardedAdController.adsAvailable):
    // без рекламы Rings не заработать, а нерабочая фича = реджект App Review (Guideline 2.1).
    @ViewBuilder private var ringsPill: some View {
        if RewardedAdController.adsAvailable {
            Button { showRings = true } label: {
                HStack(spacing: 6) {
                    RingsCoinIcon(size: 22)
                    // до ответа сервера — 0, а не прочерк: у нового пользователя баланс и есть 0
                    Text(String(ringsBalance.balance ?? 0))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppColor.text)
                }
                .padding(.leading, 8).padding(.trailing, 14).padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    // заголовок = «Ringly», а при проблемах со связью — статус подключения (Telegram-style)
    private var titleText: String {
        switch viewModel.connStatus {
        case .online:     return "Ringly"
        case .connecting: return L("Соединение…")
        case .updating:   return L("Обновление…")
        }
    }

    // беседы, отсортированные Telegram-style (по последней активности), + фильтр строкой поиска
    private var displayedConversations: [ConversationItem] {
        let sorted = viewModel.conversations.sorted { lastAt($0) > lastAt($1) }
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return sorted }
        return sorted.filter { c in
            guard let other = c.otherUser else { return false }
            let c = contacts.byUser[other.userId]
            // ищем и по своему имени, и по имени из профиля: «мама» и «Ирина» найдут один чат
            return other.username.lowercased().contains(q)
                || (c?.name ?? "").lowercased().contains(q)
                || (c?.realName ?? "").lowercased().contains(q)
        }
    }

    private func lastAt(_ c: ConversationItem) -> Int64 {
        if let s = summaries[c.conversationId], s.lastAt > 0 { return s.lastAt }
        return Self.parseISOms(c.lastMessageAt)   // ещё нет локальных сообщений → серверное время беседы
    }

    private func hasConversation(with userId: String) -> Bool {
        viewModel.conversations.contains { $0.otherUser?.userId == userId }
    }

    private func subscribeAllPresence() {
        for c in viewModel.conversations {
            if let uid = c.otherUser?.userId { viewModel.presenceSubscribe(uid) }
        }
    }

    // ===== строка беседы — как в Telegram =====
    // Сверху имя и справа галочки + время последнего сообщения, снизу превью и справа счётчик
    // непрочитанных. Нет ни одного сообщения — вместо превью @ник. Превью в одну строку: высоту
    // строки задаёт аватарка 48pt, как и до превью, — список не становится крупнее.
    private func row(_ other: OtherUser, summary: ConvSummary?) -> some View {
        let resolved = contacts.byUser[other.userId]
        let online = presence.states[other.userId]?.online == true
        let muted = muteStore.isMuted(other.userId)
        let unread = summary?.unread ?? 0
        let last = summary?.last
        return HStack(spacing: 12) {
            avatar(resolved?.avatar, username: other.username, online: online)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(resolved?.name ?? "@\(other.username)").bold().lineLimit(1)
                    // замьючен → перечёркнутый колокольчик (как в Telegram)
                    if muted { Image(systemName: "bell.slash.fill").font(.caption2).foregroundStyle(.secondary) }
                    Spacer(minLength: 6)
                    if let last, last.isMine { lastStatus(last.status) }
                    if let at = summary?.lastAt, at > 0 {
                        Text(Self.listTime(at, locale: locale)).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    if let last { preview(last) }
                    else { Text("@\(other.username)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer(minLength: 0)
                    if unread > 0 { unreadBadge(unread, muted: muted) }
                }
            }
        }
        .onAppear { contacts.ensure(other.userId) }
    }

    // Превью последнего сообщения: текст, у медиа — миниатюра и подпись (или «Фото»/«Видео»),
    // у звонка — значок и итог. Своё и чужое выглядят одинаково: в личном чате «Вы:» не пишут.
    @ViewBuilder
    private func preview(_ m: LastMessage) -> some View {
        switch m.kind {
        case "media":
            let refs = MediaRef.decodeList(m.text)
            HStack(spacing: 5) {
                if let ref = refs.first, let thumb = MediaService.thumbnail(ref) {
                    Image(uiImage: thumb).resizable().scaledToFill()
                        .frame(width: 18, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .overlay {
                            if ref.isVideo {
                                Image(systemName: "play.fill").font(.system(size: 8)).foregroundStyle(.white)
                            }
                        }
                }
                previewText(mediaLabel(m, refs: refs))
            }
        case "call":
            let log = (m.text.data(using: .utf8)).flatMap { try? JSONDecoder().decode(CallLog.self, from: $0) }
            HStack(spacing: 4) {
                Image(systemName: log?.isVideo == true ? "video.fill" : "phone.fill").font(.caption)
                previewText(log?.displayText(isMine: m.isMine) ?? L("Звонок"))
            }
            .foregroundStyle(.secondary)
        default:
            previewText(Self.singleSpaced(m.text))
        }
    }

    private func previewText(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
    }

    private func mediaLabel(_ m: LastMessage, refs: [MediaRef]) -> String {
        if let caption = m.caption, !caption.isEmpty { return Self.singleSpaced(caption) }
        if refs.count > 1 { return Plural.files(refs.count) }

        return refs.first?.isVideo == true ? L("Видео") : L("Фото")
    }

    // переносы строк в превью не нужны: в единственную строку должны попасть слова, а не пустота
    private static func singleSpaced(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    // Статус своего последнего сообщения — как в чате: часы, одна галочка (отправлено/доставлено),
    // две (прочитано), красный «!» — не отправлено.
    @ViewBuilder
    private func lastStatus(_ status: MessageStatus) -> some View {
        switch status {
        case .sending:
            Image(systemName: "clock").font(.caption2).foregroundStyle(.secondary)
        case .sent, .delivered:
            Image(systemName: "checkmark").font(.caption2.weight(.semibold)).foregroundStyle(.blue)
        case .read:
            HStack(spacing: -4) {
                Image(systemName: "checkmark")
                Image(systemName: "checkmark")
            }
            .font(.caption2.weight(.semibold)).foregroundStyle(.blue)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").font(.footnote).foregroundStyle(.red)
        }
    }

    // Время в списке, как в Telegram: сегодня — часы, за последнюю неделю — день недели, раньше — дата.
    private static func listTime(_ ms: Int64, locale: Locale) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let cal = Calendar.current
        let style: String
        if cal.isDateInToday(date) {
            style = "time"
        } else if let weekAgo = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: Date())), date >= weekAgo {
            style = "weekday"
        } else {
            style = "date"
        }

        return formatter(style, locale: locale).string(from: date)
    }

    // форматтеры дорогие, а строки перерисовываются часто (присутствие, новые сообщения) — держим по штуке
    private static var formatters: [String: DateFormatter] = [:]

    private static func formatter(_ style: String, locale: Locale) -> DateFormatter {
        let key = style + "|" + locale.identifier
        if let f = formatters[key] { return f }
        let f = DateFormatter()
        f.locale = locale
        switch style {
        case "time":    f.timeStyle = .short
        case "weekday": f.setLocalizedDateFormatFromTemplate("EEE")
        default:        f.setLocalizedDateFormatFromTemplate("ddMMyy")   // 08.10.26, как в Telegram
        }
        formatters[key] = f

        return f
    }

    // бейдж непрочитанных: синий обычно, серый — если чат замьючен (Telegram-style)
    private func unreadBadge(_ count: Int, muted: Bool) -> some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.caption.weight(.semibold)).foregroundStyle(.white)   // на синей/серой капсуле — белый в любой теме
            .padding(.horizontal, 6)
            .frame(minWidth: 20, minHeight: 20)
            .background(muted ? Color.gray : Color.blue)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private func avatar(_ image: UIImage?, username: String, online: Bool) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: 48, height: 48).clipShape(Circle())
                } else {
                    Circle().fill(.blue.opacity(0.2)).frame(width: 48, height: 48)
                        .overlay(Text(username.prefix(1).uppercased()).foregroundStyle(.blue))
                }
            }
            if online {
                Circle().fill(Color.green)
                    .frame(width: 13, height: 13)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2.5))
            }
        }
    }

    // строка «найти нового пользователя по нику»
    private func lookupRow(_ r: UserLookupResponse) -> some View {
        Button {
            route = ChatRoute(userId: r.userId, username: r.username, conversationId: nil)
        } label: {
            HStack(spacing: 12) {
                Circle().fill(.blue.opacity(0.2)).frame(width: 48, height: 48)
                    .overlay(Text(r.username.prefix(1).uppercased()).foregroundStyle(.blue))
                Text("@\(r.username)").bold()
                Spacer()
                Image(systemName: "message.fill").foregroundStyle(.blue)
            }
        }
    }

    // ISO8601 (с дробными секундами и без) → миллисекунды; nil/битое → 0
    private static func parseISOms(_ s: String?) -> Int64 {
        guard let s else { return 0 }
        let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return Int64(d.timeIntervalSince1970 * 1000) }
        let f2 = ISO8601DateFormatter(); f2.formatOptions = [.withInternetDateTime]
        if let d = f2.date(from: s) { return Int64(d.timeIntervalSince1970 * 1000) }
        return 0
    }
}

struct ChatRoute: Identifiable, Hashable {
    let userId: String; let username: String; let conversationId: String?
    var id: String { conversationId ?? userId }
}

// Тап в любом месте мимо поля ввода убирает клавиатуру — UIKit-распознавателем на окне, а не
// SwiftUI-жестом. `cancelsTouchesInView = false`: касание идёт дальше, как будто распознавателя
// нет, и нажатие на чат одновременно и убирает клавиатуру, и открывает чат. Включён, только пока
// поле в фокусе; касания внутри самих полей ввода не ловит (иначе тап для перестановки курсора
// закрывал бы клавиатуру).
private struct KeyboardDismissTap: UIViewRepresentable {
    let active: Bool

    func makeUIView(context: Context) -> Host { Host() }
    func updateUIView(_ view: Host, context: Context) { view.tap.isEnabled = active }

    final class Host: UIView, UIGestureRecognizerDelegate {
        let tap = UITapGestureRecognizer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            tap.cancelsTouchesInView = false
            tap.delaysTouchesEnded = false
            tap.isEnabled = false
            tap.delegate = self
            tap.addTarget(self, action: #selector(dismiss))
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            tap.view?.removeGestureRecognizer(tap)
            window?.addGestureRecognizer(tap)
        }

        @objc private func dismiss() { tap.view?.endEditing(true) }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var v = touch.view
            while let current = v {
                if current is UITextField || current is UITextView { return false }
                v = current.superview
            }
            return true
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

// Таб-бар уезжает вместе со списком при переходе в чат и приезжает вместе с ним обратно — как
// в Telegram.
//
// ⚠️ Почему не системные способы:
//  • `.toolbar(.hidden, for: .tabBar)` на экране чата прячет панель скачком в начале перехода и
//    скачком же возвращает её, когда список уже на месте;
//  • флаг UIKit `hidesBottomBarWhenPushed` анимирует панель правильно, но его надо поставить
//    контроллеру ДО перехода, а контроллер чата создаёт и пушит сам SwiftUI — изнутри экрана флаг
//    успевает только после того, как UIKit уже решил, что панель остаётся.
//
// Как устроено. `setTabBarHidden` сразу меняет нижнюю безопасную зону экранов, а саму панель лишь
// гасит (isHidden + alpha). Поэтому:
//  • в чат: панель прячется по-настоящему в начале перехода (у чата с первого кадра правильный
//    отступ под полем ввода), но на время перехода снова видна и уезжает влево вслед за списком;
//  • назад: панель видна и приезжает вместе со списком, а по-настоящему показывается, только когда
//    переход завершился — иначе отступ чата вырос бы посреди перехода и поле ввода подпрыгнуло бы.
//    Отменённый свайп назад оставляет её скрытой.
// Снимок панели вместо неё самой не годится: стекло (Liquid Glass) в снимок не попадает.
//
// ⚠️ iOS 18–25 (старая панель, без стекла) — наоборот, ТОЛЬКО снимок: сдвиг самой панели там не
// держится, и её иконки на время перехода оставались поверх открытого чата (iPhone SE, iOS 18).
// Настоящая панель прячется сразу, а уезжает её снимок, вложенный в экран списка, — он движется
// вместе со списком сам, и чат перекрывает его, как и сам список.
private struct TabBarFollowsList: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Probe { Probe() }
    func updateUIViewController(_ controller: Probe, context: Context) {}

    final class Probe: UIViewController {
        // контроллер списка — тот, что лежит прямо в стеке навигации
        private var listHost: UIViewController? {
            var c: UIViewController = self
            while let p = c.parent, !(p is UINavigationController) { c = p }

            return c.parent is UINavigationController ? c : nil
        }

        // снимок панели для iOS 18–25: делается при уходе в чат, им же панель «приезжает» обратно
        private var barSnapshot: UIView?

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            guard #available(iOS 18.0, *), let host = listHost, let nav = host.navigationController,
                  nav.topViewController !== host,          // уходим вглубь стека, а не на другую вкладку
                  let tabs = tabBarController, !tabs.isTabBarHidden else { return }
            if #unavailable(iOS 26.0) {
                // снимок — ДО скрытия: скрытая панель снимается пустой
                barSnapshot?.removeFromSuperview()
                barSnapshot = Self.snapshot(of: tabs.tabBar, in: host.view)
            }
            tabs.setTabBarHidden(true, animated: false)
            guard let coordinator = nav.transitionCoordinator else { barSnapshot?.removeFromSuperview(); return }
            if #unavailable(iOS 26.0) {
                guard let snap = barSnapshot else { return }
                host.view.addSubview(snap)
                coordinator.animate(alongsideTransition: nil, completion: { context in
                    snap.removeFromSuperview()
                    if context.isCancelled { tabs.setTabBarHidden(false, animated: false) }
                })
                return
            }
            let bar = tabs.tabBar
            let offset = -host.view.bounds.width
            Self.show(bar)
            coordinator.animate(alongsideTransition: { _ in
                bar.transform = CGAffineTransform(translationX: offset, y: 0)
            }, completion: { context in
                bar.transform = .identity
                if context.isCancelled { tabs.setTabBarHidden(false, animated: false) } else { Self.hide(bar) }
            })
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            guard #available(iOS 18.0, *), let host = listHost, let tabs = tabBarController,
                  tabs.isTabBarHidden else { return }
            guard let coordinator = host.navigationController?.transitionCoordinator else {
                tabs.setTabBarHidden(false, animated: false)
                return
            }
            if #unavailable(iOS 26.0) {
                // назад: снимок едет вместе со списком, настоящая панель — по завершении перехода
                // (раньше отступ чата вырос бы посреди перехода). Снимка нет — просто показать в конце.
                if let snap = barSnapshot { host.view.addSubview(snap) }
                coordinator.animate(alongsideTransition: nil, completion: { [weak self] context in
                    self?.barSnapshot?.removeFromSuperview()
                    if !context.isCancelled { tabs.setTabBarHidden(false, animated: false) }
                })
                return
            }
            let bar = tabs.tabBar
            bar.transform = CGAffineTransform(translationX: -host.view.bounds.width, y: 0)
            Self.show(bar)
            coordinator.animate(alongsideTransition: { _ in
                bar.transform = .identity
            }, completion: { context in
                bar.transform = .identity
                if context.isCancelled { Self.hide(bar) } else { tabs.setTabBarHidden(false, animated: false) }
            })
        }

        // снимок панели в координатах экрана списка (там, где она сейчас нарисована)
        private static func snapshot(of bar: UITabBar, in container: UIView) -> UIView? {
            guard let snap = bar.snapshotView(afterScreenUpdates: false), let superview = bar.superview else { return nil }
            snap.frame = superview.convert(bar.frame, to: container)
            snap.isUserInteractionEnabled = false
            return snap
        }

        // так же, как гасит и показывает панель сам setTabBarHidden
        private static func show(_ bar: UITabBar) { bar.isHidden = false; bar.alpha = 1 }
        private static func hide(_ bar: UITabBar) { bar.isHidden = true; bar.alpha = 0 }
    }
}
