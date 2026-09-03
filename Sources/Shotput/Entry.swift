import AppKit

/// Entry point called by the ShotputApp executable. The App shell task fills
/// this in with the real delegate and status item.
public func runShotput() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.run()
}
