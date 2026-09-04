import Testing
import Foundation
@testable import Shotput

/// These tests only exercise the pure value helpers; `read()` and
/// `write(_:)` touch the real `com.apple.screencapture` preference and are
/// covered manually, not here.
@Suite struct CaptureLocationTests {
    @Test func nilMeansDesktop() {
        #expect(CaptureLocation.folder(fromPreferenceValue: nil).path.hasSuffix("/Desktop"))
        #expect(CaptureLocation.folder(fromPreferenceValue: "").path.hasSuffix("/Desktop"))
    }

    @Test func tildeExpands() {
        let url = CaptureLocation.folder(fromPreferenceValue: "~/Pictures/Shots")
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        #expect(url.path.hasPrefix(home))
        #expect(url.path.hasSuffix("Pictures/Shots"))
    }

    @Test func unsetThumbnailPreferenceMeansShown() {
        #expect(CaptureThumbnail.shows(preferenceValue: nil) == true)
        #expect(CaptureThumbnail.shows(preferenceValue: true) == true)
        #expect(CaptureThumbnail.shows(preferenceValue: false) == false)
    }
}
