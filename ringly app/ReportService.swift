import Foundation

// Жалоба на пользователя (App Store Guideline 1.2).
//
// Сервер переписку прочитать не может — и не должен. Поэтому доказательства прикладывает САМ
// жалующийся: у него сообщения уже расшифрованы, и он осознанно передаёт копию, отметив галочку.
// Без этого жалоба свелась бы к «пользователь X плохой» и разобрать её было бы нечем.
struct ReportEvidenceMessage: Encodable {
    let fromMe: Bool
    let sentAt: Int64
    let text: String
}

struct CreateReportRequest: Encodable {
    let reportedUserId: String
    let reason: String
    let comment: String?
    let evidence: [ReportEvidenceMessage]?
}

struct CreateReportResponse: Decodable { let reportId: String }

enum ReportReason: String, CaseIterable, Identifiable {
    case spam
    case abuse
    case csam
    case impersonation
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spam:          return L("Спам или мошенничество")
        case .abuse:         return L("Оскорбления и угрозы")
        case .csam:          return L("Материалы с детьми")
        case .impersonation: return L("Выдаёт себя за другого")
        case .other:         return L("Другое")
        }
    }
}

final class ReportService {
    // Сколько последних сообщений беседы можно приложить. Это доказательство, а не выгрузка
    // переписки: чем меньше открытого текста уезжает с устройства, тем лучше.
    static let evidenceLimit = 5

    func send(reportedUserId: String, reason: ReportReason,
              comment: String?, evidence: [ReportEvidenceMessage]?) async throws {
        let body = CreateReportRequest(
            reportedUserId: reportedUserId,
            reason: reason.rawValue,
            comment: comment?.isEmpty == true ? nil : comment,
            evidence: evidence)

        let _: CreateReportResponse = try await APIClient.shared.request(
            "reports", method: "POST", body: body)
    }

    // Последние сообщения беседы в открытом виде — ровно то, что пользователь видит на экране.
    // Медиа и системные записи о звонках пропускаем: в `text` у них служебный JSON, а не текст.
    static func lastMessages(conversationId: String, myUserId: String?) -> [ReportEvidenceMessage] {
        ChatStore.messages(conversationId: conversationId)
            .filter { $0.kind == "text" }
            .suffix(evidenceLimit)
            .map { ReportEvidenceMessage(fromMe: $0.senderUserId == myUserId,
                                         sentAt: $0.sentAt, text: $0.text) }
    }
}
