import AppKit
import Foundation

struct OllamaProvider: DescriptionProvider {
    let client: OllamaClient
    let model: String
    let kind: AIProvider

    var modelLabel: String { model }

    var destination: URL? { client.host }

    func describe(imageURL: URL) async throws -> AIDescription {
        let imageBase64 = try await Self.encodedImage(at: imageURL)
        let content = try await client.chat(model: model, prompt: Self.prompt, imageBase64: imageBase64)
        return try Self.parseDescription(content).normalized()
    }

    static let prompt = """
    This image is a screenshot. Reply with JSON only, no other text: \
    {"title": "four to six words naming the app or window and what it shows", \
    "summary": "one sentence, under 120 characters, describing the content"}
    """

    static func parseDescription(_ content: String) throws -> AIDescription {
        struct Raw: Decodable {
            var title: String?
            var summary: String?
        }
        guard let data = extractJSONObject(from: content).data(using: .utf8),
              let raw = try? JSONDecoder().decode(Raw.self, from: data),
              let title = raw.title else {
            throw AIError.badResponse("Could not find a title in the Ollama response")
        }
        return AIDescription(title: title, summary: raw.summary ?? "")
    }

    /// Models routinely wrap JSON in a code fence or add prose around it
    /// despite `format: "json"`, so this takes the outermost braces instead
    /// of trusting the whole string to decode.
    private static func extractJSONObject(from content: String) -> String {
        guard let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}"), start < end else {
            return content
        }
        return String(content[start...end])
    }

    /// A 5 MB Retina PNG is too big to push through Ollama on every capture.
    /// The decode and JPEG encode are synchronous and `AIQueue` calls
    /// `describe` from the main actor, so this runs detached like the
    /// Vision work in `AppleLocalProvider`.
    static func encodedImage(at url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            guard let image = NSImage(contentsOf: url) else {
                throw AIError.imageUnreadable(url)
            }
            let downscaled = downscale(image, maxDimension: 1_568)
            guard let tiff = downscaled.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                throw AIError.imageUnreadable(url)
            }
            return jpeg.base64EncodedString()
        }.value
    }

    private static func downscale(_ image: NSImage, maxDimension: CGFloat) -> NSImage {
        let longSide = max(image.size.width, image.size.height)
        guard longSide > maxDimension else { return image }
        let scale = maxDimension / longSide
        let newSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        return NSImage(size: newSize, flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
    }
}
