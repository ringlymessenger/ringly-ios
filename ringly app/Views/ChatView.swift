import SwiftUI
import Combine
import PhotosUI
import Photos
import UniformTypeIdentifiers

extension View {
    // Таб-бар на экране чата не показываем. На iOS 18+ его прячет список чатов (TabBarFollowsList):
    // там панель уезжает вместе со списком, а `.toolbar(.hidden, for: .tabBar)` прятал её скачком
    // в начале перехода и скачком возвращал после. На iOS 17 нужного API нет — старый способ.
    @ViewBuilder func hideTabBar() -> some View {
        if #available(iOS 18.0, *) { self }
        else { self.toolbar(.hidden, for: .tabBar) }
    }

    // Перевёрнутая лента — как в Telegram и почти во всех мессенджерах.
    //
    // Чат живёт снизу вверх: новое приходит вниз, клавиатура поднимается снизу, плашки ответа и
    // полоса вложений растут снизу. Обычная лента устроена наоборот — её начало вверху, и каждое из
    // этих событий требовало вручную прижимать низ: при открытии, при клавиатуре, при новом
    // сообщении, при догрузке миниатюр. Отсюда вся дёрганность: каждое прижатие было вторым,
    // видимым движением поверх первого, а LazyVStack, не знающий высот непоказанных строк, ещё и
    // промахивался.
    //
    // Перевёрнутой ленте прижимать нечего: её начало — и есть низ экрана. Лента отражается по
    // вертикали, каждая строка — обратно, в сумме строки выглядят как обычно. Сжимается лента под
    // клавиатурой — свежие сообщения едут вверх вместе с её краем; растёт медиа-бабл — растёт вверх,
    // в историю, не сдвигая низ.
    //
    // ⚠️ Внутри ленты координаты прокрутки остаются своими, НЕперевёрнутыми: её «верх» рисуется внизу
    // экрана. Поэтому прокрутка «в самый низ» — это якорь `.top`, а первый ребёнок стека — самое
    // свежее сообщение.
    func chatFlipped() -> some View {
        scaleEffect(x: 1, y: -1, anchor: .center)
    }

    // ⚠️ Системный эффект краёв прокрутки (iOS 26, Liquid Glass) у перевёрнутой ленты ОБЯЗАТЕЛЬНО
    // выключать. Он размывает содержимое под панелями, а геометрию считает в координатах самой ленты —
    // то есть отражённых. В итоге размытие, задуманное для узкой полосы под панелью навигации,
    // ложилось на всю переписку целиком, как только лента стояла у свежих сообщений.
    @ViewBuilder func chatEdgeEffectOff() -> some View {
        if #available(iOS 26.0, *) { self.scrollEdgeEffectHidden(true, for: .all) }
        else { self }
    }

}

extension ToolbarContent {
    // iOS 26 сам подкладывает под элементы панели общее стекло. Капсуле шапки чата своё стекло
    // нужно другой формы, поэтому общее под ней выключается.
    @ToolbarContentBuilder func withoutSharedGlass() -> some ToolbarContent {
        if #available(iOS 26.0, *) { self.sharedBackgroundVisibility(.hidden) }
        else { self }
    }
}

// Выбранное, но ещё НЕ отправленное медиа: лежит в полосе над полем ввода, пока пользователь
// печатает подпись. Заливка стартует сразу при выборе, а не по нажатию «отправить», — иначе
// отправка стоила бы полного времени экспорта видео уже ПОСЛЕ того, как подпись набрана.
//
// Собственный id обязателен: пользователь может убрать ячейку, пока файлы ещё готовятся, и
// адресация по индексу после этого писала бы результат заливки не в ту ячейку.
struct StagedMedia: Identifiable {
    let id = UUID()
    var ref: MediaRef
}

struct ChatView: View {
    let recipientUserId: String
    let recipientUsername: String
    @State var conversationId: String?            // nil для нового чата из поиска

    @EnvironmentObject var viewModel: AppViewModel
    @ObservedObject private var dbg = MessagingDebug.shared
    @ObservedObject private var presence = PresenceStore.shared
    @ObservedObject private var typingStore = TypingStore.shared
    @ObservedObject private var blockStore = BlockState.shared
    @ObservedObject private var contacts = ContactProfileCache.shared
    private let users = UserService()

    @State private var messages: [LocalMessage] = []
    // Набранный текст живёт в отдельной модели, на которую подписано ТОЛЬКО поле ввода
    // (ComposerTextRow). Раньше это был @State самого экрана, и каждое нажатие клавиши
    // перерисовывало весь чат — ленту со всеми видимыми сообщениями. Отсюда «лаги».
    @State private var composer = ComposerModel()
    // первое заполнение ленты уже прошло → дальнейшие прокрутки наши и анимированные
    @State private var pickedMedia: [PhotosPickerItem] = []
    @State private var showPicker = false               // шторка выбора медиа (MediaPickerSheet)
    @State private var pickerCaption = ""               // подпись, набранная в шторке
    // Потолок на сообщение. Каждая миниатюра едет ВНУТРИ payload, поэтому это не только про UI:
    // альбом раздувает тело POST /messages кратно числу устройств получателей.
    static let maxMediaPerMessage = 10
    private static let bottomAnchor = "__bottom__"   // id маркера конца ленты
    @State private var staged: [StagedMedia] = []       // выбранное, ждёт подписи и отправки
    @State private var prepareTask: Task<Void, Never>?  // фоновая подготовка+заливка выбранного
    @State private var stagedRowId: String?             // localId бабла, если отправку уже нажали
    @State private var sendingMedia = false             // отправка ждёт дозаливки выбранного
    @State private var uploadingMedia = false
    @State private var mediaError: String?
    @State private var serverTitle = ""             // имя из профиля собеседника (с сервера)
    // Имя в шапке и везде в чате: своё имя контакта, если задано (локально), иначе из профиля
    private var title: String { contacts.byUser[recipientUserId]?.alias ?? serverTitle }
    @State private var sending = false
    @State private var lastReceiptedId: String?     // дебаунс read-квитанций
    @State private var securityWarning = false      // «изменился код безопасности»
    @State private var presenceTick = 0             // тик для обновления относительного времени «был в сети»
    private let presenceTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    @State private var showProfile = false          // экран профиля собеседника
    @Environment(\.dismiss) private var dismiss     // закрыть чат при «удалить контакт»
    @State private var typingActive = false         // мы уже послали "start" (чтобы не спамить "stop")
    @State private var lastTypingSentAt = Date.distantPast   // троттлинг "start" (не чаще раза в 4с)
    @State private var replyingTo: LocalMessage?    // реплай: на что отвечаем (плашка над полем ввода)
    @State private var editingTarget: LocalMessage? // редактирование: какое сообщение правим
    @State private var deleteCandidate: LocalMessage?   // подтверждение «удалить у всех»
    @State private var failedCandidate: LocalMessage?   // тап по красному значку неотправленного → повторить/удалить
    @State private var viewerRequest: MediaViewerRequest?   // открытый просмотрщик медиа
    @State private var viewerHiddenKey: String?         // миниатюра, «улетевшая» в просмотрщик
    @State private var menuRequest: MessageMenuRequest? // открытое меню сообщения (MessageMenuView)
    @State private var menuHiddenId: String?            // сообщение, «поднятое» в меню, — на месте его не видно
    @State private var heartBurst: HeartBurst.Spot?      // вспышка ❤️ после двойного нажатия (одна на ленту)
    @State private var forwardSource: LocalMessage?     // пересылка: какое сообщение шлём в другой чат
    @State private var scrollTarget: String?        // тап по цитате → скролл к оригиналу
    @State private var atBottom = true              // лента у конца → кнопку «вниз» не показываем
    @State private var unreadBelow = 0              // пришло, пока читали историю — счётчик на кнопке «вниз»
    @FocusState private var inputFocused: Bool
    // где поле ввода (global) — отсюда вылетает отправленное. Не @State: нужно только в момент
    // отправки, а как состояние перерисовывало бы экран на каждом сдвиге клавиатуры.
    @State private var inputFrame = FrameBox()
    @State private var composerHeight: CGFloat = 0  // высота панели ввода, лежащей поверх ленты
    @State private var feedScroll = FeedScroll()      // прокрутка ленты — напрямую через UIScrollView (см. FeedScroll)
    @State private var toast: String?                 // короткое подтверждение («Переслано»)
    @State private var highlightedId: String?         // сообщение, к которому перешли по цитате — облачко подсвечено
    @State private var flight: SendFlight?          // полёт только что отправленного сообщения в ленту
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Как в iMessage и Telegram: отправленное не возникает в ленте, а выезжает из поля ввода.
    //
    // Летит КОПИЯ бабла поверх всего экрана (flightGhost), а настоящая строка уже стоит на своём месте
    // в ленте, но скрыта, пока копия не долетит. Двигать саму строку было нельзя: ради старта под
    // лентой приходилось снимать с неё обрезку и поднимать её над полем ввода, и в полёте поверх поля
    // вылезало соседнее содержимое, а сам бабл проходил ПОД соседними сообщениями.
    private struct SendFlight {
        let text: String
        let from: CGRect            // рамка поля ввода в момент отправки
        var id: String?             // localId строки, когда она появилась в ленте
        var message: LocalMessage?  // её содержимое — копия рисуется из него
        var target: CGRect?         // где строка стоит на экране — туда летит копия
        var offset: CGSize = .zero
        var ready = false           // смещение посчитано: копию можно показывать
        var formed: CGFloat = 0     // 0 — ещё просто текст из поля, 1 — готовый бабл (см. textBubbleBody)
    }
    private static let flySpring = Animation.spring(response: 0.3, dampingFraction: 0.88)
    // Сам перелёт — мягче соседей: у пружины почти весь путь приходится на первые кадры, и бабл
    // не столько летел, сколько телепортировался. Складывается он чуть быстрее, чем долетает.
    private static let flyMove = Animation.spring(response: 0.36, dampingFraction: 0.9)
    private static let flyForm = Animation.easeInOut(duration: 0.24)

