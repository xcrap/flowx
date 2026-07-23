import Foundation

/// Pure scroll geometry used by the conversation surface. Keeping this math
/// outside SwiftUI makes the restore and pinned-to-bottom contract testable
/// without recreating the view hierarchy.
public struct ConversationScrollMetrics: Equatable, Sendable {
    public let offset: CGFloat
    public let maxOffset: CGFloat

    public init(offset: CGFloat, maxOffset: CGFloat) {
        self.offset = offset
        self.maxOffset = maxOffset
    }
}

public enum ConversationScrollPolicy {
    public static let bottomTolerance: CGFloat = 24

    public static func shouldPersistUserScroll(
        initialRestorePending: Bool,
        userScrollInProgress: Bool
    ) -> Bool {
        !initialRestorePending && userScrollInProgress
    }

    public static func metrics(
        contentOffsetY: CGFloat,
        contentHeight: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat,
        containerHeight: CGFloat
    ) -> ConversationScrollMetrics {
        let maxOffset = max(
            0,
            contentHeight + topInset + bottomInset - containerHeight
        )
        let offset = max(
            0,
            min(contentOffsetY + topInset, maxOffset)
        )
        return ConversationScrollMetrics(offset: offset, maxOffset: maxOffset)
    }

    public static func isPinnedToBottom(
        _ metrics: ConversationScrollMetrics,
        tolerance: CGFloat = bottomTolerance
    ) -> Bool {
        metrics.maxOffset <= 1
            || metrics.offset >= metrics.maxOffset - max(0, tolerance)
    }
}
