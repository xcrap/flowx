import Foundation

public enum ConversationRuntimeActivityKind: String, Codable, Sendable, Equatable {
    case session
    case queue
    case tool
    case contextCompaction
    case error
    case note
}

public enum ConversationRuntimeActivityTone: String, Codable, Sendable, Equatable {
    case info
    case working
    case success
    case warning
    case error
}

public struct ConversationRuntimeActivity: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var timestamp: Date
    public var kind: ConversationRuntimeActivityKind
    public var tone: ConversationRuntimeActivityTone
    public var summary: String
    public var detail: String?
    public var state: String?
    public var turnID: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        kind: ConversationRuntimeActivityKind,
        tone: ConversationRuntimeActivityTone,
        summary: String,
        detail: String? = nil,
        state: String? = nil,
        turnID: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.tone = tone
        self.summary = summary
        self.detail = detail
        self.state = state
        self.turnID = turnID
    }
}
