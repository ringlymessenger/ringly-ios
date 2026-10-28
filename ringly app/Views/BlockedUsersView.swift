import SwiftUI

// Список заблокированных мною пользователей + разблокировка. Открывается из профиля.
// Блок-лист локальный (BlockStore, SQLite) — сервер о нём не знает.
struct BlockedUsersView: View {
    @ObservedObject private var blocks = BlockState.shared

    var body: some View {
        List {
            if blocks.list.isEmpty {
                Text(L("Нет заблокированных пользователей"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(blocks.list) { u in
                    HStack {
                        Text(u.username.map { "@\($0)" } ?? u.userId)
                            .lineLimit(1)
                        Spacer()
                        Button(L("Разблокировать")) {
                            blocks.setBlocked(u.userId, username: u.username, false)
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)
                    }
                }
            }
        }
        .navigationTitle(L("Заблокированные"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { blocks.reload() }
    }
}