    var body: some View {
        VStack(spacing: 0) {
            // временный диагностический баннер (тап — скрыть)
            if let d = dbg.last {
                Text(d)
                    .font(.caption2).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8).background(.orange)
                    .textSelection(.enabled)
                    .onTapGesture { dbg.last = nil }
            }
            // предупреждение о смене identity собеседника (≈ «изменился код безопасности»)
            if securityWarning {
                HStack {
                    Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                    Text(L("Код безопасности с собеседником изменился (возможно, переустановил приложение)."))
                        .font(.caption2)
                    Spacer()
                    Button(L("Ок")) {
                        SecurityEvents.acknowledge(recipientUserId)
                        securityWarning = false
                    }.font(.caption2)
                }
                .padding(8).background(.yellow.opacity(0.25))
            }
            // я заблокировал собеседника → он не может мне писать/звонить; ввод выключен, тут разблокировка
            if blockStore.isBlocked(recipientUserId) {
                HStack {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.red)
                    Text(L("Вы заблокировали этого пользователя")).font(.caption)
                    Spacer()
                    Button(L("Разблокировать")) { blockStore.setBlocked(recipientUserId, username: recipientUsername, false) }
                        .font(.caption)
                }
                .padding(8).background(.red.opacity(0.1))
            }
            ScrollViewReader { proxy in
                // ZStack, а не .overlay на ленте: пока лента едет по инерции, её распознаватель
                // жестов забирает первое касание себе (гасит прокрутку), и до кнопки оно не доходит.
                // Отдельным слоем рядом со ScrollView кнопка нажимается сразу.
                ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        // Маркер конца ленты — ПЕРВЫМ: в перевёрнутой ленте начало содержимого и есть
                        // низ экрана. К нему едет кнопка «вниз».
                        //
                        // ⚠️ Высота маркера ЗАМЕНЯЕТ нижний отступ ленты (см. padding ниже). Когда отступ
                        // был снаружи маркера, прокрутка «к маркеру» прятала его, а покой ленты — нет:
                        // каждая доводка вниз сдвигала всю переписку на 16pt туда и обратно. Особенно
                        // видно было на вылете отправленного — он стартовал ниже поля ввода.
                        // Сверх отступа — высота панели ввода: она стеклянная и лежит ПОВЕРХ ленты
                        // (переписка просвечивает сквозь неё, как в Telegram), а в покое последнее
                        // сообщение должно стоять над ней.
                        Color.clear
                            .frame(height: 17 + composerHeight)
                            .background(ScrollViewFinder(feed: feedScroll))
                            .id(Self.bottomAnchor)

                        // От новых к старым: первым в перевёрнутой ленте идёт самое свежее.
                        // Индекс — исходный, хронологический: по нему разделитель дат сравнивает
                        // сообщение с предыдущим по времени, а не по порядку отрисовки.
                        ForEach(Array(messages.enumerated()).reversed(), id: \.element.id) { idx, m in
                            entry(idx, m).chatFlipped()
                                // летящему — без появления «из прозрачности»: он выезжает уже целиком
                                .transition(flight?.id == m.id ? .identity : .opacity)
                        }
                    }
                    // `.bottom` содержимого — это ВЕРХ экрана (лента перевёрнута); низ экрана держит маркер
                    .padding([.horizontal, .bottom])
                }
                .chatFlipped()
                .chatEdgeEffectOff()
                // ⚠️ Без `.scrollPosition(id:)`. Привязка позиции SwiftUI в перевёрнутой ленте вела себя
                // непредсказуемо: после программной прокрутки переставала обновляться от пальца (кнопка
                // «вниз» пропадала навсегда) и заново применялась при каждой перерисовке — лента сама
                // ползла, пока набираешь текст. Положение читается и задаётся прямо у UIScrollView
                // (FeedScroll): он один источник правды.
                // Полоса прокрутки отразилась бы вместе с лентой и бегала бы в обратную сторону.
                .scrollIndicators(.hidden)
                // Как в Telegram: клавиатура убирается тапом по переписке и утягивается пальцем
                // при скролле. simultaneousGesture, а НЕ onTapGesture: обычный жест перехватил бы
                // тапы у баблов (цитата → переход к оригиналу, long-press → контекстное меню),
                // а одновременный отрабатывает вместе с ними и ничего не ломает.
                .simultaneousGesture(TapGesture().onEnded { inputFocused = false })
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages.count) { oldCount, newCount in
                    // Первое заполнение (открытие чата) — ничего не делаем: перевёрнутая лента и так
                    // начинается снизу. Удаление — тоже: лента просто сомкнётся.
                    guard oldCount > 0, newCount > oldCount, let last = messages.last else { return }

                    if atBottom || last.isMine {
                        // Были внизу или это наше — доводим до самого низа (у края могло стоять не само
                        // начало ленты, а место чуть выше — тогда новое легло бы под поле ввода).
                        unreadBelow = 0
                        scrollToBottom(animated: true)
                    } else {
                        // Читает историю — ленту не трогаем, копим счётчик на кнопке (как в Telegram).
                        unreadBelow += messages.suffix(newCount - oldCount).filter { !$0.isMine }.count
                    }
                }
                .onChange(of: scrollTarget) { _, t in       // тап по цитате / «Показать в чате» → к сообщению
                    guard let t else { return }
                    scrollTarget = nil
                    // Разовая прокрутка к строке. Привязки позиции больше нет, так что спорить с ней
                    // нечему: лента остаётся там, куда приехала. `.center` симметричен — верен и в
                    // перевёрнутой ленте. Кнопку «вниз» покажет FeedScroll по фактическому смещению.
                    feedScroll.stopDeceleration()
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(t, anchor: .center) }
                    flashHighlight(t)
                }

                scrollDownButton
                    .padding(.bottom, composerHeight)
                }
                // Лента заходит под шапку, как в Telegram: капсула с именем и аватарка висят над
                // перепиской. Обрезать её по своей рамке нельзя — под шапкой оставалась чёрная полоса,
                // о которую сообщения резко обрывались. Системный эффект краёв у перевёрнутой ленты
                // выключен (см. chatEdgeEffectOff), поэтому читаемость часов и шапки держит своё
                // затемнение сверху (topFade).
                .overlay(alignment: .bottom) {
                    VStack(spacing: 0) {
                        stagedStrip
                        if !blockStore.isBlocked(recipientUserId) { inputBar }   // при блокировке ввод скрыт (разблокировка — в плашке)
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
                    // Под панелью — то же затемнение, что под шапкой: сквозь стекло поля ввода
                    // переписка иначе читалась поверх набираемого текста.
                    .background(alignment: .bottom) {
                        LinearGradient(stops: [.init(color: Color(uiColor: .systemBackground).opacity(0), location: 0),
                                               .init(color: Color(uiColor: .systemBackground).opacity(0.9), location: 0.45),
                                               .init(color: Color(uiColor: .systemBackground), location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: composerHeight + 24)
                            .ignoresSafeArea(edges: .bottom)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        // на корне экрана, а не на ленте: только отсюда затемнение дотягивается до верхнего края
        .overlay(alignment: .top) { topFade }
        .navigationTitle(headerName)
        .navigationBarTitleDisplayMode(.inline)
        // Шапка как в Telegram: по центру стеклянная капсула с именем и статусом, справа аватарка.
        // И то и другое ведёт в профиль собеседника.
        .toolbar {
            ToolbarItem(placement: .principal) { headerCapsule }.withoutSharedGlass()
            // аватарка — в системном стекле панели, как в Telegram: стекло обрамляет фото кольцом
            ToolbarItem(placement: .topBarTrailing) { headerAvatar }
        }
        .navigationDestination(isPresented: $showProfile) {
            ContactProfileView(recipientUserId: recipientUserId, recipientUsername: recipientUsername,
                               conversationId: conversationId)
        }
        .onReceive(NotificationCenter.default.publisher(for: .conversationDeleted)) { _ in
            dismiss()                                            // «удалить контакт» → закрыть чат (и профиль над ним)
        }
        .onReceive(presenceTimer) { _ in presenceTick += 1 }
        .onChange(of: pickedMedia) { items in
            guard !items.isEmpty else { return }
            stageMedia(items)
        }
        .alert(L("Не удалось отправить"), isPresented: .constant(mediaError != nil)) {
            Button("OK") { mediaError = nil }
        } message: {
            Text(mediaError ?? "")
        }
        .overlay(alignment: .bottom) {
            if uploadingMedia {
                // подготовка видео идёт секунды — без явного индикатора это выглядит как зависание
                HStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text(L("Подготовка…")).font(.caption).foregroundStyle(.white)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.black.opacity(0.7), in: Capsule())
                .padding(.bottom, 76)
            }
        }
        // Летящая копия отправленного — над всем экраном, включая поле ввода (см. SendFlight).
        // ⚠️ Без drawingGroup: стоит ему хоть раз отрисоваться в окне, долгое нажатие на сообщения
        // перестаёт открывать меню до перезапуска (подъём бабла начинается и замирает). Проверено на
        // стенде: и с постоянным прогревающим слоем, и после единственного полёта.
        .overlay { flightGhost }
        .overlay(alignment: .top) {
            if let toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColor.text)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .viewerGlass(Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: toast)
        .task { await loadHeader() }
        .task(id: conversationId) {                 // живой поток истории беседы из БД
            // трекер открытого чата: и на появлении экрана, и когда новый чат получил conversationId
            CurrentChat.shared.opened(peerUserId: recipientUserId, conversationId: conversationId)
            guard let cid = conversationId else { messages = []; return }

            // ⚠️ Синхронно и ДО любых await. Раньше лента сперва рисовалась пустой, потом ждала
            // сетевой reconcileStatuses и только затем получала историю — прокрутка позиционировалась
            // дважды: по пустому содержимому и по внезапно выросшему. Отсюда рывок с отскоком при
            // открытии. Заодно уходит пустой экран на время сетевого запроса: история и так лежит
            // в локальной базе, ждать сеть, чтобы её показать, незачем.
            messages = ChatStore.messages(conversationId: cid)
            DeliveredNotifications.clear(conversationId: cid)

            await viewModel.messaging.reconcileStatuses(conversationId: cid)   // один reconcile delivered на открытие
            for await rows in ChatStore.observe(conversationId: cid) { receive(rows) }
        }
        .onChange(of: messages) { _ in
            markRead()                                              // read-квитанция собеседнику (с дебаунсом)
            if let cid = conversationId {
                ReadStore.markRead(conversationId: cid)           // сбросить свой бейдж непрочитанных
                DeliveredNotifications.clear(conversationId: cid) // и убрать из шторки уведомления этого чата
            }
            securityWarning = SecurityEvents.hasIdentityChanged(recipientUserId)
        }
        .onAppear {
            // признак «мы внизу» — из фактического смещения ленты, меняется только на пороге
            feedScroll.onBottomChange = { bottom in
                atBottom = bottom
                if bottom { unreadBelow = 0 }
            }
            CurrentChat.shared.opened(peerUserId: recipientUserId, conversationId: conversationId)
            securityWarning = SecurityEvents.hasIdentityChanged(recipientUserId)
            blockStore.reload()                                   // актуализировать статус блокировки (локальный список)
            viewModel.presenceSubscribe(recipientUserId)          // статус собеседника, пока чат открыт
        }
        .onDisappear {
            CurrentChat.shared.closed(peerUserId: recipientUserId)
            viewModel.presenceUnsubscribe(recipientUserId)
            stopTyping()                                          // не оставляем собеседнику висящий «печатает…»
        }
        // вернулись в приложение, а этот чат так и открыт — его уведомления в шторке уже прочитаны
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if let cid = conversationId { DeliveredNotifications.clear(conversationId: cid) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pushNewMessage)) { _ in
            // NSE/другой процесс дописал в БД — ValueObservation это не ловит, перечитываем вручную
            if let cid = conversationId { messages = ChatStore.messages(conversationId: cid) }
        }
        .sheet(item: $forwardSource) { m in
            ForwardSheet(conversations: viewModel.conversations) { targets, comment in
                forward(m, to: targets, comment: comment)
            }
        }
        .alert(L("Удалить сообщение у всех?"),
               isPresented: Binding(get: { deleteCandidate != nil },
                                    set: { if !$0 { deleteCandidate = nil } })) {
            Button(L("Удалить у всех"), role: .destructive) {
                if let m = deleteCandidate { performDelete(m) }
                deleteCandidate = nil
            }
            Button(L("Отмена"), role: .cancel) { deleteCandidate = nil }
        } message: {
            Text(L("Это нельзя отменить."))
        }
        // Обычный алерт по центру экрана, а не confirmationDialog: тот на iOS 26 всплывает поповером
        // от точки нажатия и позиционируется у самой кромки сообщения.
        .alert(L("Сообщение не отправлено"),
               isPresented: Binding(get: { failedCandidate != nil },
                                    set: { if !$0 { failedCandidate = nil } }),
               presenting: failedCandidate) { m in
            Button(L("Отправить снова")) { retry(m); failedCandidate = nil }
            Button(L("Удалить"), role: .destructive) { performDelete(m); failedCandidate = nil }
            Button(L("Отмена"), role: .cancel) { failedCandidate = nil }
        }
        .sheet(isPresented: $showPicker) {
            MediaPickerSheet(caption: $pickerCaption,
                             maxCount: max(1, Self.maxMediaPerMessage - staged.count),
                             onSend: { sendPicked($0) },
                             onSystemPicked: { stageMedia($0) })
        }
        .fullScreenCover(item: $menuRequest) { request in
            MessageMenuView(request: request) { finishMenu($0) }
                .presentationBackground(.clear)
        }
        // Просмотрщик медиа — один на чат: листает все медиа переписки (см. MediaViewer).
        .environment(\.openMedia, { openMedia($0) })
        .environment(\.hiddenMediaKey, viewerHiddenKey)
        .fullScreenCover(item: $viewerRequest) { request in
            MediaViewer(request: request,
                        authorName: { $0.isMine ? L("Вы") : headerName },
                        onCurrentChange: { viewerHiddenKey = $0 },
                        onFinish: { finishViewer($0) })
                // фон прозрачный: при смахивании сквозь затемнение видна переписка, а анимации
                // открытия и закрытия просмотрщик рисует сам
                .presentationBackground(.clear)
        }
        .hideTabBar()                               // на экране чата таб-бар не показываем
    }

    // Открыть просмотрщик на миниатюре `key`. Листать можно всё медиа чата по порядку — как в
    // Telegram; файлы, которые ещё не скачаны, докачиваются уже в просмотрщике.
    private func openMedia(_ key: String) {
        var items: [MediaGalleryItem] = []
        for m in messages where m.kind == "media" {
            for (i, ref) in MediaRef.decodeList(m.text).enumerated() where !ref.isPending {
                items.append(MediaGalleryItem(key: MediaGalleryItem.key(m.id, i), ref: ref, message: m))
            }
        }
        guard let start = items.firstIndex(where: { $0.key == key }) else { return }

        inputFocused = false
        // ⚠️ Без системной анимации: вместо выезда снизу просмотрщик сам вырастает из миниатюры
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { viewerRequest = MediaViewerRequest(items: items, start: start) }
    }

    private func finishViewer(_ action: MediaViewerAction?) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            viewerRequest = nil
            viewerHiddenKey = nil
        }
        guard let action else { return }

        // Шит пересылки и алерт удаления — уже ПОСЛЕ того, как просмотрщик ушёл: показать их, пока
        // он ещё снимается с экрана, UIKit не даёт (тихо игнорирует).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            switch action {
            case .showInChat(let m): scrollTarget = m.id
            case .reply(let m): startReply(m)
            case .forward(let m): forwardSource = m
            case .delete(let m): deleteCandidate = m
            }
        }
    }

    // отправить read-квитанцию по последнему входящему (раз на новый входящий)
    private func markRead() {
        guard let cid = conversationId,
              let lastIncoming = messages.last(where: { !$0.isMine }) else { return }
        let upTo = lastIncoming.serverMessageId ?? lastIncoming.id
        guard upTo != lastReceiptedId else { return }
        lastReceiptedId = upTo
        Task {
            await viewModel.messaging.sendReadReceipt(conversationId: cid, recipientUserId: recipientUserId,
                                                      upToMessageId: upTo)
        }
    }


    // ===== шапка =====

    // Затемнение под статус-баром и шапкой: сплошное у самого верха, к низу шапки сходит на нет.
    // Высота — явная (статус-бар + шапка): отступ безопасной зоны тут не помощник, корень экрана
    // в iOS 26 и так начинается от верхнего края, и затемнение выходило полоской в 20 точек.
    private var topFade: some View {
        let bg = Color(uiColor: .systemBackground)
        let top = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.top }.first ?? 47

        return LinearGradient(stops: [.init(color: bg, location: 0),
                                      .init(color: bg.opacity(0.9), location: 0.5),
                                      .init(color: bg.opacity(0), location: 1)],
                              startPoint: .top, endPoint: .bottom)
            .frame(height: top + 70)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
    }

    private var headerCapsule: some View {
        let _ = presenceTick                              // заставить перерисовку по таймеру
        let isTyping = conversationId.map { typingStore.typing[$0] == true } ?? false
        let status = PresenceFormatter.text(presence.states[recipientUserId])

        return Button { showProfile = true } label: {
            VStack(spacing: 0) {
                Text(headerName)
                    .font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(AppColor.text)
                if isTyping {
                    Text(L("печатает…")).font(.caption).foregroundStyle(Self.sendTint)
                } else if !status.isEmpty {
                    Text(status)
                        .font(.caption).lineLimit(1)
                        .foregroundStyle(presence.states[recipientUserId]?.online == true ? Self.sendTint : AppColor.subtext)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 5)
            .frame(minHeight: 44)
            .frame(maxWidth: 230)
            .viewerGlass(Capsule())
            .contentShape(Capsule())
            .animation(.easeInOut(duration: 0.15), value: isTyping)
        }
        .buttonStyle(.plain)
    }

    private var headerAvatar: some View {
        Button { showProfile = true } label: {
            Group {
                if let image = contacts.byUser[recipientUserId]?.avatar {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Self.sendTint.opacity(0.85)
                        .overlay(Text(headerName.prefix(1).uppercased())
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white))
                }
            }
            // меньше кнопки панели — по краю остаётся кольцо системного стекла
            .frame(width: 36, height: 36)
            .clipShape(Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onAppear { contacts.ensure(recipientUserId) }
    }

    private var headerName: String {
        if !title.isEmpty { return title }
        if let name = contacts.byUser[recipientUserId]?.name, !name.isEmpty { return name }

        return "@\(recipientUsername)"
    }

    // ===== плашки и панель ввода =====
    // Вынесены из body намеренно: инлайном суммарная сложность вида переставала укладываться в лимит
    // вывода типов Swift, и компилятор падал с «unable to type-check this expression in reasonable
    // time», указывая при этом на случайную строку внутри.

    // Над текстом в поле ввода — на что отвечаем или что правим, как в Telegram: одной плашкой
    // ВНУТРИ поля, а не отдельной полосой над ним.
    @ViewBuilder private var composerHeader: some View {
        if let e = editingTarget {
            composerQuote(title: L("Изменение сообщения"), text: e.text, thumb: nil) {
                editingTarget = nil
                composer.text = ""
            }
        } else if let r = replyingTo {
            composerQuote(title: L("В ответ %@", authorName(r.senderUserId)), text: Self.quoteSnapshot(r),
                          thumb: r.kind == "media" ? MediaRef.decodeList(r.text).first.flatMap(MediaService.thumbnail) : nil) {
                replyingTo = nil
            }
        }
    }

    private func composerQuote(title: String, text: String, thumb: UIImage?,
                               onClose: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(Self.sendTint).frame(width: 3)
            if let thumb {
                Image(uiImage: thumb).resizable().scaledToFill()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Self.sendTint).lineLimit(1)
                Text(text).font(.subheadline).foregroundStyle(AppColor.subtext).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColor.subtext)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 12).padding(.trailing, 6).padding(.top, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // Прокрутка в самый низ — прямо у UIScrollView: в перевёрнутой ленте низ экрана — это начало
    // содержимого (смещение 0). UIKit сам гасит инерцию и анимирует ровно, без пересчёта SwiftUI.
    private func scrollToBottom(animated: Bool) {
        feedScroll.scrollToBottom(animated: animated)
        unreadBelow = 0
    }

    // Кнопка «вниз» (как в Telegram): появляется, когда низ ленты ушёл из виду, и показывает,
    // сколько пришло, пока читали историю.
    @ViewBuilder private var scrollDownButton: some View {
        Group {
            if !atBottom, !messages.isEmpty {
                Button {
                    unreadBelow = 0
                    scrollToBottom(animated: true)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AppColor.text)
                        .frame(width: 40, height: 40)
                        // Материал, а не полупрозрачная заливка из палитры: на тёмном фоне `surface`
                        // (белый 6%) практически неразличим, а кнопка обязана быть видна поверх
                        // произвольного содержимого — в том числе поверх фотографии.
                        .background(.regularMaterial, in: Circle())
                        .overlay(Circle().stroke(AppColor.stroke, lineWidth: 1))
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                        .overlay(alignment: .top) {
                            if unreadBelow > 0 {
                                Text(unreadBelow > 99 ? "99+" : "\(unreadBelow)")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .frame(minWidth: 20, minHeight: 20)
                                    .background(Self.sendTint, in: Capsule())
                                    .offset(y: -10)
                            }
                        }
                }
                .buttonStyle(.plain)
                .padding(.trailing, 14)
                .padding(.bottom, 10)
                .transition(.scale.combined(with: .opacity))
            }
        }
        // Анимация привязана к кнопке, а не к ленте: раньше она висела на ScrollView и заодно
        // анимировала всё, что менялось в ленте в тот же момент.
        .animation(.easeInOut(duration: 0.15), value: atBottom)
    }

    // Полоса выбранного (как в Telegram): миниатюры над полем ввода, пока набирается подпись.
    // Ячейка с индикатором = файл ещё готовится/заливается; отправить можно и раньше — сообщение
    // дождётся заливки само.
    @ViewBuilder private var stagedStrip: some View {
        // Во время отправки выбранное уже лежит баблом в ленте — полоса над полем была бы дублем
        if !staged.isEmpty, !sendingMedia {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(staged) { item in stagedCell(item) }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            // панель лежит поверх ленты — стекло, как и поле ввода под ней
            .viewerGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, 12).padding(.top, 8)
        }
    }

    private func stagedCell(_ item: StagedMedia) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumb = MediaService.thumbnail(item.ref) {
                    Image(uiImage: thumb).resizable().scaledToFill()
                } else {
                    // Кадр видео появляется только после экспорта из медиатеки — до него рисуем
                    // иконку по типу, иначе ячейка выглядела бы как сломанная картинка.
                    AppColor.fill
                        .overlay(Image(systemName: item.ref.isVideo ? "video.fill" : "photo.fill")
                            .foregroundStyle(AppColor.subtext))
                }
            }
            .frame(width: 58, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay { if item.ref.isPending { ProgressView().tint(.white) } }

            Button { dropStaged(item.id) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .padding(2)
        }
    }

    // Скрепка — системная стеклянная кнопка (iOS 26), круг высотой с однострочное поле.
    private var attachButton: some View {
        Button {
            pickerCaption = composer.text          // набранное в поле становится подписью — как в Telegram
            inputFocused = false
            showPicker = true
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(AppColor.text)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .glassCircleButton()
        // Пока отправка ждёт дозаливки, полосу трогать нельзя: выбранное в этот момент попало бы
        // в уже уходящее сообщение — и, не успев залиться, потерялось бы вместе с ним.
        // Флаг отдельный, а не `stagedRowId != nil`: строку в ленте может удалить `syncStagedRow`,
        // и тогда защита снялась бы посреди ещё не завершённой отправки.
        .disabled(uploadingMedia || sendingMedia)
    }

    // Форма поля ввода. НЕ Capsule: её радиус равен половине высоты, поэтому на многострочном тексте
    // скругление раздувалось вместе с полем и наезжало на первую и последнюю строки. Радиус
    // фиксирован и подобран так, что на одной строке форма неотличима от капсулы (высота ≈ 42),
    // а при росте поля остаётся прежней — как в Telegram.
    private static let inputShape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    // Поле ввода — стекло, кнопка отправки ВНУТРИ него справа внизу (как в Telegram). Появляется,
    // только когда есть что отправить; пустое поле целиком отдано тексту.
    private var messageField: some View {
        VStack(alignment: .leading, spacing: 0) {
            composerHeader
            ComposerTextRow(model: composer,
                            placeholder: staged.isEmpty ? L("Сообщение") : L("Подпись…"),
                            hasAttachments: !staged.isEmpty,
                            blocked: sending && conversationId == nil,
                            focus: $inputFocused,
                            frame: inputFrame,
                            onSend: { Task { await send() } },
                            onTextChange: { typingChanged() })
        }
        // обрезка — до стекла: плашка ответа выезжает изнутри поля, а блики стекла не срезаются
        .clipShape(Self.inputShape)
        .viewerGlass(Self.inputShape)
        // плашка ответа/правки выезжает и уходит пружиной, поле растёт вместе с ней
        .animation(.spring(response: 0.22, dampingFraction: 0.86), value: replyingTo?.id)
        .animation(.spring(response: 0.22, dampingFraction: 0.86), value: editingTarget?.id)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            attachButton
            messageField
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    // Тело ForEach вынесено в функцию: инлайном компилятор не укладывался в лимит вывода типов
    // (сообщение «unable to type-check this expression in reasonable time» указывало на разделитель дат,
    // хотя настоящая причина — суммарная сложность всей строки списка).
    private func entry(_ idx: Int, _ m: LocalMessage) -> some View {
        // Разделитель и сообщение — ОДНИМ блоком. В перевёрнутой ленте каждый ребёнок стека отражается
        // по отдельности, и порознь разделитель дат оказался бы ПОД своим сообщением, а не над ним.
        VStack(spacing: 8) {
            if idx == 0 || !Self.sameDay(messages[idx - 1].sentAt, m.sentAt) {
                dateSeparator(m.sentAt)          // разделитель дат (как в Telegram)
            }
            // Свайп справа налево → ответить, для ВСЕХ сообщений (как в Telegram). Слева направо на iOS 26
            // занят системным «назад» с любого места экрана. На записях о звонках выключен.
            SwipeToReply(enabled: m.kind != "call", mirrored: true, onReply: { startReply(m) }) {
                row(m)
            }
        }
        .id(m.id)
        // пока летит копия, настоящая строка на своём месте, но невидима
        .opacity(flight?.id == m.id ? 0 : 1)
    }

    // AnyView намеренно: с тремя ветвями opaque-тип строки стал таким, что вывод типов во всём
    // теле ForEach переставал сходиться за отведённое время. Стирание типа обрывает эту цепочку,
    // а цена на списке сообщений незаметна.
    private func row(_ m: LocalMessage) -> AnyView {
        if m.kind == "call" { return AnyView(callBubble(m)) }
        if m.kind == "media" {
            let refs = MediaRef.decodeList(m.text)
            // Медиа без единого файла — след сорвавшейся отправки. Такие строки уже лежат в базах
            // у пользователей сборки 33, и профилактика их не уберёт: без этой ветки чат у них
            // продолжит падать при каждом открытии.
            if refs.isEmpty { return AnyView(brokenMediaRow(m)) }

            return AnyView(mediaRow(m, refs))
        }

        return AnyView(bubble(m))
    }

    // Заглушка вместо пропавшего вложения: показывает подпись (её пользователь набирал руками —
    // молча стирать нельзя) и удаляется тапом.
    private func brokenMediaRow(_ m: LocalMessage) -> some View {
        HStack {
            Spacer(minLength: 40)
            Button { ChatStore.delete(localId: m.id) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(L("Файл не отправлен")).font(.callout)
                    }
                    .foregroundStyle(.red)
                    if let caption = m.caption, !caption.isEmpty {
                        Text(caption).font(.callout).foregroundStyle(AppColor.text)
                    }
                    Text(L("Нажмите, чтобы убрать")).font(.caption2).foregroundStyle(AppColor.subtext)
                }
                .padding(10)
                .background(Color.gray.opacity(0.2))
                .clipShape(Self.bubbleShape)
            }
            .buttonStyle(.plain)
        }
    }

    // системная запись «был звонок» (kind=="call", text — JSON CallLog): по центру, тап = перезвонить
    private func callBubble(_ m: LocalMessage) -> some View {
        let log = try? JSONDecoder().decode(CallLog.self, from: Data(m.text.utf8))
        let missed = !m.isMine && log?.outcome != "answered"    // пропущенный/отклонённый мной — красным
        return HStack {
            Spacer()
            Button { startCall(video: log?.isVideo == true) } label: {
                HStack(spacing: 6) {
                    Image(systemName: callIcon(log, isMine: m.isMine))
                    Text(log?.displayText(isMine: m.isMine) ?? L("Звонок"))
                    if let d = log?.durationSec, log?.outcome == "answered" {
                        Text("· \(CallLog.formatDuration(d))").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .foregroundStyle(missed ? Color.red : Color.secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.gray.opacity(0.12))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }

    private func callIcon(_ log: CallLog?, isMine: Bool) -> String {
        if log?.isVideo == true { return "video" }
        return isMine ? "phone.arrow.up.right" : "phone.arrow.down.left"
    }

    // ===== время сообщения и разделители дат (Telegram-style) =====
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "HH:mm"; return f
    }()
    static func timeText(_ sentAt: Int64) -> String {
        timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(sentAt) / 1000))
    }

    // общий детектор ссылок (создаётся один раз — NSDataDetector дорогой)
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    // подсветить и сделать кликабельными ссылки в тексте сообщения.
    // NSDataDetector ловит и «google.com» без схемы (подставит http). Тап открывает URL в Safari (SwiftUI Text + .link).
    // С кешем: поиск ссылок (NSDataDetector) по каждому видимому сообщению на каждой перерисовке
    // ленты был заметной частью «лагов» анимаций. Результат зависит только от текста и стороны.
    static func linkified(_ text: String, mine: Bool) -> AttributedString {
        let key = (mine ? "1" : "0") + text
        if let hit = linkCache.object(forKey: key as NSString) { return hit.value }
        let value = buildLinkified(text, mine: mine)
        linkCache.setObject(LinkifiedBox(value), forKey: key as NSString)

        return value
    }

    private final class LinkifiedBox {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    private static let linkCache: NSCache<NSString, LinkifiedBox> = {
        let c = NSCache<NSString, LinkifiedBox>()
        c.countLimit = 500
        return c
    }()

    private static func buildLinkified(_ text: String, mine: Bool) -> AttributedString {
        var attr = AttributedString(text)
        // Слово, которое не влезает в строку, переносится целиком («сооб-щение» не бывает) — как
        // в Telegram. SwiftUI Text расставляет переносы по словарю языка текста; «zxx» (ISO 639 —
        // «без языкового содержания») словаря не имеет, и переносов нет ни в русском, ни в английском.
        // ⚠️ Стиль абзаца с hyphenationFactor = 0 здесь не работает: Text его игнорирует (проверено).
        attr.languageIdentifier = "zxx"
        guard let detector = linkDetector, !text.isEmpty else { return attr }
        let ns = text as NSString
        for m in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let url = m.url, let r = Range(m.range, in: text),
                  let lo = AttributedString.Index(r.lowerBound, within: attr),
                  let hi = AttributedString.Index(r.upperBound, within: attr) else { continue }
            attr[lo..<hi].link = url                                   // Foundation-scope, тап открывает URL
            attr[lo..<hi].swiftUI.underlineStyle = .single             // .swiftUI — иначе неоднозначность с UIKit-scope
            attr[lo..<hi].swiftUI.foregroundColor = mine ? .white : .blue
        }
        return attr
    }
    // Выбранное из галереи попадает в полосу над полем ввода, а не улетает сразу: так к фото/видео
    // можно написать подпись. Заливка при этом стартует немедленно и идёт, пока пользователь печатает,
    // — иначе за подпись пришлось бы платить полным временем экспорта видео при нажатии «отправить».
    //
    // Несколько файлов уходят ОДНИМ сообщением (альбом), а не пачкой отдельных: так их видно сеткой
    // и они не разъезжаются по ленте, если какой-то залился медленнее.
    private func stageMedia(_ items: [PhotosPickerItem]) {
        pickedMedia = []
        inputFocused = true
        stage(items.map(PickedSource.item))
    }

    // Отправка из шторки выбора: файлы встают в ту же очередь подготовки и сразу уходят одним
    // сообщением с подписью из шторки. Бабл появляется в ленте немедленно, превью и индикаторы
    // заливки — уже в нём.
    private func sendPicked(_ assets: [PHAsset]) {
        guard !assets.isEmpty else { return }
        stage(assets.map(PickedSource.asset))
        composer.text = pickerCaption
        pickerCaption = ""
        Task { await sendStagedMedia() }
    }

    private func stage(_ sources: [PickedSource]) {
        guard !sources.isEmpty else { return }

        // Правка текста и вложение несовместимы: в поле лежит текст правимого сообщения, и он стал бы
        // подписью к фото. Реплай — сохраняем: цитата едет в том же payload, что и медиа
        // (sendStagedMedia её передаёт), как в Telegram.
        if editingTarget != nil { editingTarget = nil; composer.text = "" }

        // Типы известны синхронно, до какого-либо чтения — этого достаточно, чтобы показать полосу.
        let items = sources
        let kinds = sources.map(\.isVideo)
        let room = max(0, Self.maxMediaPerMessage - staged.count)
        guard room > 0 else {
            mediaError = "В одном сообщении не больше \(Self.maxMediaPerMessage) файлов"

            return
        }
        let accepted = Array(zip(items, kinds).prefix(room))

        let entries = accepted.map { pair in
            StagedMedia(ref: .pending(mime: pair.1 ? "video/mp4" : "image/jpeg",
                                      width: 4, height: 3, thumb: nil))
        }
        staged.append(contentsOf: entries)
        let ids = entries.map(\.id)

        // Задачи выстраиваем в цепочку, а не запускаем параллельно: несколько экспортов AVFoundation
        // разом упираются в память, а ожидание при отправке достаточно навесить на последнюю задачу.
        let previous = prepareTask
        prepareTask = Task {
            await previous?.value
            await prepareStaged(accepted, ids: ids)
        }
    }

    // Чтение, перекодирование, шифрование и заливка — по одному файлу. Всё на устройстве: сервер
    // получает готовые непрозрачные блобы и помочь ничем не может.
    private func prepareStaged(_ items: [(PickedSource, Bool)], ids: [UUID]) async {
        for (i, entry) in items.enumerated() {
            let (source, _) = entry
            let id = ids[i]
            guard staged.contains(where: { $0.id == id }) else { continue }   // ячейку убрали — не тратим время

            do {
                // Чтение видео — это экспорт ролика из медиатеки, десятки секунд. Поэтому полоса
                // (или бабл) показана ДО него, а не после.
                let loaded = await source.load()
                let movie = loaded?.movie
                let image = loaded?.image

                guard movie != nil || image != nil else {
                    dropStaged(id, reason: L("Не удалось прочитать файл"))
                    continue
                }

                // кадр/пропорции — в уже показанную ячейку, до заливки
                let preview = movie != nil
                    ? await MediaProcessor.quickVideoPreview(at: movie!)
                    : MediaProcessor.quickImagePreview(image!)
                updateStaged(id) { $0.ref = preview }

                guard staged.contains(where: { $0.id == id }) else {
                    if let movie { try? FileManager.default.removeItem(at: movie) }
                    continue
                }

                let prepared: MediaProcessor.Prepared
                if let movie {
                    prepared = try await MediaProcessor.prepareVideo(at: movie)
                    try? FileManager.default.removeItem(at: movie)
                } else {
                    prepared = try MediaProcessor.prepareImage(image!)
                }

                let uploaded = try await MediaService().upload(prepared)
                updateStaged(id) { $0.ref = uploaded }
            } catch MediaError.videoTooLong(let seconds) {
                dropStaged(id, reason: "Видео \(seconds) с — длиннее \(Int(MediaProcessor.maxVideoSeconds)) с")
            } catch MediaError.tooLarge {
                dropStaged(id, reason: L("Файл больше 25 МБ"))
            } catch {
                dropStaged(id, reason: error.localizedDescription)
            }
        }
    }

    private func updateStaged(_ id: UUID, _ change: (inout StagedMedia) -> Void) {
        guard let i = staged.firstIndex(where: { $0.id == id }) else { return }
        change(&staged[i])
        syncStagedRow()
    }

    // Незалившуюся ячейку убираем из полосы: оставлять её в сообщении нельзя — у получателя она
    // была бы вечной «загрузкой» в никуда.
    private func dropStaged(_ id: UUID, reason: String? = nil) {
        staged.removeAll { $0.id == id }
        if let reason { mediaError = reason }
        syncStagedRow()
    }

    // Если «отправить» уже нажали, а файлы ещё готовятся, бабл в ленте существует — держим его
    // содержимое в согласии с полосой, чтобы превью появлялись прямо в нём.
    //
    // ⚠️ Пустой список сюда записывать НЕЛЬЗЯ. Когда падала заливка последнего файла (сеть, слишком
    // большой файл, слишком длинное видео), в строку уходил `[]`, лента тут же перерисовывалась и
    // падала на медиа-бабле без единого элемента. Приложение умирало прямо внутри перерисовки — до
    // кода, который эту строку убирает, — и мёртвая строка оставалась в базе, роняя чат при каждом
    // открытии. Не осталось файлов — не осталось и сообщения.
    private func syncStagedRow() {
        guard let rowId = stagedRowId else { return }
        guard !staged.isEmpty else {
            ChatStore.delete(localId: rowId)
            stagedRowId = nil

            return
        }
        ChatStore.updateMediaPayload(localId: rowId, json: MediaRef.encodeList(staged.map(\.ref)))
    }

    // Отправка выбранного вместе с подписью. Бабл появляется в ленте сразу, даже если файлы ещё
    // заливаются: внутри крутятся индикаторы по ячейкам, а сообщение уйдёт, как только всё готово.
    private func sendStagedMedia() async {
        guard !staged.isEmpty else { return }   // отправлять нечего — пустая строка в ленте не нужна

        let caption = composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let reply = replyingTo.map { r in
            ReplyRef(messageId: r.serverMessageId ?? r.id,
                     authorUserId: r.senderUserId,
                     text: String(Self.quoteSnapshot(r).prefix(200)))
        }
        replyingTo = nil
        composer.text = ""
        stopTyping()
        sendingMedia = true
        defer { sendingMedia = false }

        let localId = UUID().uuidString
        var placed = false          // в новом чате бабл показать негде — беседы ещё нет

        if let cid = conversationId {
            ChatStore.add(LocalMessage(
                id: localId, conversationId: cid, senderUserId: AuthState.myUserId ?? "",
                isMine: true, text: MediaRef.encodeList(staged.map(\.ref)),
                sentAt: Int64(Date().timeIntervalSince1970 * 1000),
                status: .sending, serverMessageId: nil, kind: "media",
                replyToId: reply?.messageId,
                replyAuthorUserId: reply?.authorUserId,
                replyText: reply?.text,
                caption: caption.isEmpty ? nil : caption))
            stagedRowId = localId
            placed = true
        } else {
            uploadingMedia = true
        }

        await prepareTask?.value    // дожидаемся незавершённых заливок
        prepareTask = nil

        let ready = staged.map(\.ref).filter { !$0.isPending }
        staged = []
        stagedRowId = nil
        uploadingMedia = false

        guard !ready.isEmpty else {
            if placed { ChatStore.delete(localId: localId) }
            if mediaError == nil { mediaError = L("Не удалось отправить") }

            return
        }

        if placed { ChatStore.updateMediaPayload(localId: localId, json: MediaRef.encodeList(ready)) }

        do {
            let cid = try await viewModel.messaging.sendMedia(
                ready, caption: caption.isEmpty ? nil : caption, recipientUserId: recipientUserId,
                conversationId: conversationId, localId: localId, replyTo: reply)
            if conversationId == nil { conversationId = cid }
            await viewModel.loadConversations()
        } catch {
            // блобы уже на сервере → повтор пошлёт только сообщение и сработает
            if placed { ChatStore.markFailed(localId: localId) }
        }
    }

    // Разбито на две функции намеренно: со вложенным ветвлением внутри HStack/VStack компилятор
    // переставал укладываться в лимит вывода типов для всего тела ForEach.
    @ViewBuilder private func mediaContent(_ refs: [MediaRef], isMine: Bool) -> some View {
        if refs.count == 1 {
            MediaBubble(ref: refs[0], isMine: isMine)
        } else {
            MediaGroupBubble(refs: refs, isMine: isMine)
        }
    }

    private func mediaRow(_ m: LocalMessage, _ refs: [MediaRef]) -> some View {
        HStack {
            if m.isMine { Spacer(minLength: 40) }
            if m.isMine, m.status == .failed { failedBadge(m) }
            VStack(alignment: m.isMine ? .trailing : .leading, spacing: 4) {
                mediaHeader(m, refs)
                mediaBody(m, refs)
                    .environment(\.mediaMessageId, m.id)       // миниатюры знают своё сообщение → просмотрщик
                    // долгое нажатие на самой картинке открывает меню всего сообщения (см. MediaPress);
                    // рамку для меню записывает MessageLongPress ниже — она охватывает всё сообщение
                    .environment(\.messageLongPress) {
                        if let frame = MessageFrames.frames[m.id] { openMenu(m, frame: frame) }
                    }
            }
            // долгое нажатие — на всё сообщение целиком: медиа вместе с подписью и цитатой
            .modifier(MessageLongPress(id: m.id, enabled: true) { openMenu(m, frame: $0) })
            .opacity(menuHiddenId == m.id ? 0 : 1)
            if !m.isMine { Spacer(minLength: 40) }
        }
    }

    // Подпись «Переслано от …» и цитата — над самим медиа: врисовывать их в картинку негде,
    // а снизу они спорили бы с подписью к файлу.
    @ViewBuilder private func mediaHeader(_ m: LocalMessage, _ refs: [MediaRef]) -> some View {
        if m.forwardFromUserId != nil || m.replyText != nil {
            VStack(alignment: .leading, spacing: 3) {
                if let author = m.forwardFromUserId {
                    HStack(spacing: 4) {
                        Image(systemName: "arrowshape.turn.up.right")
                        Text(forwardCaption(author))
                    }
                    .font(.caption2).italic().foregroundStyle(.secondary)
                }
                if let quoted = m.replyText {
                    quoteBlock(m, quoted: quoted, onBubble: false)
                }
            }
            .frame(width: MediaLayout.width(refs), alignment: .leading)
        }
    }

    // Плашка «время + статус» поверх медиа: тёмная подложка — чтобы читалась на любом снимке.
    private func mediaStamp(_ m: LocalMessage) -> some View {
        HStack(spacing: 3) {
            Text(Self.timeText(m.sentAt)).font(.caption2.weight(.medium)).monospacedDigit()
            if m.isMine { statusView(m, onMedia: true) }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(.black.opacity(0.45), in: Capsule())
        .padding(6)
        .allowsHitTesting(false)      // тап по углу — всё ещё тап по фото
    }

    // Пункты меню сообщения (MessageMenuView). Один список на текст и медиа — различия внутри.
    private func menuItems(_ m: LocalMessage) -> [MessageMenuItem] {
        var items = [MessageMenuItem(title: L("Ответить"), icon: "arrowshape.turn.up.left") { startReply(m) }]
        if m.kind == "media" {
            if let caption = m.caption, !caption.isEmpty {
                items.append(MessageMenuItem(title: L("Копировать подпись"), icon: "doc.on.doc") {
                    UIPasteboard.general.string = caption
                })
            }
        } else {
            items.append(MessageMenuItem(title: L("Копировать"), icon: "doc.on.doc") { UIPasteboard.general.string = m.text })
            if m.editableNow {                                   // только своё, отправленное и не старше 48ч
                items.append(MessageMenuItem(title: L("Изменить"), icon: "pencil") { startEdit(m) })
            }
        }
        items.append(MessageMenuItem(title: L("Переслать"), icon: "arrowshape.turn.up.right") { forwardSource = m })
        if m.isMine {                                            // удалить у всех — только своё
            items.append(MessageMenuItem(title: L("Удалить у всех"), icon: "trash", destructive: true) { deleteCandidate = m })
        }

        return items
    }

    // Копия сообщения для меню — та же отрисовка, но вне перевёрнутой ленты и без жестов.
    private func menuPreview(_ m: LocalMessage) -> AnyView {
        if m.kind == "media" {
            let refs = MediaRef.decodeList(m.text)
            return AnyView(VStack(alignment: m.isMine ? .trailing : .leading, spacing: 4) {
                mediaHeader(m, refs)
                mediaBody(m, refs)
            })
        }

        return AnyView(textBubbleBody(m))
    }

    private func openMenu(_ m: LocalMessage, frame: CGRect) {
        inputFocused = false
        // реагировать можно только на ушедшее сообщение: реакция адресуется по серверному id
        let request = MessageMenuRequest(messageId: m.id, frame: frame, isMine: m.isMine,
                                         preview: menuPreview(m), items: menuItems(m),
                                         myReaction: myReaction(m),
                                         onReact: m.serverMessageId == nil ? nil : { toggleReaction(m, $0) })
        // ⚠️ Без системной анимации появления: меню анимируется само (см. MessageMenuView)
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            menuHiddenId = m.id
            menuRequest = request
        }
    }

    private func finishMenu(_ item: MessageMenuItem?) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            menuRequest = nil
            menuHiddenId = nil
        }
        // Действие — уже ПОСЛЕ ухода меню: шит пересылки и алерт удаления поверх снимающегося
        // экрана UIKit не показывает.
        guard let item else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { item.action() }
    }

    // Медиа с подписью — ОДНИМ баблом, как в Telegram: картинка сверху во всю ширину, под ней в
    // том же цветном фоне подпись со временем. Без подписи — голое медиа, время поверх картинки.
    @ViewBuilder private func mediaBody(_ m: LocalMessage, _ refs: [MediaRef]) -> some View {
        if let caption = m.caption, !caption.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                mediaContent(refs, isMine: m.isMine)
                    .environment(\.mediaCornerRadius, 0)
                captionBody(caption, m)
            }
            .frame(width: MediaLayout.width(refs))
            .background(bubbleFill(m))
            .overlay { highlightVeil(m) }                 // подсветка поверх картинки тоже
            .clipShape(Self.bubbleShape)
        } else {
            VStack(alignment: m.isMine ? .trailing : .leading, spacing: 4) {
                mediaContent(refs, isMine: m.isMine)
                    .overlay { highlightVeil(m).clipShape(RoundedRectangle(cornerRadius: 14)) }
                    .overlay(alignment: .bottomTrailing) { mediaStamp(m) }   // время поверх, в углу
                // без подписи реакциям внутри места нет — плашками под картинкой
                if !reactionGroups(m).isEmpty { reactionRow(m, onBubble: false) }
            }
        }
    }

    // Подпись со временем ВНУТРИ, в правом нижнем углу (как в Telegram). Место под время резервируется
    // невидимым хвостом той же ширины в конце текста: короткая подпись встаёт со временем в одну
    // строку, длинная — уступает ему место на последней.
    private func captionBody(_ caption: String, _ m: LocalMessage) -> some View {
        let mine = m.isMine

        let hasReactions = !reactionGroups(m).isEmpty

        return VStack(alignment: .leading, spacing: 6) {
            (Text(Self.linkified(caption, mine: mine)) + (hasReactions ? Text("") : stampReserve(m, edited: false)))
                .tint(mine ? .white : .blue)
                .fixedSize(horizontal: false, vertical: true)
            if hasReactions { reactionRow(m, onBubble: true, edited: false) }
        }
            .padding(.horizontal, 12).padding(.top, 7).padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(mine ? .white : .primary)
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 3) {
                    Text(Self.timeText(m.sentAt)).font(.caption2)
                    if mine { statusView(m, onMedia: true) }
                }
                .foregroundStyle(mine ? .white.opacity(0.8) : .secondary)
                .padding(.trailing, 11).padding(.bottom, 7)
            }
    }

    // Фиолетовый кнопки отправки. Задаём явно, а не через .accentColor: AccentColor в ассетах пустой,
    // и системный синий на тёмной теме выглядит чужеродно. Оттенок согласован с брендовым #7c3aed,
    // которым оформлена страница инвайт-ссылок (links.controller.ts).
    static let sendTint = Color(red: 0.48, green: 0.36, blue: 0.96)

    static func sameDay(_ a: Int64, _ b: Int64) -> Bool {
        Calendar.current.isDate(Date(timeIntervalSince1970: TimeInterval(a) / 1000),
                                inSameDayAs: Date(timeIntervalSince1970: TimeInterval(b) / 1000))
    }
    // «D MMMM» для текущего года, «D MMMM YYYY» для прошлых
    static func dateSeparatorText(_ sentAt: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(sentAt) / 1000)
        let cal = Calendar.current
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = cal.component(.year, from: date) == cal.component(.year, from: Date()) ? "d MMMM" : "d MMMM yyyy"
        return f.string(from: date)
    }
    private func dateSeparator(_ sentAt: Int64) -> some View {
        Text(Self.dateSeparatorText(sentAt))
            .font(.caption2).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(Color.gray.opacity(0.15))
            .clipShape(Capsule())
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
    }

    private func bubble(_ m: LocalMessage) -> some View {
        HStack {
            if m.isMine { Spacer(minLength: 48) }
            if m.isMine, m.status == .failed { failedBadge(m) }
            textBubbleBody(m)
                .modifier(LandingProbe(active: flight?.id == m.id) { landed(m.id, at: $0) })
                // двойное нажатие — быстрая ❤️ (как в Telegram). simultaneous: не мешает прокрутке,
                // долгому нажатию и тапу по ссылке/цитате. Только текст — на медиа одиночный тап
                // открывает просмотр, и ожидание второго нажатия заметно бы его тормозило.
                .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { quickHeart(m, at: $0.location) })
                .overlay(alignment: .topLeading) {
                    if let spot = heartBurst, spot.messageId == m.id {
                        HeartBurst(spot: spot) { if heartBurst?.id == spot.id { heartBurst = nil } }
                    }
                }
                .modifier(MessageLongPress(id: m.id, enabled: true) { openMenu(m, frame: $0) })
                .opacity(menuHiddenId == m.id ? 0 : 1)
            if !m.isMine { Spacer(minLength: 48) }
        }
    }

    // Скругление баблов. Радиус меньше половины высоты однострочного бабла (~42), поэтому он не
    // превращается в капсулу и одинаково выглядит на одной строке и на десяти.
    static let bubbleShape = RoundedRectangle(cornerRadius: 18, style: .continuous)
    static let bubbleInsets = EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)

    // Сама цветная плашка текстового сообщения — отдельно, потому что нужна дважды: в ленте и
    // как явное превью контекстного меню.
    //
    // `formed` — для вылета из поля ввода. На старте это просто текст, как он стоял в поле: без
    // подложки и цветом поля. В полёте подложка проступает и разрастается от самого текста до
    // полного размера, а текст перекрашивается в цвет бабла. Так бабл не возникает целиком в поле
    // ввода, а складывается по дороге.
    private func textBubbleBody(_ m: LocalMessage, formed: CGFloat = 1, size: CGSize? = nil) -> some View {
        // С какого масштаба подложка начинает расти: на старте её края совпадают с текстом (отступы
        // «съедены»), к концу — с краями бабла.
        let sx = size.map { $0.width > 0 ? max(0, 1 - 2 * Self.bubbleInsets.leading / $0.width) : 1 } ?? 1
        let sy = size.map { $0.height > 0 ? max(0, 1 - 2 * Self.bubbleInsets.top / $0.height) : 1 } ?? 1

        return
        VStack(alignment: .leading, spacing: 6) {
            // подпись пересланного (Telegram-style)
            if let author = m.forwardFromUserId {
                HStack(spacing: 4) {
                    Image(systemName: "arrowshape.turn.up.right")
                    Text(forwardCaption(author))
                }
                .font(.caption2).italic()
                .opacity(0.75)
            }
            // цитата (реплай): снапшот автора/текста; тап — к оригиналу, если он есть локально
            if let quoted = m.replyText {
                // Не Button: кнопка перехватывает НАЧАЛО перетаскивания, и свайп-ответ по
                // сообщению с цитатой не начинался вовсе. Обычный тап такого не делает.
                quoteBlock(m, quoted: quoted, onBubble: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Невидимый хвост резервирует место под время в конце текста — как у подписи к медиа
            // (captionBody): короткое сообщение встаёт со временем в одну строку, длинное уступает
            // ему место на последней.
            //
            // С реакциями время уезжает на их строку (как в Telegram), и хвост в тексте не нужен.
            let hasReactions = !reactionGroups(m).isEmpty
            (Text(Self.linkified(m.text, mine: m.isMine)) + (hasReactions ? Text("") : stampReserve(m)))
                .tint(m.isMine ? .white : .blue)                 // цвет тапабельных ссылок
                .fixedSize(horizontal: false, vertical: true)   // не схлопывать в 1 строку рядом с цитатой (maxWidth:.infinity)
            if hasReactions {
                reactionRow(m, onBubble: true)
            }
        }
        .padding(Self.bubbleInsets)
        .overlay(alignment: .bottomTrailing) {
            bubbleStamp(m)
                .padding(.trailing, Self.bubbleInsets.trailing - 1).padding(.bottom, 7)
                .opacity(formed)                                 // в полёте проступает вместе с подложкой
        }
        .foregroundStyle(m.isMine && formed > 0 ? Color.white : AppColor.text)
        .background {
            // ⚠️ Рост — масштабом, а НЕ отступами. Отступы меняют раскладку, а раскладочная анимация
            // отстаёт от сдвига (тот чисто визуальный) на кадр: подложка заметно волочилась за
            // текстом. Масштаб, как и сдвиг, — эффект отрисовки, они идут кадр в кадр.
            Self.bubbleShape
                .fill(bubbleFill(m))
                .scaleEffect(x: sx + (1 - sx) * formed, y: sy + (1 - sy) * formed)
                .opacity(formed)
        }
        .contentShape(Self.bubbleShape)
    }

    // ===== цитата ответа =====

    // Как в Telegram: цветная полоса, миниатюра (если отвечали на фото/видео), имя автора цветом
    // и снимок текста. `onBubble` — внутри своего цветного облачка (там всё белое).
    private func quoteBlock(_ m: LocalMessage, quoted: String, onBubble: Bool) -> some View {
        let onBrand = onBubble && m.isMine
        let accent: Color = onBrand ? .white : Self.sendTint

        return HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(accent).frame(width: 3)
            if let thumb = quoteThumbnail(m) {
                Image(uiImage: thumb).resizable().scaledToFill()
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(authorName(m.replyAuthorUserId))
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                    .foregroundStyle(accent)
                Text(quoted)
                    .font(.subheadline).lineLimit(1)
                    .foregroundStyle(onBrand ? Color.white.opacity(0.8) : AppColor.subtext)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 0).padding(.trailing, 10).padding(.vertical, 6)
        .fixedSize(horizontal: false, vertical: true)
        .background(accent.opacity(onBrand ? 0.15 : 0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        // Не Button: кнопка перехватывает НАЧАЛО перетаскивания, и свайп-ответ по
        // сообщению с цитатой не начинался вовсе. Обычный тап такого не делает.
        .modifier(TapOrMenuPress(messageId: m.id, onTap: { jumpToOriginal(m.replyToId) }, onMenu: {
            if let frame = MessageFrames.frames[m.id] { openMenu(m, frame: frame) }
        }))
    }

    // Миниатюра цитируемого медиа — из ЛОКАЛЬНОЙ копии оригинала (его превью лежит в payload).
    // Отдельного поля в ReplyRef нет сознательно: картинка раздула бы каждое сообщение-ответ,
    // а в личном чате оригинал почти всегда есть у обоих. Нет оригинала — цитата просто без картинки.
    private func quoteThumbnail(_ m: LocalMessage) -> UIImage? {
        guard let target = m.replyToId,
              let original = messages.first(where: { $0.serverMessageId == target || $0.id == target }),
              original.kind == "media",
              let ref = MediaRef.decodeList(original.text).first else { return nil }

        return MediaService.thumbnail(ref)
    }

    // ===== подсветка найденного сообщения =====

    // Как в Telegram: перешли по цитате или «Показать в чате» — облачко найденного сообщения
    // вспыхивает другим цветом и плавно возвращается к обычному. Иначе среди соседей не понять,
    // какое из них имелось в виду.
    private func flashHighlight(_ id: String) {
        // вспыхиваем, когда прокрутка почти доехала, — иначе подсветка прошла бы за кадром
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.easeOut(duration: 0.15)) { highlightedId = id }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                guard highlightedId == id else { return }     // успели перейти к другому
                withAnimation(.easeInOut(duration: 0.6)) { highlightedId = nil }
            }
        }
    }

    // Цвет облачка: обычный или подсвеченный. Свои — синий светлеет, чужие — серый уходит в фирменный.
    private func bubbleFill(_ m: LocalMessage) -> Color {
        let lit = highlightedId == m.id
        if m.isMine { return lit ? Color(red: 0.66, green: 0.58, blue: 1) : Self.sendTint }

        return lit ? Self.sendTint.opacity(0.45) : Color.gray.opacity(0.2)
    }

    // У медиа фон закрыт картинкой — подсвечиваем полупрозрачной вуалью поверх
    private func highlightVeil(_ m: LocalMessage) -> some View {
        (m.isMine ? Color.white : Self.sendTint)
            .opacity(highlightedId == m.id ? 0.35 : 0)
            .allowsHitTesting(false)
    }

    // ===== реакции =====

    private struct ReactionGroup: Identifiable {
        let emoji: String
        var count: Int
        var mine: Bool
        var id: String { emoji }
    }

    // Реакции сообщения по эмодзи, в порядке появления (первая поставленная — первой).
    private func reactionGroups(_ m: LocalMessage) -> [ReactionGroup] {
        let me = AuthState.myUserId ?? ""
        var groups: [ReactionGroup] = []
        for r in m.reactionList.sorted(by: { $0.at < $1.at }) {
            guard let e = r.emoji else { continue }
            if let i = groups.firstIndex(where: { $0.emoji == e }) {
                groups[i].count += 1
                groups[i].mine = groups[i].mine || r.userId == me
            } else {
                groups.append(ReactionGroup(emoji: e, count: 1, mine: r.userId == me))
            }
        }

        return groups
    }

    private func myReaction(_ m: LocalMessage) -> String? {
        let me = AuthState.myUserId ?? ""

        return m.reactionList.first { $0.userId == me }?.emoji
    }

    // Двойное нажатие: ❤️ стоит — снять, стоит другая моя реакция или никакой — поставить ❤️
    // (та же логика, что у toggleReaction). Вспышка — только когда ставим.
    private func quickHeart(_ m: LocalMessage, at location: CGPoint) {
        guard m.serverMessageId != nil else { return }   // неотправленное: реагировать не на что
        let heart = "❤️"
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if myReaction(m) != heart { heartBurst = HeartBurst.Spot(messageId: m.id, location: location) }
        toggleReaction(m, heart)
    }

    // Как в Telegram: та же реакция ещё раз — снять, другая — заменить прежнюю.
    private func toggleReaction(_ m: LocalMessage, _ emoji: String) {
        guard let sid = m.serverMessageId, let cid = conversationId else { return }
        let next: String? = myReaction(m) == emoji ? nil : emoji
        Task {
            await viewModel.messaging.sendReaction(targetServerMessageId: sid, emoji: next,
                                                   recipientUserId: recipientUserId, conversationId: cid)
        }
    }

    // Строка плашек. Внутри бабла справа резервирует место под время (оно рисуется поверх, в углу);
    // `onBubble == false` — под медиа без подписи, на фоне переписки.
    private func reactionRow(_ m: LocalMessage, onBubble: Bool, edited: Bool? = nil) -> some View {
        HStack(spacing: 6) {
            ForEach(reactionGroups(m)) { g in
                Button { toggleReaction(m, g.emoji) } label: {
                    HStack(spacing: 4) {
                        Text(g.emoji).font(.system(size: 15))
                        if g.count > 1 {
                            Text("\(g.count)").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        }
                    }
                    .foregroundStyle(chipText(g, m, onBubble))
                    .padding(.horizontal, 9).frame(height: 28)
                    .background(chipFill(g, m, onBubble), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
            if onBubble { stampReserve(m, edited: edited) }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: m.reactions)
    }

    // своя реакция — залитая плашка, чужая — полупрозрачная (как в Telegram)
    private func chipFill(_ g: ReactionGroup, _ m: LocalMessage, _ onBubble: Bool) -> Color {
        if onBubble && m.isMine { return g.mine ? .white : .white.opacity(0.22) }
        if onBubble { return g.mine ? Self.sendTint : Self.sendTint.opacity(0.2) }

        return g.mine ? Self.sendTint : AppColor.fill
    }

    private func chipText(_ g: ReactionGroup, _ m: LocalMessage, _ onBubble: Bool) -> Color {
        if onBubble && m.isMine { return g.mine ? Self.sendTint : .white }

        return g.mine ? .white : AppColor.text
    }

    // «изменено · время · галочки» в правом нижнем углу текстового бабла, как в Telegram
    private func bubbleStamp(_ m: LocalMessage) -> some View {
        HStack(spacing: 3) {
            if m.editedAt != nil { Text(L("изменено")).font(.caption2) }
            Text(Self.timeText(m.sentAt)).font(.caption2).monospacedDigit()
            // на синем бабле серые и синие галочки не читаются — белые, как на медиа
            if m.isMine { statusView(m, onMedia: true) }
        }
        .foregroundStyle(m.isMine ? Color.white.opacity(0.75) : AppColor.subtext)
        .allowsHitTesting(false)
    }

    // Невидимая заглушка под bubbleStamp — дописывается в конец текста, чтобы последняя строка
    // уступила место времени. Собрана из ТЕХ ЖЕ кусков (тот же шрифт, цифры, сами значки галочек),
    // а не из пробелов «на глаз»: пробелы оказались уже двух галочек, и строка, заканчивавшаяся
    // впритык, залезала под время. Галочки в заглушке — всегда две (самый широкий статус),
    // пробелы-разделители шире промежутков в самом штампе: запас лучше наезда.
    private func stampReserve(_ m: LocalMessage, edited: Bool? = nil) -> Text {
        var t = Text("\u{2003}")
        if edited ?? (m.editedAt != nil) { t = t + Text(L("изменено") + "\u{2002}") }
        t = t + Text(Self.timeText(m.sentAt)).monospacedDigit()
        if m.isMine {
            t = t + Text("\u{2002}") + Text(Image(systemName: "checkmark")) + Text(Image(systemName: "checkmark"))
        }

        return t.font(.caption2).foregroundColor(.clear)
    }

    // имя автора цитаты: DIRECT-чат — либо я, либо собеседник
    private func authorName(_ userId: String?) -> String {
        guard let userId else { return "" }
        if userId == AuthState.myUserId { return L("Вы") }
        return headerName
    }

    // подпись пересланного: автор оригинала может быть третьей стороной — резолвим что можем
    private func forwardCaption(_ authorUserId: String) -> String {
        if authorUserId == AuthState.myUserId { return L("Переслано от вас") }
        if authorUserId == recipientUserId { return "Переслано от \(headerName)" }
        if let name = ContactProfileStore.load(authorUserId)?.name { return "Переслано от \(name)" }
        return L("Переслано")
    }

    private func startReply(_ m: LocalMessage) {
        guard m.kind != "call" else { return }      // на записи о звонках не отвечаем
        editingTarget = nil                          // режимы взаимоисключающие
        replyingTo = m
        inputFocused = true
        // ⚠️ Без дополнительной прокрутки к сообщению. Раньше через 0,35 с лента ещё и ехала к нему —
        // третье движение поверх возврата облачка и подъёма клавиатуры, отсюда рывки. Перевёрнутая
        // лента и так держит низ при подъёме клавиатуры, а то, на что отвечаешь, видно в плашке.
    }

    // Текст цитаты для плашки и для снимка в сообщении. У медиа в `text` лежит JSON MediaRef —
    // подставлять его нельзя: в цитате оказался бы base64 миниатюры вместо человеческой подписи.
    static func quoteSnapshot(_ m: LocalMessage) -> String {
        guard m.kind == "media" else { return m.text }
        if let caption = m.caption, !caption.isEmpty { return caption }
        let refs = MediaRef.decodeList(m.text)
        if refs.count > 1 { return Plural.files(refs.count) }

        return refs.first?.isVideo == true ? L("Видео") : L("Фото")
    }

    private func startEdit(_ m: LocalMessage) {
        guard m.editableNow else { return }          // своё, отправленное, не старше 48ч
        replyingTo = nil                             // режимы взаимоисключающие
        editingTarget = m
        composer.text = m.text                               // правим существующий текст
        inputFocused = true
    }

    // переслать в другой чат: копия текста с атрибуцией ОРИГИНАЛЬНОГО автора
    // (пересылка пересланного сохраняет исходного автора, как в Telegram)
    // Можно сразу в несколько чатов; комментарий уходит в каждый ПЕРЕД пересланным, как в Telegram.
    private func forward(_ m: LocalMessage, to targets: [ConversationItem], comment: String) {
        forwardSource = nil
        let author = m.forwardFromUserId ?? m.senderUserId
        // Пересылаем ТОТ ЖЕ MediaRef: блоб уже лежит на сервере зашифрованным, ключ едет внутри
        // сообщения. Перезаливать файл незачем — новый получатель скачает тот же.
        // ⚠️ Обратная сторона: если серверный TTL истёк, у него останется одна миниатюра.
        let refs = m.kind == "media" ? MediaRef.decodeList(m.text).filter { !$0.isPending } : []
        if m.kind == "media", refs.isEmpty {
            mediaError = L("Файл больше недоступен — переслать нечего.")

            return
        }

        Task {
            var forwarded = 0
            for target in targets {
                guard let toUserId = target.otherUser?.userId else { continue }
                let cid = target.conversationId
                do {
                    if !comment.isEmpty {
                        _ = try await viewModel.messaging.sendText(comment, recipientUserId: toUserId,
                                                                   conversationId: cid)
                    }
                    if m.kind == "media" {
                        // ⚠️ Строку в ленте целевого чата кладём САМИ: sendMedia при известной беседе
                        // считает, что заготовка уже стоит (так устроена обычная отправка), и только
                        // ставит сообщение в очередь. Без этой строки пересланное уходило собеседнику,
                        // но у отправителя не появлялось нигде — выглядело, будто пересылка не работает.
                        let localId = UUID().uuidString
                        ChatStore.add(LocalMessage(
                            id: localId, conversationId: cid, senderUserId: AuthState.myUserId ?? "",
                            isMine: true, text: MediaRef.encodeList(refs),
                            sentAt: Int64(Date().timeIntervalSince1970 * 1000),
                            status: .sending, serverMessageId: nil, kind: "media",
                            forwardFromUserId: author, caption: m.caption))
                        _ = try await viewModel.messaging.sendMedia(
                            refs, caption: m.caption, recipientUserId: toUserId,
                            conversationId: cid, localId: localId, forwardFrom: author)
                    } else {
                        _ = try await viewModel.messaging.sendText(m.text, recipientUserId: toUserId,
                                                                   conversationId: cid, forwardFrom: author)
                    }
                    forwarded += 1
                } catch {
                    viewModel.errorMessage = error.localizedDescription
                }
            }
            // Подтверждение, как в Telegram: без него было непонятно, ушло ли пересланное.
            // Сообщение к этому моменту в очереди отправки — дойдёт и при плохой связи (OutboxWorker).
            if forwarded > 0 {
                let name = targets.count == 1
                    ? targets.first?.otherUser.map { ContactProfileCache.shared.byUser[$0.userId]?.name ?? "@\($0.username)" }
                    : nil
                showToast(name.map { L("Переслано: %@", $0) } ?? L("Переслано в чаты: %@", String(forwarded)))
            }
            await viewModel.loadConversations()
        }
    }

    private func showToast(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if toast == text { toast = nil }
        }
    }

    // удалить у всех: неотправленное (нет serverMessageId) стираем только локально —
    // до сервера оно не дошло, собеседник его и не видел
    private func performDelete(_ m: LocalMessage) {
        if editingTarget?.id == m.id { editingTarget = nil; composer.text = "" }
        if replyingTo?.id == m.id { replyingTo = nil }
        guard let sid = m.serverMessageId, let cid = conversationId else {
            ChatStore.delete(localId: m.id)
            return
        }
        Task {
            await viewModel.messaging.sendDelete(targetServerMessageId: sid,
                                                 recipientUserId: recipientUserId, conversationId: cid)
        }
    }

    private func jumpToOriginal(_ replyToId: String?) {
        guard let target = replyToId,
              let localId = messages.first(where: { $0.serverMessageId == target || $0.id == target })?.id
        else { return }                             // оригинала нет локально — цитата всё равно читабельна
        scrollTarget = localId
    }

    // индикатор статуса для своих сообщений
    // `onMedia` — поверх картинки или цветной подложки: там серый и синий не читаются, поэтому
    // галочки белые (прочитано — непрозрачные, остальное приглушено), а вместо кнопки повтора — значок.
    @ViewBuilder
    private func statusView(_ m: LocalMessage, onMedia: Bool = false) -> some View {
        let dim: Color = onMedia ? .white.opacity(0.75) : .secondary
        switch m.status {
        case .sending:
            Image(systemName: "clock").font(.caption2).foregroundStyle(dim)
        // Как в Telegram: одна галочка — отправлено (в том числе уже доставлено на устройство),
        // две — прочитано. Раньше «доставлено» тоже рисовалось двумя галочками, и на синем бабле,
        // где все галочки белые, прочитанное было не отличить от непрочитанного.
        case .sent, .delivered:
            Image(systemName: "checkmark").font(.caption2).foregroundStyle(dim)
        case .read:
            checks(onMedia ? .white : .blue)
        case .failed:
            // о сбое говорит красный кружок рядом с облачком (failedBadge) — внутри штампа пусто
            EmptyView()
        }
    }

    // Неотправленное — как в Telegram: красный кружок «!» слева от облачка вместо надписи под ним.
    // Тап — выбор «Отправить снова» / «Удалить».
    private func failedBadge(_ m: LocalMessage) -> some View {
        Button { failedCandidate = m } label: {
            Image(systemName: "exclamationmark")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.red, in: Circle())
                .frame(width: 32, height: 32)        // зона нажатия больше самого кружка
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .transition(.scale.combined(with: .opacity))
        .accessibilityLabel(L("Не отправлено"))
    }

    private func checks(_ color: Color) -> some View {   // двойная галочка
        HStack(spacing: -3) {
            Image(systemName: "checkmark")
            Image(systemName: "checkmark")
        }
        .font(.caption2)
        .foregroundStyle(color)
    }

    private func startCall(video: Bool) {
        CallManager.shared.startCall(calleeUserId: recipientUserId,
                                     calleeName: headerName, video: video)
    }

    private func loadHeader() async {
        // имя контакта, если уже знаем его Profile Key (иначе остаётся @ник)
        if let card = try? await users.card(recipientUserId), let name = users.contactName(card) {
            serverTitle = name
        }
    }

    private func send() async {
        // есть вложения — уходит медиа-сообщение, а набранный текст становится подписью к нему
        if !staged.isEmpty {
            await sendStagedMedia()

            return
        }

        let text = composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // режим редактирования: вместо нового сообщения шлём type:"edit" (silent+ephemeral)
        if let target = editingTarget, let sid = target.serverMessageId, let cid = conversationId {
            editingTarget = nil
            composer.text = ""
            stopTyping()
            guard text != target.text else { return }   // ничего не поменяли — не шлём
            guard target.editableNow else {             // окно 48ч истекло, пока правили
                viewModel.errorMessage = L("Сообщение старше 48 часов — редактировать нельзя")
                return
            }
            await viewModel.messaging.sendEdit(targetServerMessageId: sid, newText: text,
                                               recipientUserId: recipientUserId, conversationId: cid)
            return
        }

        // цитата: серверный id (или локальный, если оригинал ещё летит), автор, снапшот ≤200 символов
        let reply = replyingTo.map { r in
            ReplyRef(messageId: r.serverMessageId ?? r.id,
                     authorUserId: r.senderUserId,
                     text: String(Self.quoteSnapshot(r).prefix(200)))
        }
        replyingTo = nil
        // Полёт — только если лента у конца: из истории он бы стартовал в одну точку, а ленту при
        // этом ещё и повезло бы вниз. Telegram в этом случае тоже просто прокручивает.
        if atBottom, conversationId != nil, !reduceMotion, inputFrame.rect != .zero {
            flight = SendFlight(text: text, from: inputFrame.rect)
        }
        composer.text = ""; sending = true
        stopTyping()                        // отправили — «печатает…» больше не актуально
        defer { sending = false }
        await doSend(text, replyTo: reply)
    }

    // Новый снимок истории из БД. Если это наше только что отправленное — запускаем полёт.
    private func receive(_ rows: [LocalMessage]) {
        // Читаем историю, а снизу пришло новое: в перевёрнутой ленте оно встаёт в НАЧАЛО содержимого
        // и сдвинуло бы всё видимое. FeedScroll компенсирует сдвиг в том же проходе раскладки.
        if !atBottom, rows.count > messages.count, let last = rows.last, !last.isMine,
           !messages.contains(where: { $0.id == last.id }) {
            feedScroll.holdPositionForInsert()
        }
        if var f = flight, f.id == nil, let last = rows.last, last.isMine, last.text == f.text,
           !messages.contains(where: { $0.id == last.id }) {
            f.id = last.id
            f.message = last
            flight = f
            withAnimation(Self.flySpring) { messages = rows }   // соседи плавно уступают место

            // Страховка: строка так и не разложилась (ушла из ленты, лента пересоздалась) — без неё
            // она осталась бы невидимой навсегда.
            let id = last.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if flight?.id == id { flight = nil }
            }

            return
        }
        messages = rows
    }

    // Бабл летящего сообщения разложен — считаем, на сколько сдвинуть его к полю ввода, и отпускаем.
    private func landed(_ id: String, at frame: CGRect) {
        guard var f = flight, f.id == id, frame.width > 0 else { return }
        var t = Transaction(); t.disablesAnimations = true

        // Строка сдвинулась уже в полёте (лента доезжает, сворачивается плашка ответа) — копия
        // следует за ней, иначе приземлилась бы мимо и строка проявилась бы рывком.
        if f.ready {
            f.target = frame
            withTransaction(t) { flight?.target = frame }
            return
        }

        // Совмещаем ТЕКСТ, а не рамки: у поля отступы 16 по бокам и 10 сверху, у бабла 12 и 10.
        // Тогда кажется, что улетает ровно то, что было набрано.
        f.offset = CGSize(width: f.from.minX + 16 - Self.bubbleInsets.leading - frame.minX,
                          height: f.from.minY - frame.minY)
        f.target = frame
        f.ready = true
        withTransaction(t) { flight = f }

        DispatchQueue.main.async {
            withAnimation(Self.flyForm) { flight?.formed = 1 }
            withAnimation(Self.flyMove) { flight?.offset = .zero } completion: {
                if flight?.id == id { flight = nil }
            }
        }
    }

    // Копия летящего бабла (см. SendFlight). Координаты — оконные, а оверлей живёт в своих, поэтому
    // начало оверлея вычитается.
    @ViewBuilder private var flightGhost: some View {
        if let f = flight, f.ready, let m = f.message, let target = f.target {
            GeometryReader { geo in
                let origin = geo.frame(in: .global).origin
                HStack {
                    if m.isMine { Spacer(minLength: 0) }
                    textBubbleBody(m, formed: f.formed, size: target.size)
                    if !m.isMine { Spacer(minLength: 0) }
                }
                .frame(width: target.width, height: target.height)
                .position(x: target.midX - origin.x, y: target.midY - origin.y)
                .offset(f.offset)
            }
            .allowsHitTesting(false)
        }
    }

    // «печатает…» → собеседнику. "start" троттлим (не чаще раза в 4с), "stop" — при очистке поля.
    private func typingChanged() {
        guard let cid = conversationId else { return }        // в новом чате беседы ещё нет — не шлём
        let empty = composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if empty { stopTyping(); return }
        guard Date().timeIntervalSince(lastTypingSentAt) > 4 else { return }
        typingActive = true
        lastTypingSentAt = Date()
        Task { await viewModel.messaging.sendTyping(state: "start", recipientUserId: recipientUserId, conversationId: cid) }
    }

    private func stopTyping() {
        guard typingActive, let cid = conversationId else { return }
        typingActive = false
        lastTypingSentAt = .distantPast
        Task { await viewModel.messaging.sendTyping(state: "stop", recipientUserId: recipientUserId, conversationId: cid) }
    }

    // повтор отправки упавшего сообщения: удаляем failed-строку и шлём заново (цитату восстанавливаем из строки)
    // Повтор отправки. ВАЖНО ветвиться по kind: у медиа в `text` лежит JSON MediaRef с base64-миниатюрой,
    // и отправка его как текста давала гигантский бабл с кодом вместо картинки.
    private func retry(_ m: LocalMessage) {
        if m.kind == "media" {
            Task { await retryMedia(m) }

            return
        }

        ChatStore.delete(localId: m.id)
        let reply = m.replyToId.map {
            ReplyRef(messageId: $0, authorUserId: m.replyAuthorUserId ?? "", text: m.replyText ?? "")
        }
        Task { await doSend(m.text, replyTo: reply) }
    }

    private func retryMedia(_ m: LocalMessage) async {
        // Заготовка без attachmentId означает, что файл так и не залился. Исходник к этому моменту
        // уже удалён из временной папки, повторять нечего — честнее убрать строку и попросить выбрать
        // заново, чем оставлять кнопку, которая всегда будет падать.
        let ready = MediaRef.decodeList(m.text).filter { !$0.isPending }
        guard !ready.isEmpty else {
            ChatStore.delete(localId: m.id)
            mediaError = L("Файл не загрузился. Выберите его ещё раз.")

            return
        }

        // Блоб уже на сервере — повторяем только отправку сообщения, заново заливать не нужно.
        ChatStore.delete(localId: m.id)
        let localId = UUID().uuidString
        ChatStore.add(LocalMessage(
            id: localId, conversationId: m.conversationId, senderUserId: m.senderUserId,
            isMine: true, text: m.text, sentAt: Int64(Date().timeIntervalSince1970 * 1000),
            status: .sending, serverMessageId: nil, kind: "media", caption: m.caption))

        // ошибку показывать не нужно: сообщение уходит в очередь и дошлётся само, а если не выйдет
        // и за сутки — OutboxWorker вернёт строке «не отправлено» и эту же кнопку повтора
        _ = try? await viewModel.messaging.sendMedia(
            ready, caption: m.caption, recipientUserId: recipientUserId,
            conversationId: conversationId, localId: localId)
    }

    private func doSend(_ text: String, replyTo: ReplyRef? = nil) async {
        do {
            let cid = try await viewModel.messaging.sendText(text, recipientUserId: recipientUserId,
                                                             conversationId: conversationId, replyTo: replyTo)
            conversationId = cid                  // запомнили беседу (для нового чата)
            await viewModel.loadConversations()
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }
}

// Замер рамки бабла — только у летящего. Вешать onGeometryChange на все баблы нельзя: он дёргается
// на каждом кадре прокрутки у каждой видимой строки.
private struct LandingProbe: ViewModifier {
    let active: Bool
    let action: (CGRect) -> Void

    func body(content: Content) -> some View {
        if active {
            content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { action($0) }
        } else {
            content
        }
    }
}

extension View {
    // Круглая кнопка на «жидком стекле» — системный стиль iOS 26; на старых системах — материал.
    @ViewBuilder func glassCircleButton() -> some View {
        if #available(iOS 26.0, *) {
            // .interactive — системный отклик стекла на касание (подсветка и «пружинка»).
            // Не .buttonStyle(.glass): тот добавляет свои отступы, и круг выходил крупнее поля ввода.
            self.buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle())
        } else {
            self.buttonStyle(.plain).background(.ultraThinMaterial, in: Circle())
        }
    }
}

