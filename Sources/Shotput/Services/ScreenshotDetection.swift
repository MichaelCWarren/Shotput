import Foundation

enum ScreenshotDetection {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif"]

    static func isScreenshot(_ url: URL) -> Bool {
        guard hasImageExtension(url) else { return false }
        return hasScreenCaptureXattr(url) || matchesNamePattern(url.lastPathComponent)
    }

    static func hasImageExtension(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// `screencapture` tags every file it writes with this xattr (a bplist);
    /// its presence is enough, so this never decodes the value.
    static func hasScreenCaptureXattr(_ url: URL) -> Bool {
        let name = "com.apple.metadata:kMDItemIsScreenCapture"
        return url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return getxattr(path, name, nil, 0, 0, 0) > 0
        }
    }

    /// Fallback for files that lose the xattr, e.g. copied from another Mac
    /// or saved by an older macOS: macOS's own naming, `Screenshot 2026-09-03 at 9.41.02.png`
    /// or the older `Screen Shot 2021-01-01 at 1.00.00.png`.
    static func matchesNamePattern(_ fileName: String) -> Bool {
        let range = NSRange(fileName.startIndex..., in: fileName)
        return namePattern.firstMatch(in: fileName, range: range) != nil
    }

    /// Compiled once: a rescan runs this over every non-xattr file in the folder.
    private static let namePattern = try! NSRegularExpression(
        pattern: "^screen ?shot \\d{4}-\\d{2}-\\d{2} at ",
        options: [.caseInsensitive]
    )
}
