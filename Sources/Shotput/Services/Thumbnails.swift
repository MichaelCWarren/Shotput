import AppKit
import QuickLookThumbnailing

/// One thumbnail representation per URL, sized to cover every screen that
/// shows one (56×36 dropdown rows up to ~120×76 library tiles); each just
/// scales this down.
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    /// Thumbnails run ~311KB each (172×116 @2x, 4 bytes/px); 64MB holds
    /// ~200, more than any scroll window needs, and NSCache evicts the rest
    /// under memory pressure so a library of thousands never blows past it.
    private static let totalCostLimit = 64 * 1024 * 1024

    /// A failure is cached only for a while. Long enough that scrolling past
    /// a file QuickLook can't render doesn't re-ask for every row, short
    /// enough that a screenshot caught while `screencapture` was still
    /// writing it, or a QuickLook XPC hiccup, recovers on a later look.
    private static let defaultFailureTTL: Duration = .seconds(10)

    private let cache = NSCache<NSURL, CachedThumbnail>()
    private let inFlight = InFlightTasks()
    private let failureTTL: Duration

    init(failureTTL: Duration = ThumbnailCache.defaultFailureTTL) {
        self.failureTTL = failureTTL
        cache.totalCostLimit = Self.totalCostLimit
    }

    func thumbnail(for url: URL) async -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL), !cached.hasExpired {
            return cached.image
        }

        let task = await inFlight.task(for: url) {
            await Self.generate(for: url)
        }
        let result = await task.value
        let expiresAt = result == nil ? ContinuousClock.now + failureTTL : nil
        cache.setObject(CachedThumbnail(image: result, expiresAt: expiresAt), forKey: url as NSURL, cost: Self.cost(for: result))
        await inFlight.removeTask(for: url)
        return result
    }

    func evict(_ url: URL) {
        cache.removeObject(forKey: url as NSURL)
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    private static func generate(for url: URL) async -> NSImage? {
        let size = CGSize(width: 172, height: 116)
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: 2, representationTypes: .thumbnail)

        let generated: NSImage? = await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.nsImage)
            }
        }
        return generated ?? NSImage(contentsOf: url)
    }

    /// A failed generation costs almost nothing to hold, so caching a miss
    /// never meaningfully eats into the budget for real thumbnails.
    private static func cost(for image: NSImage?) -> Int {
        guard let rep = image?.representations.first else {
            return 64
        }
        return rep.pixelsWide * rep.pixelsHigh * 4
    }
}

/// `NSCache` cannot store `nil` directly, so a failed generation is boxed
/// here and cached like any other result, which is what stops a file
/// QuickLook can't render from being regenerated on every scroll. Only
/// failures carry an expiry; a real thumbnail never goes stale.
private final class CachedThumbnail {
    let image: NSImage?
    let expiresAt: ContinuousClock.Instant?

    init(image: NSImage?, expiresAt: ContinuousClock.Instant?) {
        self.image = image
        self.expiresAt = expiresAt
    }

    var hasExpired: Bool {
        guard let expiresAt else { return false }
        return ContinuousClock.now >= expiresAt
    }
}

/// Serializes access to the per-URL in-flight task map, so two concurrent
/// first calls for one URL share a single generation instead of racing.
/// `NSCache` is already thread-safe; a plain dictionary here isn't.
private actor InFlightTasks {
    private var tasks: [URL: Task<NSImage?, Never>] = [:]

    func task(for url: URL, generate: @escaping @Sendable () async -> NSImage?) -> Task<NSImage?, Never> {
        if let existing = tasks[url] {
            return existing
        }
        let task = Task { await generate() }
        tasks[url] = task
        return task
    }

    func removeTask(for url: URL) {
        tasks.removeValue(forKey: url)
    }
}
