import Foundation

/// What the AI layer has to say about one screenshot, as a single value so a
/// row or a tile switches once instead of combining flags.
enum AIState: Equatable {
    /// Nothing to show: AI is off, or this URL isn't tracked. A stored
    /// description is not lost while AI is off, it just isn't AI state.
    case off
    case queued
    case describing
    /// Failed, still has attempts left.
    case retrying(attempt: Int)
    /// Out of attempts. Stays this way until the user retries it. `detail`
    /// is the long form for a tooltip, nil when it would only repeat
    /// `reason`.
    case gaveUp(reason: String, detail: String?)
    case described
}

/// One line of the Settings status section.
struct AIStatus: Equatable {
    var describedCount: Int
    var pendingCount: Int
    var failedCount: Int
    var isRunning: Bool
    var blockedReason: String?
    var lastError: String?
}

/// A given-up screenshot, ready to list.
struct AIFailureItem: Identifiable, Equatable {
    var url: URL
    var reason: String
    var failedAt: Date
    var attempts: Int
    /// Longer than `reason` and meant for a tooltip, when there is more to
    /// say than the row has room for.
    var detail: String?

    var id: URL { url }
}
