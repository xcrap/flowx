import Foundation
import Testing
@testable import FXAgent

@Test @MainActor func streamBufferCoalescesBurstsAndFlushesBeforeCompletion() {
    var publications: [String] = []
    let buffer = StreamDeltaBuffer(interval: .seconds(10)) { publications.append($0) }
    buffer.append("First")
    #expect(publications == ["First"])
    for _ in 0..<1_000 { buffer.append("🐬") }
    #expect(publications.count == 1)
    buffer.flush()
    #expect(publications == ["First", String(repeating: "🐬", count: 1_000)])
    buffer.flush()
    #expect(publications.count == 2)
    buffer.discard()
}

@Test @MainActor func streamBufferPublishesTrailingTextDuringProviderPause() async throws {
    var publications: [String] = []
    let buffer = StreamDeltaBuffer(interval: .milliseconds(10)) { publications.append($0) }
    buffer.append("First")
    buffer.append("Last")
    // Yield until the trailing delivery happens; no third token is required.
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while publications.count < 2, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(publications == ["First", "Last"])
    buffer.discard()
}

@Test @MainActor func streamBufferDiscardCancelsTrailingDelivery() async throws {
    var publications: [String] = []
    let buffer = StreamDeltaBuffer(interval: .milliseconds(10)) { publications.append($0) }
    buffer.append("First")
    buffer.append("Discarded")
    buffer.discard()
    try await Task.sleep(for: .milliseconds(40))
    #expect(publications == ["First"])
}
