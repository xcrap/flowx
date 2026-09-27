import Foundation
import Testing
@testable import FXAgent
@testable import FXCore

/// Mirrors `ConversationView`: a new `messageRevision` is rendered off the
/// main actor through a turn cache, then installed on the main actor.
@MainActor
private final class TranscriptRenderModel {
    private static let executor = BoundedTaskExecutor(maxConcurrentTasks: 2)
    let state: ConversationState
    private(set) var renderedRevision = Int.min
    private(set) var renderedIDs: Set<UUID> = []
    private var cache = TranscriptTurnCache<String>()

    init(state: ConversationState) {
        self.state = state
    }

    func render() async throws {
        let revision = state.messageRevision
        let messages = state.messages
        let previous = cache
        let (next, _) = try await Self.executor.run(priority: .userInitiated) {
            var cache = previous
            let output = try cache.render(messages: messages, isRunning: false) { turn, _ in
                turn.map { TranscriptPresentationParser.assistantMessage($0.textContent).visibleText }
            }
            return (cache, output)
        }
        cache = next
        renderedRevision = revision
        renderedIDs = Set(messages.map(\.id))
    }
}

private struct HandoffSample {
    var blankTurns = 0
    var totalTurns = 0
    var finishToInstall = Duration.zero
}

/// Streams a reply, finishes it, and samples every main-actor turn until the
/// render for the finished message installs.
@MainActor
private func streamAndFinish(
    _ model: TranscriptRenderModel,
    reply: String,
    isReplyVisible: (TranscriptRenderModel, UUID?) -> Bool
) async throws -> HandoffSample {
    let state = model.state
    state.appendUserMessage("Prompt \(state.messageRevision)")
    try await model.render()
    state.startStreaming()
    var index = reply.startIndex
    while index < reply.endIndex {
        let next = reply.index(index, offsetBy: 64, limitedBy: reply.endIndex) ?? reply.endIndex
        state.appendStreamDelta(String(reply[index..<next]))
        index = next
    }

    let clock = ContinuousClock()
    let finishedAt = clock.now
    state.finishStreaming(stopReason: "end_turn")
    let messageID = state.messages.last?.id
    let render = Task { @MainActor in try await model.render() }
    var sample = HandoffSample()
    while model.renderedRevision < state.messageRevision {
        sample.totalTurns += 1
        if !isReplyVisible(model, messageID) { sample.blankTurns += 1 }
        await Task.yield()
    }
    try await render.value
    sample.finishToInstall = finishedAt.duration(to: clock.now)
    #expect(isReplyVisible(model, messageID))
    return sample
}

/// Before: the tail showed only `streamingText`, which `finishStreaming`
/// clears in the same pass that appends the message.
@MainActor
private func replyVisibleFromStreamingTextOnly(_ model: TranscriptRenderModel, _ messageID: UUID?) -> Bool {
    !model.state.streamingText.isEmpty || messageID.map(model.renderedIDs.contains) == true
}

/// Now: the tail also shows the reply handed off by `finishStreaming` until
/// the render for its message revision is installed.
@MainActor
private func replyVisibleWithHandoff(_ model: TranscriptRenderModel, _ messageID: UUID?) -> Bool {
    let handoff = model.state.pendingStreamingHandoff(renderedMessageRevision: model.renderedRevision)
    return handoff != nil || replyVisibleFromStreamingTextOnly(model, messageID)
}

@Test @MainActor func finishedReplyStaysVisibleUntilItsRenderInstalls() async throws {
    let state = ConversationState(agentID: UUID())
    let model = TranscriptRenderModel(state: state)
    let before = try await streamAndFinish(model, reply: "Hello\n\nWorld", isReplyVisible: replyVisibleFromStreamingTextOnly)
    #expect(before.blankTurns > 0)
    let after = try await streamAndFinish(model, reply: "Hello again", isReplyVisible: replyVisibleWithHandoff)
    #expect(after.totalTurns > 0)
    #expect(after.blankTurns == 0)
}

@Test @MainActor func streamingHandoffKeepsTheSegmentIdentityAndEndsAtItsRevision() {
    let state = ConversationState(agentID: UUID())
    state.startStreaming()
    state.appendStreamDelta("Checking the files")
    let streamingSegment = state.streamingSegment
    let renderedBeforeFinish = state.messageRevision
    state.finishStreaming(stopReason: "tool_use")
    // A tool call starts the next stream straight away.
    state.startStreaming()
    state.appendMessage(ConversationMessage(role: .assistant, content: [.toolUse(id: "t", name: "Read", input: "{}")]))

    let handoff = state.pendingStreamingHandoff(renderedMessageRevision: renderedBeforeFinish)
    #expect(handoff?.text == "Checking the files")
    #expect(handoff?.segment == streamingSegment)
    #expect(state.streamingSegment != streamingSegment)
    #expect(state.pendingStreamingHandoff(renderedMessageRevision: handoff?.messageRevision ?? 0) == nil)
    #expect(state.pendingStreamingHandoff(renderedMessageRevision: state.messageRevision) == nil)

    state.finishStreaming()
    #expect(state.pendingStreamingHandoff(renderedMessageRevision: renderedBeforeFinish)?.text == "Checking the files")
    state.resetConversation()
    #expect(state.pendingStreamingHandoff(renderedMessageRevision: Int.min) == nil)
}

/// Opt-in benchmark of the stream-end gap. Run with `make benchmark-chat`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["FLOWX_BENCHMARK_CHAT"] == "1"))
@MainActor func benchmarkStreamEndHandoff() async throws {
    let state = ConversationState(agentID: UUID())
    let paragraph = String(repeating: "A detailed explanation of the updated project and its rendering behavior. ", count: 12)
    state.replaceMessages((0..<124).flatMap { index in
        [
            ConversationMessage(role: .user, content: [.text("Prompt \(index)")]),
            ConversationMessage(role: .assistant, content: [.text(paragraph)]),
        ]
    })
    let model = TranscriptRenderModel(state: state)
    try await model.render()
    let reply = (0..<16).map { "\($0 + 1). \(paragraph)" }.joined(separator: "\n\n")

    func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
    for (name, rule) in [
        ("streamingText only (before)", replyVisibleFromStreamingTextOnly),
        ("with hand-off (after)", replyVisibleWithHandoff),
    ] as [(String, @MainActor (TranscriptRenderModel, UUID?) -> Bool)] {
        var samples: [HandoffSample] = []
        for _ in 0..<20 {
            samples.append(try await streamAndFinish(model, reply: reply, isReplyVisible: rule))
        }
        let gaps = samples.map(\.finishToInstall).sorted()
        print(String(
            format: "HANDOFF BENCHMARK: %@: %d messages, %d KB reply: finish -> install p50 %.2f ms, max %.2f ms; reply blank on %d of %d sampled main-actor turns",
            name, state.messages.count, reply.utf8.count / 1_024,
            milliseconds(gaps[gaps.count / 2]), milliseconds(gaps[gaps.count - 1]),
            samples.reduce(0) { $0 + $1.blankTurns }, samples.reduce(0) { $0 + $1.totalTurns }
        ))
    }
}
