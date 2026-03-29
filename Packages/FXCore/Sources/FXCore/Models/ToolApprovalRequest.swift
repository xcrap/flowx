import Foundation

public enum ToolRiskLevel: String, Codable, Sendable {
    case safe
    case moderate
    case dangerous
}

public enum ApprovalStatus: String, Codable, Sendable {
    case pending
    case approved
    case denied
}

public struct ToolApprovalRequest: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var toolName: String
    public var description: String
    public var parameters: [String: String]
    public var riskLevel: ToolRiskLevel
    public var agentID: UUID
    public var status: ApprovalStatus

    public init(
        id: UUID = UUID(),
        toolName: String,
        description: String,
        parameters: [String: String] = [:],
        riskLevel: ToolRiskLevel = .moderate,
        agentID: UUID,
        status: ApprovalStatus = .pending
    ) {
        self.id = id
        self.toolName = toolName
        self.description = description
        self.parameters = parameters
        self.riskLevel = riskLevel
        self.agentID = agentID
        self.status = status
    }
}
