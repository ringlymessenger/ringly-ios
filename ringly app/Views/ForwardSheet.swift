import SwiftUI

// Выбор чатов для пересылки — по образцу Telegram: поиск, имена с аватарками, отметка нескольких
// чатов сразу и необязательный комментарий, который уходит вместе с пересланным.
struct ForwardSheet: View {
    let conversations: [ConversationItem]
    let onSend: (_ targets: [ConversationItem], _ comment: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var contacts = ContactProfileCache.shared
    @State private var query = ""
    @State private var selected: [String] = []          // conversationId в порядке выбора
    @State private var comment = ""

    var body: some View {
        NavigationStack {
            List(filtered, id: \.conversationId) { c in
                if let other = c.otherUser { row(c, other) }
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: L("Поиск"))
            .navigationTitle(L("Переслать"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !selected.isEmpty { sendBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
            }
            .animation(.spring(response: 0.24, dampingFraction: 0.88), value: selected.isEmpty)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var filtered: [ConversationItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return conversations }

        return conversations.filter { c in
            guard let other = c.otherUser else { return false }
            let name = contacts.byUser[other.userId]?.name ?? ""

            return other.username.lowercased().contains(q) || name.lowercased().contains(q)
        }
    }

    private func row(_ c: ConversationItem, _ other: OtherUser) -> some View {
        let resolved = contacts.byUser[other.userId]
        let isOn = selected.contains(c.conversationId)

        return Button { toggle(c.conversationId) } label: {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if let image = resolved?.avatar {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            Circle().fill(.blue.opacity(0.2))
                                .overlay(Text(other.username.prefix(1).uppercased()).foregroundStyle(.blue))
                        }
                    }
                    .frame(width: 46, height: 46)
                    .clipShape(Circle())

                    // галочка на аватарке — как в Telegram
                    if isOn {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, ChatView.sendTint)
                            .background(Circle().fill(Color(.systemBackground)).padding(-2))
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(resolved?.name ?? "@\(other.username)").font(.body.weight(.semibold)).lineLimit(1)
                    Text("@\(other.username)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onAppear { contacts.ensure(other.userId) }
    }

    private var sendBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(L("Добавить комментарий…"), text: $comment, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .tint(ChatView.sendTint)
                .padding(.horizontal, 16).padding(.vertical, 11)
                .viewerGlass(RoundedRectangle(cornerRadius: 22, style: .continuous))

            Button {
                let byId = Dictionary(conversations.map { ($0.conversationId, $0) }, uniquingKeysWith: { a, _ in a })
                onSend(selected.compactMap { byId[$0] }, comment.trimmingCharacters(in: .whitespacesAndNewlines))
                dismiss()
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(ChatView.sendTint, in: Circle())
                    if selected.count > 1 {
                        Text("\(selected.count)")
                            .font(.system(size: 11, weight: .bold)).foregroundStyle(ChatView.sendTint)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(.white, in: Capsule())
                            .offset(x: 4, y: -4)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func toggle(_ id: String) {
        withAnimation(.spring(response: 0.2, dampingFraction: 0.72)) {
            if let i = selected.firstIndex(of: id) { selected.remove(at: i) } else { selected.append(id) }
        }
    }
}
