import Testing
import Foundation
@testable import Shotput

@Suite struct ScreenshotDetectionTests {
    @Test func xattrMarksScreenshot() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try makeScreenshotFile(in: dir, name: "IMG_0001.png", withXattr: true)

        #expect(ScreenshotDetection.isScreenshot(url))
    }

    @Test func namePatternIsFallback() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let macOS = try makeScreenshotFile(in: dir, name: "Screenshot 2026-09-03 at 9.41.02.png", withXattr: false)
        let legacy = try makeScreenshotFile(in: dir, name: "Screen Shot 2021-01-01 at 1.00.00.png", withXattr: false)
        let photo = try makeScreenshotFile(in: dir, name: "IMG_0001.png", withXattr: false)

        #expect(ScreenshotDetection.isScreenshot(macOS))
        #expect(ScreenshotDetection.isScreenshot(legacy))
        #expect(!ScreenshotDetection.isScreenshot(photo))
    }

    @Test func nonImageIsNeverScreenshot() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("notes.pdf")
        try Data("not really a pdf".utf8).write(to: url)
        setScreenCaptureXattr(url)

        #expect(!ScreenshotDetection.isScreenshot(url))
    }
}
