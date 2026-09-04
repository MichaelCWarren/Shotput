import Testing
import Foundation
@testable import Shotput

@Suite @MainActor struct ObservationLoopTests {
    @Test func reArmsAfterEachChange() async throws {
        let settings = testSettings(folder: try makeTempDir())
        var callCount = 0
        let token = ObservationLoop.track {
            _ = settings.keepPinned
        } onChange: {
            callCount += 1
        }
        defer { token.cancel() }

        // Each toggle waits for its own callback instead of a fixed 50 ms,
        // which is both the point of the test and the only way a slow
        // machine does not look like a missed re-arm.
        settings.keepPinned.toggle()
        #expect(await poll { callCount == 1 })
        settings.keepPinned.toggle()
        #expect(await poll { callCount == 2 })
        settings.keepPinned.toggle()
        #expect(await poll { callCount == 3 })

        #expect(callCount == 3)
    }

    @Test func cancelStopsCallbacks() async throws {
        let settings = testSettings(folder: try makeTempDir())
        var callCount = 0
        let token = ObservationLoop.track {
            _ = settings.keepPinned
        } onChange: {
            callCount += 1
        }
        token.cancel()

        settings.keepPinned.toggle()
        try await settle(0.05)

        #expect(callCount == 0)
    }
}