// Прокрутка ленты напрямую через UIScrollView, под SwiftUI-лентой.
//
// Почему не средствами SwiftUI: `.scrollPosition(id:)` в перевёрнутой ленте давал три бага разом —
// после программной прокрутки привязка переставала обновляться от пальца (кнопка «вниз» пропадала),
// заново применялась на каждой перерисовке (лента ползла, пока набираешь текст) и спорила с
// `ScrollViewReader` (переход к цитате отскакивал). Здесь один источник правды — смещение самого
// UIScrollView: «внизу» считается по нему, вниз едем через него же.
@MainActor
final class FeedScroll {
    // внизу, если до начала содержимого (= низа экрана в перевёрнутой ленте) меньше этого
    private static let bottomThreshold: CGFloat = 60

    var onBottomChange: ((Bool) -> Void)?
    private(set) var isAtBottom = true

    private weak var view: UIScrollView?
    private var offsetObservation: NSKeyValueObservation?
    private var sizeObservation: NSKeyValueObservation?
    private var heldHeight: CGFloat?          // высота содержимого до вставки нового сообщения

    func attach(_ scrollView: UIScrollView) {
        guard view !== scrollView else { return }
        view = scrollView
        offsetObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] sv, _ in
            MainActor.assumeIsolated { self?.offsetChanged(sv) }
        }
        sizeObservation = scrollView.observe(\.contentSize, options: [.new]) { [weak self] sv, _ in
            MainActor.assumeIsolated { self?.sizeChanged(sv) }
        }
        offsetChanged(scrollView)
    }

    private func distanceFromBottom(_ sv: UIScrollView) -> CGFloat {
        sv.contentOffset.y + sv.adjustedContentInset.top
    }

    // меняет признак только на пороге — экран перерисовывается раз, а не на каждом кадре прокрутки
    private func offsetChanged(_ sv: UIScrollView) {
        let bottom = distanceFromBottom(sv) < Self.bottomThreshold
        guard bottom != isAtBottom else { return }
        isAtBottom = bottom
        onBottomChange?(bottom)
    }

    // Новое сообщение пришло, пока читаем историю: оно добавится в начало содержимого. Запоминаем
    // высоту, а в ближайшем изменении размера сдвигаем смещение на прирост — видимое стоит на месте.
    // Сдвиг идёт в том же проходе раскладки, поэтому без видимого рывка.
    func holdPositionForInsert() {
        guard let view else { return }
        heldHeight = view.contentSize.height
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.heldHeight = nil }
    }

    private func sizeChanged(_ sv: UIScrollView) {
        guard let held = heldHeight else { return }
        heldHeight = nil
        let delta = sv.contentSize.height - held
        guard delta > 0 else { return }
        sv.contentOffset.y += delta
    }

    func scrollToBottom(animated: Bool) {
        guard let sv = view else { return }
        // setContentOffset заодно гасит инерцию: кнопка «вниз» срабатывает и на летящей ленте
        sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: -sv.adjustedContentInset.top), animated: animated)
    }

    func stopDeceleration() {
        guard let view, view.isDecelerating || view.isDragging else { return }
        view.setContentOffset(view.contentOffset, animated: false)
    }
}

