import Foundation
import Observation

/// Handle returned by `ObservationLoop.track`. `withObservationTracking`
/// fires its `onChange` once and then stops, so anything that wants to keep
/// observing has to re-arm itself after every change; this is that loop,
/// shared so `ScreenshotStore` and `CleanupScheduler` don't each write it.
final class ObservationToken {
    fileprivate var isCancelled = false

    func cancel() {
        isCancelled = true
    }

    deinit {
        cancel()
    }
}

enum ObservationLoop {
    @MainActor
    static func track(_ read: @escaping () -> Void, onChange: @escaping @MainActor () -> Void) -> ObservationToken {
        let token = ObservationToken()
        arm(token, read: read, onChange: onChange)
        return token
    }

    @MainActor
    private static func arm(_ token: ObservationToken, read: @escaping () -> Void, onChange: @escaping @MainActor () -> Void) {
        withObservationTracking(read) {
            // Fires from willSet, before the new value lands, so hop to the
            // main actor before re-reading or calling back.
            DispatchQueue.main.async {
                guard !token.isCancelled else { return }
                onChange()
                arm(token, read: read, onChange: onChange)
            }
        }
    }
}
