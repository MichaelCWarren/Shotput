import Foundation

/// Backs `SettingsView`: everything beyond a direct binding to
/// `SettingsStore` (header text, which conditional rows show, folder sync
/// and apply with error capture, launch-at-login with revert) lives here so
/// it can be tested without a window. System side effects are injected
/// closures so tests never touch `com.apple.screencapture` or `SMAppService`.
@Observable
@MainActor
final class SettingsViewModel {
    private let settings: SettingsStore
    /// Optional because Settings can be built without the AI layer, and
    /// then there is no indexing status to report.
    private let ai: AICoordinator?
    private let registry: ProviderRegistry
    private let readLocation: () -> URL
    private let writeLocation: (URL) throws -> Void
    private let readShowsThumbnail: () -> Bool
    private let writeShowsThumbnail: (Bool) throws -> Void
    private let setLoginItem: (Bool) throws -> Void

    var lastError: Error?

    init(
        settings: SettingsStore,
        ai: AICoordinator? = nil,
        registry: ProviderRegistry = .live,
        readLocation: @escaping () -> URL = CaptureLocation.read,
        writeLocation: @escaping (URL) throws -> Void = CaptureLocation.write,
        readShowsThumbnail: @escaping () -> Bool = CaptureThumbnail.read,
        writeShowsThumbnail: @escaping (Bool) throws -> Void = CaptureThumbnail.write,
        setLoginItem: @escaping (Bool) throws -> Void = LoginItem.set
    ) {
        self.settings = settings
        self.ai = ai
        self.registry = registry
        self.readLocation = readLocation
        self.writeLocation = writeLocation
        self.readShowsThumbnail = readShowsThumbnail
        self.writeShowsThumbnail = writeShowsThumbnail
        self.setLoginItem = setLoginItem
    }

    var choices: [ProviderChoice] {
        registry.choices(for: settings.ai)
    }

    var selectedChoice: ProviderChoice {
        choices.first { $0.id == settings.aiProvider } ?? choices[0]
    }

    var aiSectionTitle: String {
        guard settings.aiEnabled else { return "AI" }
        return "AI · " + settings.aiProvider.label.uppercased()
    }

    var cleanupSubtitle: String? {
        settings.cleanupAction == .trash ? "Recoverable from Trash for 30 more days" : nil
    }

    var showsModelNameRow: Bool { settings.aiProvider != .appleLocal }
    var showsOllamaHostRow: Bool { settings.aiProvider == .ollamaLocal }
    var showsCloudKeyRow: Bool { settings.aiProvider == .ollamaCloud }

    /// Takes the field's draft when the user commits it. Skipping an
    /// unchanged value keeps tabbing through the field from costing a
    /// keychain write.
    func commitCloudKey(_ value: String) {
        guard value != settings.ollamaCloudKey else { return }
        settings.ollamaCloudKey = value
    }

    /// Says so when the keychain rejected the key, because the field itself
    /// keeps showing what was typed and describes keep working until quit.
    var cloudKeySubtitle: String {
        settings.cloudKeySaveFailed
            ? "Not saved. The keychain refused it, so it is gone when Shotput quits."
            : "Sent as a Bearer token to ollama.com"
    }

    // MARK: - AI status

    /// Only the first few given-up screenshots are listed. Settings already
    /// scrolls past the bottom of a laptop screen, and a library of
    /// thousands can give up on hundreds.
    static let maxListedFailures = 3

    var aiStatus: AIStatus? { ai?.status }

    var aiFailures: [AIFailureItem] { ai?.failures ?? [] }

    var listedFailures: [AIFailureItem] { Array(aiFailures.prefix(Self.maxListedFailures)) }

    var hiddenFailureCount: Int { max(0, aiFailures.count - Self.maxListedFailures) }

    var aiStatusHeadline: String {
        guard let aiStatus else { return "" }
        return Self.statusHeadline(aiStatus)
    }

    var aiStatusDetail: String {
        guard let aiStatus else { return "" }
        return Self.statusDetail(aiStatus, aiEnabled: settings.aiEnabled)
    }

    var aiStatusNote: String? {
        guard let aiStatus else { return nil }
        return Self.statusNote(aiStatus, aiEnabled: settings.aiEnabled)
    }

