@testable import Shotput

func runThemeTests() {
    T.equal(CleanupInterval.week.days, 7, "week is 7 days")
    T.equal(CleanupInterval.never.days, nil, "never has no deadline")
    T.equal(CleanupInterval.day.label, "24 h", "day label matches the design")
    T.equal(CleanupAction.trash.label, "Move to Trash", "trash label matches the design")
}
