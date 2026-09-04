import Testing
import Foundation

@Suite struct InfoPlistTests {
    private var plistURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
    }

    @Test func requiredKeys() throws {
        let data = try Data(contentsOf: plistURL)
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )

        #expect(plist["LSUIElement"] as? Bool == true)
        #expect(plist["CFBundleIdentifier"] as? String == "com.shotput.app")
        #expect(plist["CFBundleExecutable"] as? String == "Shotput")
        #expect(plist["LSMinimumSystemVersion"] as? String == "26.0")
        #expect(plist["CFBundleIconFile"] as? String == "AppIcon")
        #expect(!(plist["NSDesktopFolderUsageDescription"] as? String ?? "").isEmpty)
    }
}
