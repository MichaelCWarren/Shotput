import AppKit
import os

/// File-system actions the dropdown, library, toast and cleanup all call.
/// None of these touch `ScreenshotStore`; callers apply the store change
/// (`store.remove`) themselves once the action succeeds.
enum ScreenshotActions {
    private static let logger = Logger(subsystem: "com.shotput.app", category: "actions")

    static func annotate(_ url: URL) {
        guard let previewURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else {
            NSWorkspace.shared.open(url)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: previewURL, configuration: configuration) { _, error in
            if let error {
                logger.error("Failed to open \(url.lastPathComponent, privacy: .public) in Preview: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Throws the failure `trashItem` gave, whose description is what the
    /// Library's alert and the cleanup log show. Callers treat a partial
    /// batch as a whole failure and let the next rescan reconcile, so the
    /// URLs moved before the throw are not reported.
    @discardableResult
    static func trash(_ urls: [URL]) throws -> [URL] {
        var moved: [URL] = []
        for url in urls {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            if let resultingURL = resultingURL as URL? {
                moved.append(resultingURL)
            }
        }
        return moved
    }

    static func delete(_ urls: [URL]) throws {
        for url in urls {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func remove(_ urls: [URL], action: CleanupAction) throws {
        switch action {
        case .trash:
            try trash(urls)
        case .delete:
            try delete(urls)
        }
    }

    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Modal directory picker used by Settings and Onboarding to pick the
    /// capture folder. Returns nil when the user cancels.
    @MainActor
    static func chooseFolder(startingAt: URL, prompt: String, message: String? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = startingAt
        panel.prompt = prompt
        if let message {
            panel.message = message
        }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
