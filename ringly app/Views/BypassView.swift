import SwiftUI

// Обход блокировок: ручное управление точками входа.
//
// Зачем экран, если мостики и так приходят с сервера автоматически: (1) сервер выдачи сам может быть
// недоступен — тогда единственный путь это ссылка из рук в руки; (2) у человека может быть СВОЙ VPS
// с поднятым демоном, и он хочет ходить именно через него, а не через случайный волонтёрский.
//
// Ссылка вставляется той же, что печатает демон: `ringly-relay link --host <ip>` → `ringly-bridge://…`.
// Переход по такой ссылке делает ровно то же самое (см. AppViewModel.handleDeepLink) — этот экран
// нужен, когда ссылку нельзя «нажать»: пришла текстом, продиктована, записана на бумаге.
//
// Как прокси в Telegram: «Подключить» добавляет точку входа и сразу подключается — в строке крутится
// индикатор, пока резолвер не проверит мостик, потом «Подключено · N мс». Правила переключения при
// отказе — в EndpointResolver.
//
// Вёрстка — как у остальных экранов профиля: карточки, строки с иконкой слева, пояснения под ними.
// Вставка — системной PasteButton: она не вызывает запрос iOS «Разрешить вставку?».
struct BypassView: View {
    private let resolver = EndpointResolver.shared

    @State private var linkText = ""
    @State private var entries: [EndpointResolver.BridgeEntry] = []
    @State private var isDirect = true
    @State private var error: String?
    @State private var pendingDelete: EndpointResolver.BridgeEntry?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !resolver.isTunnelAvailable {
                    banner(L("В этой сборке обход недоступен: приложение собрано без компонента обхода. Точки входа можно добавить, но использоваться они не будут."))
                }
                if resolver.simulateBlock {
                    // тумблер из скрытого меню легко забыть включённым — тогда «напрямую не работает»
                    // выглядело бы как настоящая поломка
                    banner(L("Включена имитация блокировки: прямое подключение не работает. Выключается в служебном меню."))
                }
                routesSection
                addSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .background(AppColor.background.ignoresSafeArea())
        .navigationTitle(L("Обход блокировок"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: EndpointResolver.stateChangedNotification)) { _ in
            reload()
        }
        // пинги, пока экран открыт: у активного — до сервера через мостик, у остальных — до их сервера
        .task {
            while !Task.isCancelled {
                await resolver.refreshPings()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
        .alert(L("Не удалось добавить"), isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
        .confirmationDialog(L("Удалить точку входа?"),
                            isPresented: .constant(pendingDelete != nil),
                            titleVisibility: .visible) {
            Button(L("Удалить"), role: .destructive) {
                if let entry = pendingDelete {
                    resolver.removeBridge(host: entry.bridge.host, port: entry.bridge.port)
                }
                pendingDelete = nil
            }
            Button(L("Отмена"), role: .cancel) { pendingDelete = nil }
        } message: {
            Text(L("Чтобы вернуть её, снова понадобится ссылка."))
        }
    }

    // MARK: - Подключение

    private var routesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(L("Подключение"))

            VStack(spacing: 0) {
                Button { resolver.selectDirect() } label: {
                    routeRow(icon: "globe", title: L("Напрямую"), subtitle: Text(L("Без обхода")),
                             isActive: isDirect, isConnecting: false)
                }
                .buttonStyle(.plain)

                ForEach(entries) { entry in
                    divider
                    Button { resolver.connect(host: entry.bridge.host, port: entry.bridge.port) } label: {
                        routeRow(icon: "point.3.connected.trianglepath.dotted",
                                 title: entry.bridge.host,
                                 subtitle: subtitle(entry),
                                 isActive: entry.isActive,
                                 isConnecting: entry.status == .connecting)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        // выданные сервером удалять незачем: их список ведёт сервер, вернутся при обновлении
                        if entry.origin == .own {
                            Button(role: .destructive) { pendingDelete = entry } label: {
                                Label(L("Удалить"), systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .background(AppColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            note(L("Нажмите на строку, чтобы подключиться. Свою точку входа можно удалить долгим нажатием."))
        }
    }

    private func routeRow(icon: String, title: String, subtitle: Text,
                          isActive: Bool, isConnecting: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(AppColor.subtext).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(AppColor.text).lineLimit(1)
                subtitle.font(.caption).foregroundStyle(AppColor.subtext).lineLimit(1)
            }
            Spacer()
            if isConnecting {
                ProgressView()
            } else if isActive {
                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
            }
        }
        .padding(14)
        .contentShape(Rectangle())
    }

    // «Выдан автоматически · Подключено · 85 мс». Цветом выделено только состояние.
    private func subtitle(_ entry: EndpointResolver.BridgeEntry) -> Text {
        let origin = entry.origin == .server ? Text(L("Выдан автоматически") + " · ") : Text("")
        let state: Text
        switch entry.status {
        case .idle:
            state = Text("\(L("Порт")) \(entry.bridge.port) · \(entry.bridge.sni)")
        case .connecting:
            state = Text(L("Подключение…"))
        case .connected(let ms):
            state = Text(ms.map { L("Подключено") + " · " + L("%d мс", $0) } ?? L("Подключено"))
                .foregroundColor(.green)
        case .reachable(let ms):
            state = Text(L("Доступен") + " · " + L("%d мс", ms))
        case .unavailable:
            state = Text(L("Недоступен")).foregroundColor(.red)
        }
        return origin + state
    }

    // MARK: - Своя точка входа

    private var addSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(L("Своя точка входа"))

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "link").foregroundStyle(AppColor.subtext).frame(width: 22)
                    TextField("ringly-bridge://…", text: $linkText)
                        .foregroundStyle(AppColor.text)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.go)
                        .onSubmit(add)
                    PasteButton(payloadType: String.self) { strings in
                        guard let text = strings.first else { return }
                        Task { @MainActor in linkText = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.capsule)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)

                divider

                Button(action: add) {
                    HStack(spacing: 12) {
                        Image(systemName: "plus.circle.fill").frame(width: 22)
                        Text(L("Подключить"))
                        Spacer()
                    }
                    .foregroundStyle(linkText.isEmpty ? AppColor.faint : Color.accentColor)
                    .padding(14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(linkText.isEmpty)
            }
            .background(AppColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            note(L("Точка входа — это чужой (или ваш) сервер, который передаёт зашифрованный трафик до Ringly. Прочитать переписку он не может: шифрование сквозное. Ссылку выдаёт команда `ringly-relay link` на сервере."))
        }
    }

    // MARK: - Общие куски

    private func header(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(AppColor.subtext).padding(.horizontal, 4)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(AppColor.subtext)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    // разделитель с отступом под иконку — как в системных списках
    private var divider: some View {
        Divider().overlay(AppColor.hairline).padding(.leading, 48)
    }

    private func banner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).frame(width: 22)
            Text(text)
                .font(.footnote)
                .foregroundStyle(AppColor.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func add() {
        let text = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let bridge = BridgeLink.parse(text) else {
            error = L("Это не похоже на ссылку-мостик. Она должна начинаться с ringly-bridge://")
            return
        }
        // Разделяем две причины: ссылка битая или такая точка входа уже есть — иначе пользователь
        // будет думать, что ссылка неверная, хотя он просто добавил её дважды.
        guard resolver.acceptBridgeLink(text) else {
            error = L("Такая точка входа уже добавлена")
            return
        }
        linkText = ""
        resolver.connect(host: bridge.host, port: bridge.port)
    }

    private func reload() {
        entries = resolver.entries
        isDirect = resolver.current == .direct
    }
}
