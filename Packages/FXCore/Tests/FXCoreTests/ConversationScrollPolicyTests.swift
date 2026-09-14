import Foundation
import Testing
@testable import FXCore

@Test func conversationRestoreFinishesAsSoonAsGeometryStabilizes() {
    var restoration = ConversationScrollRestoration()
    let results = (0..<4).map { _ in
        restoration.observe(maxOffset: 500, desiredOffset: 9_000, stickToBottom: true)
    }
    #expect(results == [false, false, false, true])
}

@Test func conversationRestoreWaitsForLayoutChangesAndSavedOffset() {
    var restoration = ConversationScrollRestoration()
    for _ in 0..<10 {
        let ready = restoration.observe(maxOffset: 100, desiredOffset: 500, stickToBottom: false)
        #expect(!ready)
    }
    for height in [600, 650, 700, 700, 700] {
        let ready = restoration.observe(maxOffset: CGFloat(height), desiredOffset: 500, stickToBottom: false)
        #expect(!ready)
    }
    let ready = restoration.observe(maxOffset: 700, desiredOffset: 500, stickToBottom: false)
    #expect(ready)
}

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
