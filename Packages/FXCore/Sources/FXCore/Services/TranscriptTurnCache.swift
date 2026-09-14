import Foundation

/// Reuses the presentation of unchanged turns. Equality includes the complete
/// message, so native transcript refreshes and image materialization can keep
/// message IDs without leaving stale content on screen.
public struct TranscriptTurnCache<Output: Sendable>: Sendable {
    private struct Entry: Sendable {
        let messages: [ConversationMessage]
        let isActive: Bool
        let output: [Output]
    }

    private var entries: [UUID: Entry] = [:]

    public init() {}

    public mutating func render(
        messages: [ConversationMessage],
        isRunning: Bool,
        transform: ([ConversationMessage], Bool) throws -> [Output]
    ) throws -> [Output] {
        var nextEntries: [UUID: Entry] = [:]
        var output: [Output] = []
        var start = messages.startIndex

        func appendTurn(endingAt end: Int) throws {
            guard start < end else { return }
            try Task.checkCancellation()
            let turn = Array(messages[start..<end])
            let id = turn[0].id
            let isActive = isRunning && end == messages.endIndex
            let entry: Entry
            if let cached = entries[id], cached.isActive == isActive,
               cached.messages == turn {
                entry = cached
            } else {
                entry = Entry(
                    messages: turn,
                    isActive: isActive,
                    output: try transform(turn, isActive)
                )
            }
            nextEntries[id] = entry
            output.append(contentsOf: entry.output)
            start = end
        }

        for index in messages.indices where messages[index].role == .user {
            try appendTurn(endingAt: index)
        }
        try appendTurn(endingAt: messages.endIndex)
        try Task.checkCancellation()
        // Commit only after a successful render; prune everything that fell out
        // of the retained transcript, including empty/replaced conversations.
        entries = nextEntries
        return output
    }
}
