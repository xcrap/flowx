import Foundation
import Testing
@testable import FXCore

@Test func conversationScrollMetricsIncludeInsetsAndClampToTheDocument() {
    let metrics = ConversationScrollPolicy.metrics(
        contentOffsetY: 480,
        contentHeight: 1_200,
        topInset: 20,
        bottomInset: 30,
        containerHeight: 400
    )

    #expect(metrics.offset == 500)
    #expect(metrics.maxOffset == 850)
}

@Test func conversationScrollMetricsClampTransientLayoutValues() {
    let beforeTop = ConversationScrollPolicy.metrics(
        contentOffsetY: -100,
        contentHeight: 300,
        topInset: 20,
        bottomInset: 20,
        containerHeight: 500
    )
    let beyondBottom = ConversationScrollPolicy.metrics(
        contentOffsetY: 2_000,
        contentHeight: 1_000,
        topInset: 0,
        bottomInset: 0,
        containerHeight: 400
    )

    #expect(beforeTop == ConversationScrollMetrics(offset: 0, maxOffset: 0))
    #expect(beyondBottom == ConversationScrollMetrics(offset: 600, maxOffset: 600))
}

@Test func conversationScrollPinnedStateUsesTheInteractionTolerance() {
    #expect(
        ConversationScrollPolicy.isPinnedToBottom(
            ConversationScrollMetrics(offset: 976, maxOffset: 1_000)
        )
    )
    #expect(
        !ConversationScrollPolicy.isPinnedToBottom(
            ConversationScrollMetrics(offset: 975, maxOffset: 1_000)
        )
    )
    #expect(
        ConversationScrollPolicy.isPinnedToBottom(
            ConversationScrollMetrics(offset: 0, maxOffset: 0)
        )
    )
}
