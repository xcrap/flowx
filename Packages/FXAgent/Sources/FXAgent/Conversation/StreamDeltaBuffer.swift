import Foundation

/// Publishes the first token immediately, then coalesces bursts to a bounded
/// UI cadence. A trailing timer also delivers text when the provider pauses.
@MainActor
final class StreamDeltaBuffer {
    private let interval: Duration
    private let publish: (String) -> Void
    private let clock = ContinuousClock()
    private var lastFlush: ContinuousClock.Instant?
    private var pending = ""
    private var flushTask: Task<Void, Never>?

    init(interval: Duration = .milliseconds(50), publish: @escaping (String) -> Void) {
        self.interval = interval
        self.publish = publish
    }

    func append(_ delta: String) {
        guard !delta.isEmpty else { return }
        pending.append(delta)
        guard let lastFlush else {
            flush()
            return
        }
        let deadline = lastFlush.advanced(by: interval)
        if clock.now >= deadline {
            flush()
        } else if flushTask == nil {
            flushTask = Task { [weak self] in
                do {
                    try await Task.sleep(until: deadline, clock: .continuous)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.flush()
            }
        }
    }

    func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard !pending.isEmpty else { return }
        let delta = pending
        pending = ""
        lastFlush = clock.now
        publish(delta)
    }

    func discard() {
        flushTask?.cancel()
        flushTask = nil
        pending = ""
    }
}
