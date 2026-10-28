import Foundation
import LibSignalClient

enum APIError: LocalizedError {
    case server(String)        // сервер вернул { success:false, error }
    case http(Int)             // не-2xx без понятного тела
    case decoding              // не смогли разобрать JSON
    case network(Error)        // нет сети и т.п.

    // Переводим ЗДЕСЬ, в точке показа. Сами значения `.server(msg)` остаются сырыми: по ним
    // MessagingService.isStaleDeviceListError сравнивает сентинелы, и локализованный текст сломал бы
    // это сравнение. Сообщения, пришедшие с сервера, в словаре просто не найдутся — вернутся как есть.
    var errorDescription: String? {
        switch self {
        case .server(let msg): return L(msg)
        case .http(let code):  return L("Ошибка сервера (%d)", code)
        case .decoding:        return L("Не удалось разобрать ответ")
        case .network:         return L("Проблема с сетью")
        }
    }
}

struct APIEnvelope<T: Decodable>: Decodable {
    let success: Bool
    let data: T?
    let error: String?
}

final class APIClient {
    static let shared = APIClient()                 // один экземпляр на всё приложение
    private let baseURL = AppConfig.apiBaseURL

    // универсальный запрос: метод, путь, query, тело, нужен ли токен
    func request<T: Decodable>(
        _ path: String,
        method: String = "GET",
        query: [String: String]? = nil,
        body: Encodable? = nil,
        // Готовое бинарное тело вместо JSON (POST /messages/binary: шифртексты байтами, без base64).
        // Задано — `body` игнорируется.
        rawBody: Data? = nil,
        authorized: Bool = true
    ) async throws -> T {
        var url = baseURL.appendingPathComponent(path)
        if let query, !query.isEmpty {
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
            url = comps.url!
        }
        var req = URLRequest(url: url)
        req.httpMethod = method

        if let rawBody {
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            req.httpBody = rawBody
        } else if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }

        if authorized, let token = TokenStore.shared.token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            // Сессия от резолвера: прямой путь или через мостик (обход блокировок). Успех/неудачу
            // сообщаем резолверу — он решает, переключать ли транспорт (с гистерезисом, не во время звонка).
            (data, response) = try await EndpointResolver.shared.makeSession().data(for: req)
            EndpointResolver.shared.reportSuccess()
        } catch {
            EndpointResolver.shared.reportFailure()
            throw APIError.network(error)
        }

        // пытаемся разобрать конверт
        guard let envelope = try? JSONDecoder().decode(APIEnvelope<T>.self, from: data) else {
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw APIError.http(http.statusCode)
            }
            throw APIError.decoding
        }

        if envelope.success, let value = envelope.data {
            return value
        } else {
            throw APIError.server(envelope.error ?? "Неизвестная ошибка")
        }
    }
    
    // файл: APIClient.swift — добавить метод в class APIClient
    func upload<T: Decodable>(
        _ path: String,
        fileField: String,
        blobs: [Data]
    ) async throws -> T {
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token = TokenStore.shared.token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        var body = Data()
        for (i, blob) in blobs.enumerated() {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"avatar_\(i)\"\r\n")
            body.appendString("Content-Type: application/octet-stream\r\n\r\n")
            body.append(blob)
            body.appendString("\r\n")
        }
        body.appendString("--\(boundary)--\r\n")
        req.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await EndpointResolver.shared.makeSession().data(for: req)
            EndpointResolver.shared.reportSuccess()
        } catch {
            EndpointResolver.shared.reportFailure()
            throw APIError.network(error)
        }

        guard let envelope = try? JSONDecoder().decode(APIEnvelope<T>.self, from: data) else {
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw APIError.http(http.statusCode)
            }
            throw APIError.decoding
        }
        if envelope.success, let value = envelope.data {
            return value
        } else {
            throw APIError.server(envelope.error ?? "Неизвестная ошибка")
        }
    }
}

struct AnyEncodable: Encodable {
    private let encodeFunc: (Encoder) throws -> Void
    init(_ wrapped: Encodable) { encodeFunc = wrapped.encode }
    func encode(to encoder: Encoder) throws { try encodeFunc(encoder) }
}

// файл: APIClient.swift — в конец файла
private extension Data {
    mutating func appendString(_ s: String) {
        append(Data(s.utf8))
    }
}
