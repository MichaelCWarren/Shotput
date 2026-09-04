import Testing
import AppKit
@testable import Shotput

/// Each test uses a private named pasteboard and releases it, so the user's
/// real clipboard is never touched.
@Suite struct ClipboardTests {
    @Test func copyImagesWritesOneItemPerFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try makeScreenshotFile(in: dir, name: "a.png")
        let b = try makeScreenshotFile(in: dir, name: "b.png")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ShotputTests-\(UUID())"))
        defer { pasteboard.releaseGlobally() }

        #expect(Clipboard.copyImages([a, b], to: pasteboard))

        let items = try #require(pasteboard.pasteboardItems)
        #expect(items.count == 2)
        for item in items {
            #expect(item.types.contains(.fileURL))
            #expect(item.types.contains(.png))
        }
        #expect(pasteboard.readObjects(forClasses: [NSImage.self])?.count == 2)
    }

    @Test func missingFileLeavesExistingClipboardAlone() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try makeScreenshotFile(in: dir, name: "a.png")
        let trashed = dir.appendingPathComponent("gone.png")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ShotputTests-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("unchanged", forType: .string)
        let changeCountBefore = pasteboard.changeCount

        #expect(!Clipboard.copyImages([a, trashed], to: pasteboard))

        #expect(pasteboard.changeCount == changeCountBefore)
        #expect(pasteboard.string(forType: .string) == "unchanged")
    }

    @Test func copyTextWritesString() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ShotputTests-\(UUID())"))
        defer { pasteboard.releaseGlobally() }

        Clipboard.copyText("hello", to: pasteboard)

        #expect(pasteboard.string(forType: .string) == "hello")
    }

    @Test func emptyArrayReturnsFalse() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ShotputTests-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("unchanged", forType: .string)
        let changeCountBefore = pasteboard.changeCount

        #expect(!Clipboard.copyImages([], to: pasteboard))

        #expect(pasteboard.changeCount == changeCountBefore)
        #expect(pasteboard.string(forType: .string) == "unchanged")
    }
}
