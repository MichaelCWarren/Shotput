import Foundation

enum CaptureLocationError: Error {
    case syncFailed
}

/// The `com.apple.screencapture` domain macOS's own screenshot tool reads.
/// Writing a key there is only half the job: SystemUIServer holds the old
/// value until it is restarted.
private enum ScreenCapturePreferences {
    static let appID = "com.apple.screencapture" as CFString

    static func value(for key: CFString) -> CFPropertyList? {
        CFPreferencesCopyAppValue(key, appID)
    }

    static func set(_ value: CFPropertyList, for key: CFString) throws {
        CFPreferencesSetAppValue(key, value, appID)
        guard CFPreferencesAppSynchronize(appID) else { throw CaptureLocationError.syncFailed }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["SystemUIServer"]
        // A non-zero exit is fine: SystemUIServer relaunches on its own and
        // the preference is already written.
        try? process.run()
        process.waitUntilExit()
    }
}

/// Reads and writes the preference that decides where macOS's screenshot
/// tool saves, so a folder chosen in Settings is where ⇧⌘4 actually lands.
enum CaptureLocation {
    private static let key = "location" as CFString

    static func read() -> URL {
        folder(fromPreferenceValue: ScreenCapturePreferences.value(for: key) as? String)
    }

    static func write(_ folder: URL) throws {
        try ScreenCapturePreferences.set(folder.path as CFString, for: key)
    }

    static func folder(fromPreferenceValue value: String?) -> URL {
        guard let value, !value.isEmpty else {
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        }
        let expanded = (value as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }
}

/// Reads and writes the preference behind Screenshot.app's "Show Floating
/// Thumbnail" option, so Settings can drop the system preview that doubles
/// up with Shotput's own capture toast.
enum CaptureThumbnail {
    private static let key = "show-thumbnail" as CFString

    static func read() -> Bool {
        shows(preferenceValue: ScreenCapturePreferences.value(for: key) as? Bool)
    }

    static func write(_ shows: Bool) throws {
        try ScreenCapturePreferences.set(shows as CFBoolean, for: key)
    }

    static func shows(preferenceValue value: Bool?) -> Bool {
        value ?? true
    }
}
