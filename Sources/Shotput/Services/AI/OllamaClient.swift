import Foundation

struct OllamaClient {
    static let defaultLocalHost = URL(string: "http://localhost:11434")!
    static let cloudHost = URL(string: "https://ollama.com")!

    let host: URL
    let apiKey: String?
    let session: URLSession

    init(host: URL, apiKey: String?, session: URLSession = .shared) {
        self.host = host
        self.apiKey = apiKey
        self.session = session
    }

    func makeChatRequest(model: String, prompt: String, imageBase64: String) -> URLRequest {
        var request = URLRequest(url: host.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        applyHeaders(to: &request)
        let body = ChatRequestBody(
            model: model,
            messages: [ChatMessage(role: "user", content: prompt, images: [imageBase64])],
            stream: false,
            format: "json"
        )
        request.httpBody = try? JSONEncoder().encode(body)
        return request
    }

    func chat(model: String, prompt: String, imageBase64: String) async throws -> String {
        let data = try await send(makeChatRequest(model: model, prompt: prompt, imageBase64: imageBase64))
        return try Self.parseChat(data)
    }

    static func parseChat(_ data: Data) throws -> String {
        guard let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data) else {
            throw AIError.badResponse("Could not decode Ollama chat response")
        }
        return decoded.message.content
    }

    private func applyHeaders(to request: inout URLRequest) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .notConnectedToInternet, .timedOut:
                throw AIError.unreachable(host)
            case .appTransportSecurityRequiresSecureConnection:
                throw AIError.requiresSecureConnection(host)
            default:
                throw error
            }
        }
        guard let http = response as? HTTPURLResponse else {
            throw AIError.badResponse("No HTTP response from Ollama")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyPrefix = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw AIError.http(http.statusCode, bodyPrefix)
        }
        return data
    }
}

private struct ChatMessage: Encodable {
    var role: String
    var content: String
    var images: [String]
}

private struct ChatRequestBody: Encodable {
    var model: String
    var messages: [ChatMessage]
    var stream: Bool
    var format: String
}

private struct ChatResponse: Decodable {
    struct Message: Decodable {
        var role: String
        var content: String
    }
    var message: Message
}
