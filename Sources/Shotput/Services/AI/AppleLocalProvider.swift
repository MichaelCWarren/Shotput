import FoundationModels
import Vision
import Foundation

struct AppleLocalProvider: DescriptionProvider {
    let kind: AIProvider = .appleLocal
    let modelLabel = "Apple Intelligence"

    func describe(imageURL: URL) async throws -> AIDescription {
        guard SystemLanguageModel.default.isAvailable else {
            throw AIError.providerUnavailable(Self.currentUnavailableReason() ?? "Apple Intelligence is unavailable")
        }

        let (ocr, labels) = try await Self.gatherInput(imageURL: imageURL)
        let session = LanguageModelSession(instructions: Self.instructions)

        do {
            // `@Generable`/`@Guide` need the FoundationModelsMacros plugin,
            // which ships with Xcode and isn't present on this Command Line
            // Tools-only machine, so this asks for the same title/summary
            // shape as plain text and parses it the way OllamaProvider does.
            let response = try await session.respond(
                to: Self.prompt(ocr: ocr, labels: labels),
                generating: String.self,
                options: GenerationOptions(temperature: 0.3, maximumResponseTokens: 120)
            )
            return try OllamaProvider.parseDescription(response.content).normalized()
        } catch is LanguageModelSession.GenerationError {
            // A guardrail refusal or a context overflow shouldn't leave the
            // screenshot pending forever; fall back to what OCR/Vision saw.
            return Self.fallbackDescription(ocr: ocr, labels: labels)
        } catch let error as AIError {
            if case .badResponse = error {
                return Self.fallbackDescription(ocr: ocr, labels: labels)
            }
            throw error
        }
    }

    /// Reads live `SystemLanguageModel` state; the registry calls this too
    /// so Settings can show the same reason without duplicating the switch.
    static func currentUnavailableReason() -> String? {
        guard case .unavailable(let reason) = SystemLanguageModel.default.availability else { return nil }
        return unavailableMessage(reason)
    }

    static func unavailableMessage(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: "This Mac cannot run Apple Intelligence"
        case .appleIntelligenceNotEnabled: "Apple Intelligence is not enabled on this Mac"
        case .modelNotReady: "The on-device model is still downloading"
        @unknown default: "Apple Intelligence is unavailable"
        }
    }

    static func fallbackDescription(ocr: String, labels: [String]) -> AIDescription {
        let lines = ocr.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let firstMultiWordLine = lines.first { $0.split(separator: " ").count >= 2 }
        let title = firstMultiWordLine ?? labels.first ?? "Screenshot"

        let summary: String
        if !labels.isEmpty {
            summary = "Contains: " + labels.joined(separator: ", ")
        } else if lines.count >= 2 {
            summary = lines[1]
        } else {
            summary = ""
        }
        return AIDescription(title: title, summary: summary).normalized()
    }

    private static let instructions = "You write short titles and one-sentence summaries for screenshots taken on a Mac."

    private static func prompt(ocr: String, labels: [String]) -> String {
        var lines = ["This text was extracted from a screenshot via OCR:", ocr.isEmpty ? "(no text found)" : ocr]
        if !labels.isEmpty {
            lines.append("The screenshot was also classified with these labels: \(labels.joined(separator: ", "))")
        }
        lines.append("""
        Reply with JSON only, no other text: {"title": "four to six words naming the app or window and what it shows", "summary": "one sentence, under 120 characters, describing the content"}
        """)
        return lines.joined(separator: "\n")
    }

    /// OCR and classification both need to touch pixels, so this stays off
    /// the main actor even when `describe` is called from it.
    private static func gatherInput(imageURL: URL) async throws -> (ocr: String, labels: [String]) {
        async let ocr = OCR.recognizeText(in: imageURL)
        async let labels = classify(imageURL: imageURL)
        return (String(try await ocr.prefix(1_500)), await labels)
    }

    private static func classify(imageURL: URL) async -> [String] {
        await Task.detached(priority: .utility) {
            let request = VNClassifyImageRequest()
            let handler = VNImageRequestHandler(url: imageURL, options: [:])
            try? handler.perform([request])

            let observations = request.results ?? []
            return observations
                .filter { $0.confidence >= 0.3 }
                .sorted { $0.confidence > $1.confidence }
                .prefix(5)
                .map(\.identifier)
        }.value
    }
}
