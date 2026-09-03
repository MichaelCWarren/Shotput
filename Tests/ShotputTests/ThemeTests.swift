import Testing
import SwiftUI
@testable import Shotput

@Suite struct ThemeTests {
    @Test func cleanupIntervalDays() {
        #expect(CleanupInterval.week.days == 7)
        #expect(CleanupInterval.never.days == nil)
    }

    @Test func labelsMatchTheDesign() {
        #expect(CleanupInterval.day.label == "24 h")
        #expect(CleanupAction.trash.label == "Move to Trash")
    }

    /// Guards the shared widget parameters specs 07 and 08 depend on.
    @Test func sharedWidgetParameters() {
        let footer = PillButton(title: "Copy 2", prominent: true,
                                height: 26, fontSize: 11.5, weight: .semibold) {}
        #expect(footer.height == 26)
        #expect(footer.fontSize == 11.5)

        let toast = PillButton(title: "Annotate", height: 22, fontSize: 10.5, weight: .medium) {}
        #expect(toast.height == 22)
        #expect(toast.weight == .medium)

        #expect(PillButton(title: "Copy") {}.height == 24)
        #expect(SettingsGroup(radius: 20) { EmptyView() }.radius == 20)
    }
}
