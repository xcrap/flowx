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

/// Reveal the transcript once its geometry converges, instead of imposing a
/// half-second delay on every task switch. A late document resize is followed
/// separately by the scroll coordinator.
public struct ConversationScrollRestoration: Sendable {
    private var previousMaxOffset: CGFloat?
    private var stablePasses = 0

    public init() {}

    public mutating func observe(
        maxOffset: CGFloat,
        desiredOffset: CGFloat,
        stickToBottom: Bool
    ) -> Bool {
        let targetAvailable = stickToBottom || desiredOffset <= maxOffset + 0.5
        if targetAvailable, let previousMaxOffset,
           abs(previousMaxOffset - maxOffset) <= 0.5 {
            stablePasses += 1
        } else {
            stablePasses = 0
        }
        previousMaxOffset = maxOffset
        return stablePasses >= 3
    }
}
