import Foundation
import Testing
@testable import FXCore

private func message(_ role: MessageRole, _ text: String) -> ConversationMessage {
    ConversationMessage(role: role, content: [.text(text)])
}

@Test func transcriptCacheRebuildsOnlyChangedTurns() throws {
    var cache = TranscriptTurnCache<String>()
    var messages = (0..<100).flatMap { [message(.user, "Prompt \($0)"), message(.assistant, "Reply \($0)")] }
    var rebuilt = 0
    let transform: ([ConversationMessage], Bool) -> [String] = { turn, active in
        rebuilt += turn.count
        return turn.map { $0.textContent + (active ? ":active" : "") }
    }
    let initial = try cache.render(messages: messages, isRunning: true, transform: transform)
    #expect(rebuilt == 200)

    messages.append(message(.assistant, "More"))
    rebuilt = 0
    let updated = try cache.render(messages: messages, isRunning: true, transform: transform)
    #expect(rebuilt == 3)
    #expect(updated.dropLast() == initial[...])
    #expect(updated.last == "More:active")

    rebuilt = 0
    _ = try cache.render(messages: messages, isRunning: false, transform: transform)
    #expect(rebuilt == 3)
    rebuilt = 0
    _ = try cache.render(messages: messages, isRunning: false, transform: transform)
    #expect(rebuilt == 0)
}

@Test func transcriptCacheDetectsSameIDEditsAndPrunesRetainedHistory() throws {
    var cache = TranscriptTurnCache<ConversationMessage>()
    var messages = [message(.user, "First"), message(.assistant, "Reply"), message(.user, "Second")]
    _ = try cache.render(messages: messages, isRunning: false) { turn, _ in turn }
    messages[1].content = [.text("Corrected"), .toolResult(id: "tool", content: "Late result", isError: true)]
    let changed = try cache.render(messages: messages, isRunning: false) { turn, _ in turn }
    #expect(changed == messages)
    messages.removeFirst() // Retention can cut through a turn.
    let trimmed = try cache.render(messages: messages, isRunning: false) { turn, _ in turn }
    #expect(trimmed == messages)
    _ = try cache.render(messages: [], isRunning: false) { turn, _ in turn }
    var rebuilt = 0
    _ = try cache.render(messages: messages, isRunning: false) { turn, _ in
        rebuilt += turn.count
        return turn
    }
    #expect(rebuilt == messages.count)
}

@Test func transcriptCacheKeepsPreviousSnapshotAfterFailedRender() throws {
    enum Failure: Error { case interrupted }
    var cache = TranscriptTurnCache<ConversationMessage>()
    let original = [message(.user, "First"), message(.assistant, "Reply")]
    _ = try cache.render(messages: original, isRunning: false) { turn, _ in turn }
    let newer = original + [message(.user, "Second")]
    #expect(throws: Failure.self) {
        try cache.render(messages: newer, isRunning: false) { _, _ in throw Failure.interrupted }
    }
    let restored = try cache.render(messages: original, isRunning: false) { _, _ in
        Issue.record("An interrupted render discarded a valid cached turn")
        return []
    }
    #expect(restored == original)
}

@Test func transcriptCacheIncludesLeadingToolsAndUserBoundaries() throws {
    var cache = TranscriptTurnCache<ConversationMessage>()
    let messages = [message(.tool, "Orphan"), message(.user, "A"), message(.user, "B"), message(.assistant, "C")]
    var activeTurns: [Bool] = []
    let output = try cache.render(messages: messages, isRunning: true) { turn, active in
        activeTurns.append(active)
        return turn
    }
    #expect(output == messages)
    #expect(activeTurns == [false, false, true])
}
