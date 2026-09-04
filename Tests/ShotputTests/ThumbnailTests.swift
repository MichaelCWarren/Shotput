import Testing
import AppKit
@testable import Shotput

/// Each test builds its own `ThumbnailCache()` (its `init()` is internal for
/// exactly this reason) instead of `.shared`, so parallel tests never see
/// each other's entries.
@Suite struct ThumbnailTests {
    @Test func generatesImageForPNG() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeTextImage("thumb", size: NSSize(width: 40, height: 30), in: dir)
        let cache = ThumbnailCache()

        let image = try #require(await cache.thumbnail(for: url))

        #expect(image.size.width > 0)
    }

    @Test func secondCallIsCached() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeTextImage("thumb", size: NSSize(width: 40, height: 30), in: dir)
        let cache = ThumbnailCache()

        let first = await cache.thumbnail(for: url)
        let second = await cache.thumbnail(for: url)

        #expect(first === second)
    }

    @Test func evictForcesRegeneration() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeTextImage("thumb", size: NSSize(width: 40, height: 30), in: dir)
        let cache = ThumbnailCache()

        let first = await cache.thumbnail(for: url)
        cache.evict(url)
        let second = await cache.thumbnail(for: url)

        #expect(first !== second)
    }

    @Test func nilResultIsCachedUntilEvicted() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("missing.png")
        // Pinned rather than left at the 10 s default, which a loaded machine
        // can outlast between the two lookups below. What this test is about
        // is evict(), so the TTL wants to be out of the way, not merely long.
        let cache = ThumbnailCache(failureTTL: .seconds(3600))

        let first = await cache.thumbnail(for: url)
        #expect(first == nil)

        // A file now exists at the same path, but the cached miss should
        // still win until something evicts it.
        try makePNG(at: url)
        let stillNil = await cache.thumbnail(for: url)
        #expect(stillNil == nil)

        cache.evict(url)
        let afterEvict = await cache.thumbnail(for: url)
        #expect(afterEvict != nil)
    }

    @Test func nilResultExpiresAfterFailureTTL() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("late.png")
        let cache = ThumbnailCache(failureTTL: .zero)

        #expect(await cache.thumbnail(for: url) == nil)

        // The transient failure clears once the file lands: the expired miss
        // no longer masks it.
        try makePNG(at: url)
        let recovered = await cache.thumbnail(for: url)
        #expect(recovered != nil)

        // A real thumbnail carries no expiry, so it survives a zero TTL.
        #expect(await cache.thumbnail(for: url) === recovered)
    }
}

private func makePNG(at url: URL) throws {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let data = try #require(rep.representation(using: .png, properties: [:]))
    try data.write(to: url)
}
