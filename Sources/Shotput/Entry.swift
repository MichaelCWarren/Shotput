import AppKit

/// Entry point called by the ShotputApp executable.
///
/// NSApplication.delegate does not retain, so the delegate is stashed here
/// to outlive this call. main.swift calls this synchronously on the main
/// thread before any concurrency machinery starts, so asserting main-actor
/// isolation here is safe (same reasoning as the Hotkey C callback).
@MainActor
private var delegate: ShotputApp?

public func runShotput() {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let appDelegate = ShotputApp()
        delegate = appDelegate
        app.delegate = appDelegate
        app.run()
    }
}
