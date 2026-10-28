import Foundation

// Клиент для раздела Rings: баланс/экономика (GET /rings), покупка услуги, загрузка/удаление мелодии.
// Цены и лимиты сервер отдаёт в статусе — клиент их НЕ хардкодит (тюнинг экономики без релиза).
struct RingsService {

    func status() async throws -> RingsStatus {
        try await APIClient.shared.request("rings")
    }

    // plan: "7d" | "30d" | "90d". 409 «Not enough Rings» пробрасывается как APIError.server.
    func purchase(plan: String) async throws -> PurchaseRingbackResponse {
        try await APIClient.shared.request(
            "ringback/purchase", method: "POST", body: PurchaseRingbackRequest(plan: plan))
    }

    // блоб уже обработан (трим 45с / нормализация / AAC 128k) в RingbackStudio
    func uploadAudio(_ data: Data) async throws -> RingbackAudioResponse {
        try await APIClient.shared.upload("ringback/audio", fileField: "file", blobs: [data])
    }

    func deleteAudio() async throws {
        let _: OkResponse = try await APIClient.shared.request("ringback/audio", method: "DELETE")
    }
}
