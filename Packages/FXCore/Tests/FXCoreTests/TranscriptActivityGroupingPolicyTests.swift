import Foundation
import Testing
@testable import FXCore

@Test func assistantNarrativeRemainsOutsideToolGroupsInChronologicalOrder() {
    let opening = message(.assistant, .text("I'll inspect the current implementation."))
    let read = message(.assistant, .toolUse(id: "read", name: "Read", input: "{}"))
    let readResult = message(.tool, .toolResult(id: "read", content: "source", isError: false))
    let update = message(.assistant, .text("I found the issue and am applying the fix."))
    let edit = message(.assistant, .toolUse(id: "edit", name: "Edit", input: "{}"))
    let editResult = message(.tool, .toolResult(id: "edit", content: "updated", isError: false))
    let completion = message(.assistant, .text("The fix is complete."))
    let source = [opening, read, readResult, update, edit, editResult, completion]

    let segments = TranscriptActivityGroupingPolicy.segments(from: source)

    #expect(segments == [
        .narrative([opening]),
        .activity([read, readResult]),
        .narrative([update]),
        .activity([edit, editResult]),
        .narrative([completion]),
    ])
    #expect(segments.flatMap(\.messages) == source)
}

@Test func mixedNarrativeAndToolContentIsNeverHiddenAsActivity() {
    let mixed = ConversationMessage(
        role: .assistant,
        content: [
            .text("I am checking this now."),
            .toolUse(id: "shell", name: "Bash", input: "{}"),
        ]
    )

    #expect(
        TranscriptActivityGroupingPolicy.segments(from: [mixed])
            == [.narrative([mixed])]
    )
}

@Test func userQuestionsRemainNarrativeInsteadOfBackgroundActivity() {
    let question = message(
        .assistant,
        .toolUse(id: "question", name: "AskUserQuestion", input: "{}")
    )

    #expect(
        TranscriptActivityGroupingPolicy.segments(from: [question])
            == [.narrative([question])]
    )
}

private func message(
    _ role: MessageRole,
    _ content: MessageContent
) -> ConversationMessage {
    ConversationMessage(role: role, content: [content])
}

private extension TranscriptActivitySegment {
    var messages: [ConversationMessage] {
        switch self {
        case .narrative(let messages), .activity(let messages):
            messages
        }
    }
}
