import Testing
import Foundation
import AppKit
@testable import Shotput

@Suite @MainActor struct OnboardingTests {
    @Test func gateIgnoresTheOptionalTrashStep() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let gated = OnboardingModel(
            settings: testSettings(folder: dir),
            checkCaptureFolder: { .passed },
            checkSaveFolder: { .failed },
            checkTrash: { .pending }
        )
        await gated.recheck()
        #expect(gated.nextPendingIndex == 1)
        #expect(gated.canContinue == false)
        #expect(gated.hint == "Continue enables after Save-folder access is granted")
        // Row 3 gets no trailing control unless it's the first unpassed step.
        #expect(gated.nextPendingIndex != 2)

        let trashOptional = OnboardingModel(
            settings: testSettings(folder: dir),
            checkCaptureFolder: { .passed },
            checkSaveFolder: { .passed },
            checkTrash: { .pending }
        )
        await trashOptional.recheck()
        #expect(trashOptional.canContinue == true)
        #expect(trashOptional.hint == "Trash access is optional. Auto-cleanup will ask for it when it first runs.")

        let allPassed = OnboardingModel(
            settings: testSettings(folder: dir),
            checkCaptureFolder: { .passed },
            checkSaveFolder: { .passed },
            checkTrash: { .passed }
        )
        await allPassed.recheck()
        #expect(allPassed.hint == "All set. You can revisit this from the menu bar.")
    }

    @Test func captureFolderCheckReportsListingFailure() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(PermissionChecks.captureFolderAccess(at: dir) == .passed)

        let neverCreated = dir.appendingPathComponent("never-created")
        #expect(PermissionChecks.captureFolderAccess(at: neverCreated) == .failed)
    }

    @Test func trashRoundTripLeavesNothingBehind() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = PermissionChecks.trashRoundTrip(in: dir)
        #expect(result.state == .passed)

        let remaining = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(!remaining.contains { $0.lastPathComponent.hasPrefix(".shotput-trash-check-") })

        let trashURL = try #require(result.trashURL)
        #expect(!FileManager.default.fileExists(atPath: trashURL.path))
    }
}

@Suite @MainActor struct ToastTests {
    @Test func hoverFreezesTheRemainingTime() {
        var current = Date(timeIntervalSince1970: 1_700_000_000)
        let model = ToastModel(now: { current })
        let shot = Screenshot(url: URL(fileURLWithPath: "/tmp/hover-shot.png"), created: current, byteSize: 1_024)

        model.show(shot, appName: "Safari", copied: false)
        #expect(abs(model.remaining - 4) < 0.001)

        current = current.addingTimeInterval(1.5)
        model.setHovering(true)
        #expect(abs(model.remaining - 2.5) < 0.001)

        // Two further advances while still hovering: the countdown stays frozen.
        current = current.addingTimeInterval(1)
        #expect(abs(model.remaining - 2.5) < 0.001)
        current = current.addingTimeInterval(1)
        #expect(abs(model.remaining - 2.5) < 0.001)

        model.setHovering(false)
        current = current.addingTimeInterval(2.5)
        #expect(model.remaining <= 0)

        model.show(shot, appName: "Safari", copied: false)
        #expect(abs(model.remaining - 4) < 0.001)
        #expect(model.isVisible == true)
    }

    @Test func metaLineJoinsAppTimeAndSize() {
        let shot = Screenshot(url: URL(fileURLWithPath: "/tmp/meta-shot.png"), created: Date(), byteSize: 421_000)

        let withApp = ToastModel.metaText(appName: "Safari", screenshot: shot)
        #expect(withApp == "Safari · \(shot.timeText) · \(shot.sizeText)")

        let withoutApp = ToastModel.metaText(appName: nil, screenshot: shot)
        #expect(withoutApp == "\(shot.name) · \(shot.timeText) · \(shot.sizeText)")
    }

