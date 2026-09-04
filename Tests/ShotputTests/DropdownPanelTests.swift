import Testing
import AppKit
import SwiftUI
@testable import Shotput

@Suite @MainActor struct DropdownPanelTests {
    @Test func anchorsTopRightWithoutButton() {
        _ = NSApplication.shared
        let panel = DropdownPanel(rootView: AnyView(DropdownPlaceholderView()))
        panel.show(relativeTo: nil)
        defer { panel.hide() }

        let visible = NSScreen.main!.visibleFrame
        #expect(panel.frame.maxX == visible.maxX - 10)
        #expect(panel.frame.maxY == visible.maxY - 10)
        #expect(panel.frame.width == Theme.Metrics.dropdownWidth)
    }

    @Test func growsDownwardOnContentChange() {
        _ = NSApplication.shared
        let panel = DropdownPanel(rootView: AnyView(DropdownPlaceholderView()))
        panel.show(relativeTo: nil)
        defer { panel.hide() }

        let before = panel.frame
        panel.rootView = AnyView(DropdownPlaceholderView(height: 300))
        RunLoop.main.run(until: Date() + 0.1)

        #expect(panel.frame.maxX == before.maxX)
        #expect(panel.frame.maxY == before.maxY)
        #expect(panel.frame.height >= 300)
    }

    @Test func hideIsIdempotent() {
        _ = NSApplication.shared
        let panel = DropdownPanel(rootView: AnyView(DropdownPlaceholderView()))
        panel.show(relativeTo: nil)
        panel.hide()
        panel.hide()
        #expect(panel.isVisible == false)
    }
}
