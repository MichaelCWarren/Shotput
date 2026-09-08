import Testing
import Foundation
@testable import Shotput

@Suite struct AboutTests {
    @Test func versionTextPairsTheMarketingVersionWithTheBuild() {
        #expect(AppVersion.text(short: "0.1.0", build: "12") == "Version 0.1.0 (12)")
        // A build that just repeats the version says nothing worth the parens.
        #expect(AppVersion.text(short: "0.1.0", build: "0.1.0") == "Version 0.1.0")
        #expect(AppVersion.text(short: "0.1.0", build: nil) == "Version 0.1.0")
        #expect(AppVersion.text(short: nil, build: "12") == "Version unknown")
    }

    @Test func versionTextReadsTheAppsOwnInfoPlist() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )

        // The window shows whatever these two keys say, so an empty one would
        // ship an About box reading "Version unknown".
        let text = AppVersion.text(
            short: plist["CFBundleShortVersionString"] as? String,
            build: plist["CFBundleVersion"] as? String
        )
        #expect(text != "Version unknown")
        #expect(text.hasPrefix("Version "))
    }

    @Test func statsCountAndSumTheWholeStore() {
        let shots = [
            Screenshot(url: URL(fileURLWithPath: "/tmp/a.png"), created: Date(), byteSize: 1_000_000, isPinned: true),
            Screenshot(url: URL(fileURLWithPath: "/tmp/b.png"), created: Date(), byteSize: 2_000_000),
            Screenshot(url: URL(fileURLWithPath: "/tmp/c.png"), created: Date(), byteSize: 3_000_000, isPinned: true)
        ]
        let stats = aboutStats(for: shots)

        #expect(stats.captured == 3.formatted())
        #expect(stats.pinned == 2.formatted())
        #expect(stats.size == ByteCountFormatter.string(fromByteCount: 6_000_000, countStyle: .file))
    }

    @Test func emptyStoreStillReads() {
        let stats = aboutStats(for: [])
        #expect(stats.captured == 0.formatted())
        #expect(stats.pinned == 0.formatted())
        #expect(hoardQuip(count: 0) == "Nothing captured yet. Enjoy the silence.")
    }

    @Test func everyCountGetsAQuipAndEveryQuipIsDifferent() {
        let quips = [0, 10, 100, 500, 5_000].map(hoardQuip(count:))
        #expect(Set(quips).count == quips.count)
        #expect(quips.allSatisfy { !$0.isEmpty })
        #expect(aboutTaglines.count > 1)
    }
}
