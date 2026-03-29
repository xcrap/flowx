import Foundation

public struct Agent: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var title: String
    public var configuration: AgentConfiguration
    public var executionState: AgentExecutionState
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        configuration: AgentConfiguration = AgentConfiguration(),
        executionState: AgentExecutionState = .idle
    ) {
        self.id = id
        self.title = title
        self.configuration = configuration
        self.executionState = executionState
        self.createdAt = Date()
    }
}

public enum AgentExecutionState: String, Codable, Sendable {
    case idle
    case running
    case success
    case failure
    case waitingForApproval
}
