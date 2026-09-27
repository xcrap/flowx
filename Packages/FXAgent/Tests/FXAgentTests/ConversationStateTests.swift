import Foundation
import Testing
@testable import FXAgent

@Test @MainActor func draftFlagTracksOnlyBlankToNonBlankTransitions() {
    let state = ConversationState(agentID: UUID())
    #expect(!state.hasDraftText)

    state.inputText = "  \n\t"
    #expect(!state.hasDraftText)

    state.inputText = " hello"
    #expect(state.hasDraftText)

    state.inputText = " hello world"
    #expect(state.hasDraftText)

    state.inputText = ""
    #expect(!state.hasDraftText)
}
