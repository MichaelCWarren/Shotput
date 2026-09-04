import Vision

/// Single OCR path shared by the dropdown's "Copy text" and the AI layer's
/// `AppleLocalProvider`, so there is exactly one place that talks to Vision.
enum OCR {
    static func recognizeText(in url: URL) async throws -> String {
        try await Task.detached {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(url: url, options: [:])
            try handler.perform([request])

            let observations = request.results ?? []
            return observations
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        }.value
    }
}