    /// A second capture arriving while the first toast is sliding away must
    /// bring the panel back, and the interrupted slide-out must not order it
    /// out again a fraction of a second later.
    @Test func aPresentDuringDismissKeepsThePanelOnScreen() throws {
        _ = NSApplication.shared
        let panel = makeToastPanel()
        defer { panel.orderOut(nil) }
        let slides = SlideRecorder(panel: panel)
        let onScreen = try #require(NSScreen.screens.first).visibleFrame.maxX - 16

        panel.present()
        slides.land(0)

        let dismissals = Counter()
        panel.dismiss { dismissals.value += 1 }
        #expect(slides.count == 2)
        #expect(slides.alpha(1) == 0)

        // Second capture, with the slide-out still in flight.
        panel.present()
        #expect(slides.count == 3)
        slides.land(2)

        // Now the superseded slide-out finishes. Its end state never reaches
        // the panel — the newer animation owns the frame and alpha — but its
        // completion still runs, and that is what must no-op.
        slides.finish(1)

        #expect(dismissals.value == 0)
        #expect(panel.isVisible == true)
        #expect(panel.alphaValue == 1)
        #expect(panel.frame.maxX == onScreen)
    }

    @Test func anUninterruptedDismissOrdersOutAndCompletes() {
        _ = NSApplication.shared
        let panel = makeToastPanel()
        defer { panel.orderOut(nil) }
        let slides = SlideRecorder(panel: panel)

        panel.present()
        slides.land(0)
        #expect(panel.isVisible == true)

        let dismissals = Counter()
        panel.dismiss { dismissals.value += 1 }
        slides.land(1)

        #expect(dismissals.value == 1)
        #expect(panel.isVisible == false)
    }

    /// The geometry the slide runs between, which the animation itself only
    /// interpolates: in from offscreen right, back out the same way.
    @Test func presentStartsOffscreenRightAndSlidesToTheAnchor() throws {
        _ = NSApplication.shared
        let panel = makeToastPanel()
        defer { panel.orderOut(nil) }
        let slides = SlideRecorder(panel: panel)
        let visible = try #require(NSScreen.screens.first).visibleFrame

        panel.present()
        let anchored = ToastPanel.targetFrame(in: visible, size: panel.frame.size)
        #expect(panel.frame.origin.x == anchored.origin.x + anchored.width + 16)
        #expect(panel.alphaValue == 0)
        #expect(slides.frame(0) == anchored)
        #expect(slides.alpha(0) == 1)

        slides.land(0)
        panel.dismiss {}
        #expect(slides.frame(1).origin.x == anchored.origin.x + anchored.width + 16)
    }

    @Test func targetFrameAnchorsTopRight() {
        let frame = ToastPanel.targetFrame(
            in: CGRect(x: 0, y: 0, width: 1512, height: 944),
            size: CGSize(width: 330, height: 82)
        )
        let expectedX: CGFloat = 1512 - 16 - 330
        let expectedY: CGFloat = 944 - 16 - 82
        #expect(frame.origin.x == expectedX)
        #expect(frame.origin.y == expectedY)
        #expect(frame.size == CGSize(width: 330, height: 82))
    }
}

@MainActor
private final class Counter {
    var value = 0
}

/// Stands in for `NSAnimationContext`, which never advances in a test host
/// with nothing pumping a run loop. Each slide the panel asks for is recorded,
/// and the test decides when it lands.
@MainActor
private final class SlideRecorder {
    private struct Slide {
        let frame: CGRect
        let alpha: CGFloat
        let completion: () -> Void
    }

    private var slides: [Slide] = []
    private unowned let panel: ToastPanel

    init(panel: ToastPanel) {
        self.panel = panel
        panel.slide = { [weak self] _, frame, alpha, _, completion in
            self?.slides.append(Slide(frame: frame, alpha: alpha, completion: completion))
        }
    }

    var count: Int { slides.count }
    func frame(_ index: Int) -> CGRect { slides[index].frame }
    func alpha(_ index: Int) -> CGFloat { slides[index].alpha }

    /// An animation that ran to the end uninterrupted: the panel takes the end
    /// state, then the completion fires.
    func land(_ index: Int) {
        panel.setFrame(slides[index].frame, display: false)
        panel.alphaValue = slides[index].alpha
        slides[index].completion()
    }

    /// A superseded animation: only the completion fires, because a newer
    /// animation has taken over the frame and alpha.
    func finish(_ index: Int) {
        slides[index].completion()
    }
}

@MainActor
private func makeToastPanel() -> ToastPanel {
    ToastPanel(rootView: ToastView(
        model: ToastModel(),
        onAnnotate: {}, onCopyText: {}, onDelete: {}, onThumbTap: {}, onHover: { _ in }
    ))
}
