import Testing
import Foundation
@testable import Shotput

/// `annotate` and `revealInFinder` launch other apps and are not
/// unit-tested; see the spec's Verification section for the manual checks.
@Suite struct ActionsTests {
    @Test func trashMovesFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeScreenshotFile(in: dir, name: "trash-me.png")

        let moved = try ScreenshotActions.trash([url])
        defer { try? FileManager.default.removeItem(at: moved[0]) }

        #expect(moved.count == 1)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: moved[0].path))
    }

    @Test func deleteRemovesFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeScreenshotFile(in: dir, name: "delete-me.png")

        try ScreenshotActions.delete([url])

        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func removeDispatchesOnAction() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let trashURL = try makeScreenshotFile(in: dir, name: "trash-dispatch.png")
        let deleteURL = try makeScreenshotFile(in: dir, name: "delete-dispatch.png")

        try ScreenshotActions.remove([trashURL], action: .trash)
        #expect(!FileManager.default.fileExists(atPath: trashURL.path))
        if let trashDir = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first {
            let trashed = trashDir.appendingPathComponent(trashURL.lastPathComponent)
            #expect(FileManager.default.fileExists(atPath: trashed.path))
            try? FileManager.default.removeItem(at: trashed)
        }

        try ScreenshotActions.remove([deleteURL], action: .delete)
        #expect(!FileManager.default.fileExists(atPath: deleteURL.path))
    }
}
