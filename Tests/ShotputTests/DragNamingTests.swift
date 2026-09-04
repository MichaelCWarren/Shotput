import Foundation
import Testing
@testable import Shotput

@MainActor
@Suite struct DragNamingTests {
    private func shot(_ path: String, title: String? = nil) -> Screenshot {
        Screenshot(url: URL(fileURLWithPath: path), created: Date(), byteSize: 100, title: title)
    }

    @Test func titleBecomesLowercaseKebab() {
        #expect(ScreenshotDrag.sanitized("Terminal window: build output") == "terminal-window-build-output")
        #expect(ScreenshotDrag.fileName(for: shot("/tmp/Screenshot 2026-09-04 at 16.53.12.png", title: "Terminal window: build output")) == "terminal-window-build-output.png")
    }

    @Test func runsOfPunctuationAndSpaceCollapseToOneDash() {
        #expect(ScreenshotDrag.sanitized("Build  --  output?! (final)") == "build-output-final")
    }

    @Test func edgePunctuationLeavesNoLeadingOrTrailingDash() {
        #expect(ScreenshotDrag.sanitized("...Stripe dashboard...") == "stripe-dashboard")
        #expect(ScreenshotDrag.sanitized("/tmp/") == "tmp")
    }

    @Test func punctuationOnlyTitleFallsBackToTheOriginalName() {
        #expect(ScreenshotDrag.sanitized("?!  ...") == "")
        #expect(ScreenshotDrag.fileName(for: shot("/tmp/Shot.png", title: "?!  ...")) == "Shot.png")
    }

    @Test func nonASCIILettersSurvive() {
        #expect(ScreenshotDrag.sanitized("Café Münster: día 2") == "café-münster-día-2")
        #expect(ScreenshotDrag.sanitized("東京の地図 (2026)") == "東京の地図-2026")
    }

    @Test func untitledShotIsNamedAfterItsSanitizedCaptureName() {
        #expect(ScreenshotDrag.fileName(for: shot("/tmp/Screenshot 2026-09-04 at 16.53.12.png")) == "screenshot-2026-09-04-at-16-53-12.png")
    }

    @Test func untitledShotWithoutAnExtensionKeepsTheWholeName() {
        #expect(ScreenshotDrag.fileName(for: shot("/tmp/Screen Grab 3")) == "screen-grab-3")
    }

    @Test func longTitleClipsOnADashBoundary() {
        let title = "The quarterly revenue dashboard showing regional breakdown by territory"
        let name = ScreenshotDrag.sanitized(title)
        #expect(name == "the-quarterly-revenue-dashboard-showing-regional-breakdown")
        #expect(name.count <= ScreenshotDrag.maxNameLength)
        #expect(!name.hasSuffix("-"))
    }

    @Test func longTitleWithNoLateDashClipsMidWord() {
        let title = "ab " + String(repeating: "c", count: 80)
        #expect(ScreenshotDrag.sanitized(title) == "ab-" + String(repeating: "c", count: 57))
    }

    @Test func clipLandingOnADashDropsIt() {
        let title = String(repeating: "d", count: 58) + " tail"
        #expect(ScreenshotDrag.sanitized(title) == String(repeating: "d", count: 58))
    }

    @Test func collidingNamesAreNumberedWithADash() {
        let now = Date()
        let name = "collision-probe-\(UUID().uuidString.prefix(8)).png"
        #expect(ScreenshotDrag.claim(name, now: now) == name)
        let second = ScreenshotDrag.claim(name, now: now)
        #expect(second == (name as NSString).deletingPathExtension + "-2.png")
        #expect(ScreenshotDrag.claim(name, now: now) == (name as NSString).deletingPathExtension + "-3.png")
    }
}
