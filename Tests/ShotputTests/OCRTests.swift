import Testing
import AppKit
@testable import Shotput

/// Vision runs on-device, so these have no network dependency.
@Suite struct OCRTests {
    @Test func recognizesRenderedText() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeTextImage("SHOTPUT 2026", size: NSSize(width: 600, height: 120), in: dir)

        let text = try await OCR.recognizeText(in: url)

        #expect(text.contains("SHOTPUT"))
    }

    @Test func blankImageReturnsEmpty() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeTextImage(nil, size: NSSize(width: 200, height: 100), in: dir)

        let text = try await OCR.recognizeText(in: url)

        #expect(text == "")
    }
}