// Невидимый вид внутри ленты: находит над собой UIScrollView и отдаёт его FeedScroll.
private struct ScrollViewFinder: UIViewRepresentable {
    let feed: FeedScroll

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ view: UIView, context: Context) {
        DispatchQueue.main.async {
            var v: UIView? = view.superview
            while let current = v, !(current is UIScrollView) { v = current.superview }
            if let found = v as? UIScrollView { feed.attach(found) }
        }
    }
}

// Набираемый текст. Отдельный объект, чтобы на нажатия клавиш перерисовывалось только поле ввода.
@MainActor
final class ComposerModel: ObservableObject {
    @Published var text = ""
}

// Рамка без перерисовок: читается только в момент отправки.
final class FrameBox {
    var rect: CGRect = .zero
}

// Строка поля ввода: текст + кнопка отправки внутри стекла. Единственное, что подписано на
// ComposerModel, — поэтому набор текста не трогает ленту.
private struct ComposerTextRow: View {
    @ObservedObject var model: ComposerModel
    let placeholder: String
    let hasAttachments: Bool          // вложение отправляется и без подписи
    let blocked: Bool                 // первое сообщение нового чата ещё уходит
    var focus: FocusState<Bool>.Binding
    let frame: FrameBox
    let onSend: () -> Void
    let onTextChange: () -> Void

    private var canSend: Bool {
        !blocked && (hasAttachments || !model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            // многострочный ввод: длинный текст переносится и поле растёт (до 5 строк, дальше скролл внутри)
            TextField(placeholder, text: $model.text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused(focus)
                .foregroundStyle(AppColor.text)
                .tint(ChatView.sendTint)                  // курсор и выделение — в цвет кнопки
                .padding(.leading, 16)
                .padding(.trailing, canSend ? 6 : 16)
                .padding(.vertical, 11)
                // рамка именно ТЕКСТА: от неё стартует вылет отправленного (SendFlight)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame.rect = $0 }

            if canSend {
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(ChatView.sendTint, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4).padding(.bottom, 4)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.8), value: canSend)
        .onChange(of: model.text) { _, _ in onTextChange() }
    }
}