    var isDescribing: Bool {
        guard let aiStatus else { return false }
        return aiStatus.isRunning && aiStatus.blockedReason == nil
    }

    /// Re-indexing while nothing can run would throw away every description
    /// and leave the library with none, so it is offered only when the
    /// queue could actually replace them. AI being off is one of the
    /// reasons `blockedReason` already reports.
    var canReindexAll: Bool {
        guard let aiStatus else { return false }
        return aiStatus.blockedReason == nil && aiStatus.describedCount > 0
    }

    var reindexWarning: String {
        Self.reindexWarning(
            describedCount: aiStatus?.describedCount ?? 0,
            provider: selectedChoice.displayName,
            isCloud: selectedChoice.isCloud
        )
    }

    func retryFailure(_ url: URL) { ai?.retry(url) }

    func retryAllFailed() { ai?.retryAllFailed() }

    func reindexAll() { ai?.reindexAll() }

    /// The total is derived from the parts rather than taken from the
    /// library, so the three numbers on screen always add up. A separate
    /// library count disagrees with them for as long as a rescan is in
    /// flight.
    static func statusHeadline(_ status: AIStatus) -> String {
        let total = status.describedCount + status.pendingCount + status.failedCount
        guard total > 0 else { return "Nothing described yet" }
        return "\(status.describedCount) of \(total) described"
    }

    static func statusDetail(_ status: AIStatus, aiEnabled: Bool) -> String {
        var parts: [String] = []
        if !aiEnabled {
            parts.append("AI is off")
        } else if status.blockedReason != nil {
            parts.append("Paused")
        } else if status.isRunning {
            parts.append("Describing now")
        } else if status.pendingCount > 0 {
            parts.append("Waiting to start")
        } else if status.failedCount > 0 {
            // Not "up to date": the given-up screenshots listed under this
            // row have no description and the row would be claiming they do.
            parts.append("Nothing pending")
        } else {
            parts.append("Up to date")
        }
        if status.pendingCount > 0 {
            parts.append("\(status.pendingCount) pending")
        }
        return parts.joined(separator: " · ")
    }

    /// The reason the queue stopped, or the last thing that went wrong.
    /// Silent while AI is off: the detail line already says so, and the
    /// blocked reason there would only repeat it.
    static func statusNote(_ status: AIStatus, aiEnabled: Bool) -> String? {
        guard aiEnabled else { return nil }
        return status.blockedReason ?? status.lastError
    }

    static func failureSummary(count: Int) -> String {
        count == 1 ? "1 screenshot gave up" : "\(count) screenshots gave up"
    }

    static func failureDetail(_ item: AIFailureItem, now: Date = Date()) -> String {
        "\(item.reason) · \(Screenshot.shortDuration(now.timeIntervalSince(item.failedAt))) ago"
    }

    static func reindexWarning(describedCount: Int, provider: String, isCloud: Bool) -> String {
        let kept = describedCount == 1
            ? "the 1 description Shotput already has"
            : "the \(describedCount) descriptions Shotput already has"
        var text = "This throws away \(kept) and asks \(provider) for new ones."
        if isCloud {
            text += " Every screenshot is uploaded again."
        }
        return text
    }

    /// Adopts a capture folder set outside the app (e.g. `defaults write`)
    /// instead of trusting whatever the store last persisted.
    func syncFolder() {
        let location = readLocation()
        if location.path != settings.captureFolder.path {
            settings.captureFolder = location
        }
    }

    /// Adopts a thumbnail preference set outside the app: Screenshot.app's
    /// own Options menu writes the same key.
    func syncThumbnail() {
        let hidden = !readShowsThumbnail()
        if hidden != settings.hidesSystemThumbnail {
            settings.hidesSystemThumbnail = hidden
        }
    }

    func setHidesSystemThumbnail(_ on: Bool) {
        do {
            try writeShowsThumbnail(!on)
            settings.hidesSystemThumbnail = on
            lastError = nil
        } catch {
            lastError = error
        }
    }

    func applyFolder(_ url: URL) {
        do {
            try writeLocation(url)
            settings.captureFolder = url
            lastError = nil
        } catch {
            lastError = error
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            try setLoginItem(on)
            settings.launchAtLogin = on
            lastError = nil
        } catch {
            lastError = error
        }
    }
}
