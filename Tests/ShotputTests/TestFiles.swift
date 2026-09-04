import AppKit
import Foundation
import Testing
@testable import Shotput

/// Shared fixtures for the screenshot-store suites. No `@Suite` here, just
/// free functions; each caller gets its own temp directory or pasteboard so
/// suites running in parallel never see each other's files.

func makeTempDir(_ name: String = "") throws -> URL {
    let suffix = name.isEmpty ? "" : "-\(name)"
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ShotputTests-\(UUID().uuidString)\(suffix)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // /var is a symlink to /private/var that FileManager.contentsOfDirectory
    // resolves but `resolvingSymlinksInPath()` deliberately leaves alone
    // (Foundation special-cases /tmp, /var, /etc there), so a URL built
    // straight off .temporaryDirectory would never equal the one a rescan
    // finds. realpath(3) has no such exception.
    var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
    guard realpath(dir.path, &buffer) != nil else { return dir }
    return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
}

@discardableResult
func makeScreenshotFile(in dir: URL, name: String, created: Date = Date(), withXattr: Bool = true) throws -> URL {
    let url = dir.appendingPathComponent(name)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let data = try #require(rep.representation(using: .png, properties: [:]))
    try data.write(to: url)
    try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: url.path)
    if withXattr {
        setScreenCaptureXattr(url)
    }
    return url
}

/// The same xattr `screencapture` writes, so detection tests exercise the
/// real rule rather than a stand-in flag.
func setScreenCaptureXattr(_ url: URL) {
    let name = "com.apple.metadata:kMDItemIsScreenCapture"
    guard let plistData = try? PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0) else { return }
    url.withUnsafeFileSystemRepresentation { path in
        guard let path else { return }
        _ = plistData.withUnsafeBytes { buffer in
            setxattr(path, name, buffer.baseAddress, buffer.count, 0, 0)
        }
    }
}

func makeTextImage(_ text: String?, size: NSSize, in dir: URL) throws -> URL {
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    if let text {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 48),
            .foregroundColor: NSColor.black,
        ]
        (text as NSString).draw(at: NSPoint(x: 20, y: size.height / 2 - 30), withAttributes: attributes)
    }
    image.unlockFocus()

    let tiff = try #require(image.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: tiff))
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    let url = dir.appendingPathComponent("\(UUID().uuidString).png")
    try png.write(to: url)
    return url
}

/// A `UserDefaults` domain named for one test, so suites running in parallel
/// never share state and never touch the user's real defaults.
func testSuite(name: String = "ShotputTests-\(UUID())") -> (defaults: UserDefaults, name: String) {
    (UserDefaults(suiteName: name)!, name)
}

/// Stand-in for the keychain. Every `SettingsStore` the tests build injects
/// one of these; a suite that wrote to the login keychain would leave items
/// behind on whoever ran it.
final class InMemorySecretStore: SecretStore {
    private(set) var readCount = 0
    private(set) var writeCount = 0
    var writesFail = false
    private var values: [String: String]

    init(_ values: [String: String] = [:]) {
        self.values = values
    }

    func secret(for account: String) -> String? {
        readCount += 1
        return values[account]
    }

    @discardableResult
    func setSecret(_ value: String, for account: String) -> Bool {
        writeCount += 1
        guard !writesFail else { return false }
        values[account] = value
        return true
    }

    @discardableResult
    func removeSecret(for account: String) -> Bool {
        guard !writesFail else { return false }
        values[account] = nil
        return true
    }
}

@MainActor
func testSettings(folder: URL, suiteName: String = "ShotputTests-\(UUID())") -> SettingsStore {
    let store = SettingsStore(defaults: testSuite(name: suiteName).defaults, secrets: InMemorySecretStore())
    store.captureFolder = folder
    return store
}

/// Same as `testSettings`, minus the folder override, plus the backing
/// `defaults`/`name` for callers that build a second `SettingsStore` from the
/// same domain, poke raw values in before construction, or tear the domain
/// down explicitly.
@MainActor
func testSettingsWithSuite(name: String = "ShotputTests-\(UUID())") -> (store: SettingsStore, defaults: UserDefaults, name: String) {
    let (defaults, name) = testSuite(name: name)
    return (SettingsStore(defaults: defaults, secrets: InMemorySecretStore()), defaults, name)
}

/// Short waits for callbacks that land on the main queue with nothing to
/// hook a completion to: the FSEvents debounce and the `ObservationLoop`
/// re-arm. Keep these short; the FSEvents latency is 0.3 s.
func settle(_ seconds: Double = 0.5) async throws {
    try await Task.sleep(for: .seconds(seconds))
}

/// Repeatedly checks `condition` until it is true or `timeout` elapses.
/// For state that clears itself off an internal `Task.sleep` with no
/// awaitable handle (`CopiedFlash`'s clear, `AIDropdownModel`'s debounced
/// search), a single fixed-time check races that change under load; polling
/// doesn't.
///
/// Omitting `timeout` means "this is going to happen, wait for it". The
/// ceiling then only decides how long a stall runs before the suite calls
/// it a failure, and it costs nothing on a machine that delivers promptly,
/// so it is set for the worst box that will ever run this. At 2 s, twelve
/// of twelve runs under a 14-way CPU load failed on these waits.
///
/// Passing an explicit `timeout` means the opposite: the test asserts the
/// condition stays false, and the window is what gives that claim its
/// force. Those numbers are chosen per call site and commented there.
func poll(
    timeout: Duration = .seconds(10),
    interval: Duration = .milliseconds(5),
    _ condition: () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: interval)
    }
    return condition()
}
