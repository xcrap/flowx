import Foundation
import FXCore

public enum ProviderSessionPhase: String, Codable, Sendable {
    case idle
    case preparing
    case responding
    case compacting
    case compacted
    case cancelling
    case failed

    public var isWorking: Bool {
        switch self {
        case .preparing, .responding, .compacting, .compacted, .cancelling:
            true
        case .idle, .failed:
            false
        }
    }

    public var statusLabel: String {
        switch self {
        case .idle:
            "Idle"
        case .preparing:
            "Starting"
        case .responding:
            "Working"
        case .compacting:
            "Compacting"
        case .compacted:
            "Compacted"
        case .cancelling:
            "Stopping"
        case .failed:
            "Error"
        }
    }
}

public enum ProviderLifecycleEvent: Sendable, Equatable {
    case turnStarted(turnID: String?)
    case phaseChanged(ProviderSessionPhase)
}

public struct ProviderStreamHandle: Sendable {
    public let stream: AsyncThrowingStream<StreamEvent, Error>
    public let cancel: @Sendable () async -> Void
    public let respondToApproval: @Sendable (UUID, Bool) async -> Void

    public init(
        stream: AsyncThrowingStream<StreamEvent, Error>,
        cancel: @escaping @Sendable () async -> Void,
        respondToApproval: @escaping @Sendable (UUID, Bool) async -> Void = { _, _ in }
    ) {
        self.stream = stream
        self.cancel = cancel
        self.respondToApproval = respondToApproval
    }
}

public enum ConversationGoalStatus: String, Codable, Sendable, Equatable {
    case active
    case paused
    case blocked
    case usageLimited
    case budgetLimited
    case complete

    public var label: String {
        switch self {
        case .active:
            "Active"
        case .paused:
            "Paused"
        case .blocked:
            "Blocked"
        case .usageLimited:
            "Usage limited"
        case .budgetLimited:
            "Budget limited"
        case .complete:
            "Complete"
        }
    }
}

public struct ConversationGoal: Codable, Sendable, Equatable {
    public var threadID: String
    public var objective: String
    public var status: ConversationGoalStatus
    public var tokensUsed: Int
    public var tokenBudget: Int?
    public var timeUsedSeconds: Int
    public var createdAt: Int
    public var updatedAt: Int

    public init(
        threadID: String,
        objective: String,
        status: ConversationGoalStatus,
        tokensUsed: Int,
        tokenBudget: Int?,
        timeUsedSeconds: Int,
        createdAt: Int,
        updatedAt: Int
    ) {
        self.threadID = threadID
        self.objective = objective
        self.status = status
        self.tokensUsed = tokensUsed
        self.tokenBudget = tokenBudget
        self.timeUsedSeconds = timeUsedSeconds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ProviderApprovalRequest: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var toolName: String
    public var description: String
    public var parameters: [String: String]
    public var riskLevel: ToolRiskLevel

    public init(
        id: UUID = UUID(),
        toolName: String,
        description: String,
        parameters: [String: String] = [:],
        riskLevel: ToolRiskLevel = .moderate
    ) {
        self.id = id
        self.toolName = toolName
        self.description = description
        self.parameters = parameters
        self.riskLevel = riskLevel
    }
}

public protocol AIProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var availableModels: [AIModel] { get }

    func sendMessage(
        prompt: String,
        attachments: [Attachment],
        messages: [ConversationMessage],
        model: String,
        effort: String?,
        systemPrompt: String?,
        agentMode: AgentMode?,
        agentAccess: AgentAccess?,
        workingDirectory: URL?,
        resumeSessionID: String?
    ) -> ProviderStreamHandle
}

public protocol AIProviderThreadControls: AIProvider {
    func setThreadGoal(
        objective: String?,
        status: ConversationGoalStatus?,
        tokenBudget: Int?,
        systemPrompt: String?,
        agentMode: AgentMode?,
        agentAccess: AgentAccess?,
        workingDirectory: URL?,
        resumeSessionID: String?
    ) async throws -> ConversationGoal

    func getThreadGoal(
        systemPrompt: String?,
        agentMode: AgentMode?,
        agentAccess: AgentAccess?,
        workingDirectory: URL?,
        resumeSessionID: String?
    ) async throws -> (threadID: String, goal: ConversationGoal?)

    func clearThreadGoal(
        systemPrompt: String?,
        agentMode: AgentMode?,
        agentAccess: AgentAccess?,
        workingDirectory: URL?,
        resumeSessionID: String?
    ) async throws -> String

    func compactThread(
        systemPrompt: String?,
        agentMode: AgentMode?,
        agentAccess: AgentAccess?,
        workingDirectory: URL?,
        resumeSessionID: String?
    ) async throws -> String
}

public struct AIModel: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public var name: String
    public var contextWindow: Int
    public var availableContextWindows: [Int]
    public var supportsTools: Bool
    public var supportsVision: Bool

    public init(
        id: String,
        name: String,
        contextWindow: Int = 200_000,
        availableContextWindows: [Int] = [],
        supportsTools: Bool = true,
        supportsVision: Bool = true
    ) {
        self.id = id
        self.name = name
        self.contextWindow = contextWindow
        self.availableContextWindows = availableContextWindows.isEmpty ? [contextWindow] : availableContextWindows
        self.supportsTools = supportsTools
        self.supportsVision = supportsVision
    }
}

public enum StreamEvent: Sendable {
    case initialized(sessionID: String, model: String)
    case lifecycle(ProviderLifecycleEvent)
    case textDelta(String)
    case text(String)
    case approvalRequest(ProviderApprovalRequest)
    case toolUse(id: String, name: String, input: String)
    case toolResult(id: String, content: String, isError: Bool)
    case usage(inputTokens: Int, outputTokens: Int, costUSD: Double?)
    case contextUsage(
        inputTokens: Int,
        outputTokens: Int,
        cachedInputTokens: Int,
        reasoningOutputTokens: Int,
        totalTokens: Int,
        contextWindow: Int?
    )
    case usageTotal(
        inputTokens: Int,
        outputTokens: Int,
        cachedInputTokens: Int,
        reasoningOutputTokens: Int,
        totalTokens: Int,
        contextWindow: Int?
    )
    case goalUpdated(ConversationGoal?)
    case done(stopReason: String)
    case error(String)
}

@Observable
@MainActor
public final class ProviderRegistry {
    public private(set) var providers: [String: any AIProvider] = [:]

    public init() {}

    public func register(_ provider: any AIProvider) {
        providers[provider.id] = provider
    }

    public func provider(for id: String) -> (any AIProvider)? {
        providers[id]
    }

    public var allProviders: [any AIProvider] {
        Array(providers.values)
    }
}
