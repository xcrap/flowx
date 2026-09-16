import Foundation
import Observation
import Testing
@testable import FXAgent

@Test @MainActor func failedBackgroundRetryPreservesVisibleErrorAndCachedRevision() {
    let state = NativeTranscriptRefreshState()
    let loadedAt = Date(timeIntervalSince1970: 100)
    state.succeed(revision: "last-good", loadedAt: loadedAt)
    state.fail("Session file missing", at: loadedAt)

    // SwiftUI observes these two values to add/remove the status row and
    // loading viewport. Neither may invalidate during a failing retry.
    let changed = ObservationChangeFlag()
    withObservationTracking {
        _ = state.error
        _ = state.isLoading
    } onChange: {
        changed.markChanged()
    }
    for _ in 0..<3 {
        state.begin(hasMessages: true)
        #expect(state.error == "Session file missing")
        #expect(!state.isLoading)
        state.fail("Session file missing", at: loadedAt)
    }
    #expect(!changed.didChange)
    #expect(state.loadedAt == loadedAt)
    #expect(state.revision == "last-good")
    state.succeed(revision: "recovered", loadedAt: loadedAt.addingTimeInterval(30))
    #expect(changed.didChange)
    #expect(state.error == nil)
}

@Test @MainActor func transcriptRefreshRetriesBackOffAndSuccessResetsThem() {
    let state = NativeTranscriptRefreshState()
    var now = Date(timeIntervalSince1970: 100)
    for delay: TimeInterval in [5, 10, 20, 40, 60, 60] {
        state.fail("Unavailable", at: now)
        #expect(!state.canRetry(at: now.addingTimeInterval(delay - 0.1)))
        #expect(state.canRetry(at: now.addingTimeInterval(delay)))
        now = now.addingTimeInterval(delay)
    }
    state.begin(hasMessages: true)
    #expect(state.error == "Unavailable")
    state.succeed(revision: "recovered", loadedAt: now)
    #expect(state.error == nil)
    #expect(state.canRetry(at: now))
    state.fail("Unavailable", at: now)
    #expect(state.retryAt == now.addingTimeInterval(5))
}

@Test @MainActor func cancelledRefreshDoesNotDiscardErrorOrChangeSuccessfulHistory() {
    let state = NativeTranscriptRefreshState()
    state.begin(hasMessages: false)
    #expect(state.isLoading)
    state.fail("Missing file")
    let retryAt = state.retryAt
    state.begin(hasMessages: false)
    state.cancel()
    #expect(!state.isLoading)
    #expect(state.error == "Missing file")
    #expect(state.retryAt == retryAt)
    #expect(state.loadedAt == nil)
}

private final class ObservationChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false

    var didChange: Bool {
        lock.lock()
        defer { lock.unlock() }
        return changed
    }

    func markChanged() {
        lock.lock()
        defer { lock.unlock() }
        changed = true
    }
}
