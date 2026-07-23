import Foundation

public enum ConversationImagePersistencePolicy {
    /// Image assets are persisted independently from any transcript cache
    /// truncation so an early prompt cannot lose its attachment after a long
    /// provider turn emits many later messages.
    public static func materializationMessages(
        from messages: [ConversationMessage]
    ) -> [ConversationMessage] {
        messages.filter { message in
            message.content.contains { content in
                switch content {
                case .image, .imageAsset:
                    true
                default:
                    false
                }
            }
        }
    }

    public static func mergingMaterializationMessages(
        existing: [ConversationMessage],
        newer: [ConversationMessage],
        limit: Int = 250
    ) -> [ConversationMessage] {
        guard limit > 0 else { return [] }
        var order: [UUID] = []
        var messagesByID: [UUID: ConversationMessage] = [:]
        for message in existing + newer {
            if messagesByID[message.id] == nil {
                order.append(message.id)
            }
            messagesByID[message.id] = message
        }
        if order.count > limit {
            order.removeFirst(order.count - limit)
        }
        return order.compactMap { messagesByID[$0] }
    }
}
