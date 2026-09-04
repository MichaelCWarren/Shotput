import Foundation
import Network

/// A provider's raw title/summary, before `normalized()` enforces the
/// length and formatting rules every row and footer relies on.
struct AIDescription: Equatable, Codable {
    var title: String
    var summary: String

    func normalized() -> AIDescription {
        AIDescription(
            title: Self.normalize(title, limit: 48, stripTrailingPeriod: true),
            summary: Self.normalize(summary, limit: 120, stripTrailingPeriod: false)
        )
    }

    private static func normalize(_ text: String, limit: Int, stripTrailingPeriod: Bool) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        result = String(result.map { $0.isNewline ? " " : $0 })
        if stripTrailingPeriod, result.hasSuffix(".") {
            result.removeLast()
        }
        return truncate(result, limit: limit)
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let cut = text.index(text.startIndex, offsetBy: limit)
        let prefix = text[text.startIndex..<cut]
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[prefix.startIndex..<lastSpace])
        }
        return String(prefix)
    }
}

protocol DescriptionProvider: Sendable {
    var kind: AIProvider { get }
    var modelLabel: String { get }
    var credit: String { get }
    var isCloud: Bool { get }
    /// Where the image bytes go, or nil when they never leave this process.
    var destination: URL? { get }

    func describe(imageURL: URL) async throws -> AIDescription
}

extension DescriptionProvider {
    var isCloud: Bool { kind.sendsToCloud }
    var destination: URL? { nil }
}

extension URL {
    /// The whole question the send-off-this-Mac gate asks. Loopback stays
    /// here; a LAN address and a public one are both egress, so no private
    /// range test comes into it.
    var isLoopbackHost: Bool {
        guard var host = host?.lowercased() else { return false }
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        // `IPv4Address.isLoopback` matches only 127.0.0.1; the loopback
        // block is the whole 127/8, and Ollama can be bound anywhere in it.
        if let v4 = IPv4Address(host) { return v4.isLoopback || v4.rawValue.first == 127 }
        if let v6 = IPv6Address(host) { return v6.isLoopback }
        return false
    }
}

enum AIError: LocalizedError {
    case providerUnavailable(String)
    case unreachable(URL)
    case requiresSecureConnection(URL)
    case http(Int, String)
    case badResponse(String)
    case imageUnreadable(URL)
    case aiDisabled
    case cloudBlocked
    case offMachineBlocked(URL)
    case missingCloudKey

    var errorDescription: String? {
        switch self {
        case .providerUnavailable(let message): message
        case .unreachable(let url): Self.unreachableText(url)
        case .requiresSecureConnection(let url): "\(url.host ?? url.absoluteString) needs an https address. macOS blocks plain http to hosts off this Mac"
        case .http(let status, let body): Self.httpText(status: status, body: body)
        case .badResponse(let message): message
        case .imageUnreadable(let url): "Can't read \(url.lastPathComponent)"
        case .aiDisabled: "AI describing is off"
        case .cloudBlocked: "Cloud provider selected but Send images off this Mac is off"
        case .offMachineBlocked(let url): "\(url.host ?? url.absoluteString) isn't on this Mac. Turn on Send images off this Mac to use it"
        case .missingCloudKey: "Add an Ollama Cloud API key in Settings"
        }
    }

    private static func unreachableText(_ url: URL) -> String {
        let label = hostLabel(url)
        return url.isLoopbackHost ? "Ollama isn't running at \(label)" : "Can't reach Ollama at \(label)"
    }

    /// Ollama reports its errors as a JSON body, and a row the user reads at
    /// a glance can't be 200 characters of `{"error":...}`. The raw body
    /// stays on `debugDescription` for anything that wants all of it.
    private static func httpText(status: Int, body: String) -> String {
        let message = errorMessage(in: body)
        if let model = missingModel(in: message) {
            return "Model \(model) isn't installed. Run ollama pull \(model)"
        }
        switch status {
        case 401, 403:
            return "Ollama rejected the API key"
        case 429:
            return "Ollama is rate limiting. Try again in a few minutes"
        default:
            // No status code in front of the message: a row is 372pt wide,
            // and "Server returned 404: mod…" spends that width on the part
            // the user can do nothing with. The code stays on the tooltip.
            return message.isEmpty ? "Ollama answered \(status)" : message
        }
    }

    /// The `error` field if the body is Ollama's usual JSON, the body itself
    /// if it is plain text or a truncated object that won't parse, on one
    /// line either way. Some errors nest the text a level down, so both
    /// shapes are tried before giving up on the body.
    private static func errorMessage(in body: String) -> String {
        struct FlatBody: Decodable { var error: String }
        struct NestedBody: Decodable {
            struct Error: Decodable { var message: String }
            var error: Error
        }
        var message = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = message.data(using: .utf8) {
            let decoder = JSONDecoder()
            if let flat = try? decoder.decode(FlatBody.self, from: data) {
                message = flat.error
            } else if let nested = try? decoder.decode(NestedBody.self, from: data) {
                message = nested.error.message
            }
        }
        message = message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard message.count > 100 else { return message }
        return String(message.prefix(100)) + "…"
    }

    /// Ollama has said "model 'x' not found" and "model \"x\" not found, try
    /// pulling it first" across versions, so the quoted name is the part
    /// worth trusting.
    private static func missingModel(in message: String) -> String? {
        let lowercased = message.lowercased()
        guard lowercased.contains("not found") || lowercased.contains("try pulling") else { return nil }
        for quote in ["'", "\""] {
            let parts = message.components(separatedBy: quote)
            if parts.count >= 3, !parts[1].isEmpty { return parts[1] }
        }
        return nil
    }

    private static func hostLabel(_ url: URL) -> String {
        guard let host = url.host else { return url.absoluteString }
        guard let port = url.port else { return host }
        return "\(host):\(port)"
    }
}

extension AIError: CustomDebugStringConvertible {
    /// What a tooltip can show: the sentence a row shows, plus the raw
    /// server body that the sentence leaves out.
    var debugDescription: String {
        guard case .http(let status, let body) = self, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return errorDescription ?? "\(self)"
        }
        return "\(errorDescription ?? "HTTP \(status)")\n\nHTTP \(status): \(body)"
    }
}
