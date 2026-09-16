import Foundation
import Observation

/// Refresh bookkeeping is independent of the displayed transcript. A retry
/// retains the last error until a successful read, so cached content and the
/// status row do not disappear while the provider is unavailable.
@Observable
@MainActor
public final class NativeTranscriptRefreshState {
    public private(set) var isLoading = false
    public private(set) var error: String?
    @ObservationIgnored public private(set) var loadedAt: Date?
    @ObservationIgnored public private(set) var revision: String?
    @ObservationIgnored public private(set) var retryAt: Date?
    @ObservationIgnored private var consecutiveFailures = 0

    public init() {}

    public func canRetry(at now: Date = Date()) -> Bool {
        retryAt.map { $0 <= now } ?? true
    }

    public func begin(hasMessages: Bool) {
        // Background retries must never replace a cached chat with a loader.
        if !hasMessages && error == nil && !isLoading { isLoading = true }
    }

    public func succeed(revision: String?, loadedAt: Date) {
        self.revision = revision
        self.loadedAt = loadedAt
        consecutiveFailures = 0
        retryAt = nil
        if error != nil { error = nil }
        cancel()
    }

    public func fail(_ message: String, at now: Date = Date()) {
        consecutiveFailures = min(consecutiveFailures + 1, 5)
        let delay = min(60, 5 * pow(2, Double(consecutiveFailures - 1)))
        retryAt = now.addingTimeInterval(delay)
        if error != message { error = message }
        cancel()
    }

    public func cancel() {
        if isLoading { isLoading = false }
    }
}
