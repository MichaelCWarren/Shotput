import SwiftUI
@testable import Shotput

func runThemeTests() {
    T.equal(CleanupInterval.week.days, 7, "week is 7 days")
    T.equal(CleanupInterval.never.days, nil, "never has no deadline")
    T.equal(CleanupInterval.day.label, "24 h", "day label matches the design")
    T.equal(CleanupAction.trash.label, "Move to Trash", "trash label matches the design")
}

// Guards the shared widget parameters specs 07 and 08 depend on.
func runThemeWidgetTests() {
    let footer = PillButton(title: "Copy 2", prominent: true, height: 26, fontSize: 11.5, weight: .semibold) {}
    T.equal(footer.height, 26, "library footer pill is 26 tall")
    T.equal(footer.fontSize, 11.5, "library footer pill is 11.5pt")
    let toast = PillButton(title: "Annotate", height: 22, fontSize: 10.5, weight: .medium) {}
    T.equal(toast.height, 22, "toast pill is 22 tall")
    T.equal(toast.weight, .medium, "toast pill uses medium weight")
    let dflt = PillButton(title: "Copy") {}
    T.equal(dflt.height, 24, "default pill height unchanged at 24")
    T.equal(SettingsGroup(radius: 20) { EmptyView() }.radius, 20, "SettingsGroup radius is settable")
}
