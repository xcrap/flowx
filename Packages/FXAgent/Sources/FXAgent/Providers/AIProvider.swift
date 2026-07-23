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
    public let respondToUserInput: @Sendable (UUID, ProviderUserInputAnswers) async -> Void
    public let cancelUserInput: @Sendable (UUID) async -> Void

    public init(
        stream: AsyncThrowingStream<StreamEvent, Error>,
        cancel: @escaping @Sendable () async -> Void,
        respondToApproval: @escaping @Sendable (UUID, Bool) async -> Void = { _, _ in },
        respondToUserInput: @escaping @Sendable (UUID, ProviderUserInputAnswers) async -> Void = { _, _ in },
        cancelUserInput: @escaping @Sendable (UUID) async -> Void = { _ in }
    ) {
        self.stream = stream
        self.cancel = cancel
        self.respondToApproval = respondToApproval
        self.respondToUserInput = respondToUserInput
        self.cancelUserInput = cancelUserInput
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

public struct ProviderUserInputOption: Sendable, Equatable, Hashable {
    public var label: String
    public var description: String
    /// Provider-native value returned when the user selects this display label.
    public var value: String

    public init(label: String, description: String = "", value: String? = nil) {
        self.label = label
        self.description = description
        self.value = value ?? label
    }
}

public enum ProviderUserInputValueType: String, Sendable, Equatable {
    case string
    case number
    case integer
    case boolean
}

public struct ProviderUserInputQuestion: Identifiable, Sendable, Equatable {
    public var id: String
    public var header: String
    public var question: String
    public var options: [ProviderUserInputOption]
    public var allowsOther: Bool
    public var allowsMultiple: Bool
    public var isSecret: Bool
    public var isRequired: Bool
    public var valueType: ProviderUserInputValueType
    public var valueFormat: String?
    public var allowsEmptyValue: Bool
    public var preservesWhitespace: Bool
    public var defaultAnswers: [String]
    public var minimumValue: Double?
    public var maximumValue: Double?
    public var minimumLength: Int?
    public var maximumLength: Int?
    public var minimumSelectionCount: Int?
    public var maximumSelectionCount: Int?

    public init(
        id: String,
        header: String,
        question: String,
        options: [ProviderUserInputOption] = [],
        allowsOther: Bool = false,
        allowsMultiple: Bool = false,
        isSecret: Bool = false,
        isRequired: Bool = true,
        valueType: ProviderUserInputValueType = .string,
        valueFormat: String? = nil,
        allowsEmptyValue: Bool = false,
        preservesWhitespace: Bool = false,
        defaultAnswers: [String] = [],
        minimumValue: Double? = nil,
        maximumValue: Double? = nil,
        minimumLength: Int? = nil,
        maximumLength: Int? = nil,
        minimumSelectionCount: Int? = nil,
        maximumSelectionCount: Int? = nil
    ) {
        self.id = id
        self.header = header
        self.question = question
        self.options = options
        self.allowsOther = allowsOther
        self.allowsMultiple = allowsMultiple
        self.isSecret = isSecret
        self.isRequired = isRequired
        self.valueType = valueType
        self.valueFormat = valueFormat
        self.allowsEmptyValue = allowsEmptyValue
        self.preservesWhitespace = preservesWhitespace
        self.defaultAnswers = defaultAnswers
        self.minimumValue = minimumValue
        self.maximumValue = maximumValue
        self.minimumLength = minimumLength
        self.maximumLength = maximumLength
        self.minimumSelectionCount = minimumSelectionCount
        self.maximumSelectionCount = maximumSelectionCount
    }
}

public typealias ProviderUserInputAnswers = [String: [String]]

public enum ProviderUserInputPresentation: Sendable, Equatable {
    case form
    case externalURL(String)
    /// A provider request that FlowX cannot fulfill directly but must not
    /// resolve without an explicit user decision.
    case decision(actionLabel: String)
}

public enum ProviderUserInputCancellationBehavior: Sendable, Equatable {
    /// Cancelling the prompt interrupts the provider turn (ordinary provider questions).
    case stopTurn
    /// Cancelling sends a protocol-level cancellation response and leaves the turn running.
    case respondToProvider
}

public struct ProviderUserInputRequest: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var questions: [ProviderUserInputQuestion]
    public var title: String
    public var message: String?
    public var presentation: ProviderUserInputPresentation
    public var cancellationBehavior: ProviderUserInputCancellationBehavior
    /// Provider timing metadata only. FlowX never auto-submits or skips a
    /// prompt; every response requires an explicit user action.
    public var autoResolutionMilliseconds: UInt64?

    public init(
        id: UUID = UUID(),
        questions: [ProviderUserInputQuestion],
        title: String = "Input needed",
        message: String? = nil,
        presentation: ProviderUserInputPresentation = .form,
        cancellationBehavior: ProviderUserInputCancellationBehavior = .stopTurn,
        autoResolutionMilliseconds: UInt64? = nil
    ) {
        self.id = id
        self.questions = questions
        self.title = title
        self.message = message
        self.presentation = presentation
        self.cancellationBehavior = cancellationBehavior
        self.autoResolutionMilliseconds = autoResolutionMilliseconds
    }
}

public enum ProviderAttachmentKind: String, Codable, Sendable, CaseIterable {
    case image
    case pdf
}

public struct AIProviderCapabilities: Sendable, Equatable {
    public var supportedAttachments: Set<ProviderAttachmentKind>
    public var supportsApprovals: Bool
    public var supportsThreadControls: Bool
    public var supportsModelDiscovery: Bool

    public init(
        supportedAttachments: Set<ProviderAttachmentKind> = [],
        supportsApprovals: Bool = false,
        supportsThreadControls: Bool = false,
        supportsModelDiscovery: Bool = false
    ) {
        self.supportedAttachments = supportedAttachments
        self.supportsApprovals = supportsApprovals
        self.supportsThreadControls = supportsThreadControls
        self.supportsModelDiscovery = supportsModelDiscovery
    }
}

public protocol AIProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var availableModels: [AIModel] { get }
    var capabilities: AIProviderCapabilities { get }

    @discardableResult
    func refreshAvailableModels() async -> [AIModel]

    func sendMessage(
        prompt: String,
        attachments: [Attachment],
        messages: [ConversationMessage],
        model: String?,
        effort: String?,
        systemPrompt: String?,
        agentMode: AgentMode?,
        agentAccess: AgentAccess?,
        workingDirectory: URL?,
        resumeSessionID: String?
    ) -> ProviderStreamHandle
}

public extension AIProvider {
    var capabilities: AIProviderCapabilities {
        AIProviderCapabilities(
            supportedAttachments: availableModels.contains(where: \.supportsVision) ? [.image] : []
        )
    }

    @discardableResult
    func refreshAvailableModels() async -> [AIModel] {
        availableModels
    }
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

/// Providers with persistent child processes can release cached sessions when
/// projects or conversations close, instead of retaining idle CLIs forever.
public protocol AIProviderSessionManaging: AIProvider {
    func releaseSession(_ sessionID: String) async
    func releaseAllSessions() async
}

public struct ProviderNativeThreadSummary: Identifiable, Sendable, Equatable {
    public let providerID: String
    public let id: String
    public var title: String
    public var preview: String
    public var workingDirectory: String
    public var createdAt: Date
    public var updatedAt: Date
    public var model: String?
    public var effort: String?
    public var status: String?
    public var source: String

    public init(
        providerID: String,
        id: String,
        title: String,
        preview: String = "",
        workingDirectory: String,
        createdAt: Date,
        updatedAt: Date,
        model: String? = nil,
        effort: String? = nil,
        status: String? = nil,
        source: String
    ) {
        self.providerID = providerID
        self.id = id
        self.title = title
        self.preview = preview
        self.workingDirectory = workingDirectory
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.model = model
        self.effort = effort
        self.status = status
        self.source = source
    }
}

public struct ProviderNativeThread: Sendable, Equatable {
    public var summary: ProviderNativeThreadSummary
    public var messages: [ConversationMessage]

    public init(summary: ProviderNativeThreadSummary, messages: [ConversationMessage]) {
        self.summary = summary
        self.messages = messages
    }
}

public enum ProviderNativeThreadDiscoveryMode: Sendable, Equatable {
    /// Fast provider-index lookup for frequent active-app polling.
    case indexed
    /// Reconcile provider storage so sessions missing from the index can reappear.
    case repair
}

/// Read-only discovery of the provider's own sessions. Native provider state is
/// authoritative; FlowX persistence is only a UI cache and workspace layout.
public protocol AIProviderNativeThreads: AIProvider {
    func listNativeThreads(
        workingDirectory: URL,
        limit: Int
    ) async throws -> [ProviderNativeThreadSummary]

    func listNativeThreads(
        workingDirectory: URL,
        limit: Int,
        discoveryMode: ProviderNativeThreadDiscoveryMode
    ) async throws -> [ProviderNativeThreadSummary]

    func readNativeThread(
        id: String,
        workingDirectory: URL?
    ) async throws -> ProviderNativeThread
}

public extension AIProviderNativeThreads {
    func listNativeThreads(
        workingDirectory: URL,
        limit: Int,
        discoveryMode: ProviderNativeThreadDiscoveryMode
    ) async throws -> [ProviderNativeThreadSummary] {
        try await listNativeThreads(workingDirectory: workingDirectory, limit: limit)
    }
}

public enum AIInputModality: String, Codable, Sendable, CaseIterable {
    case text
    case image
}

public struct AIModelServiceTier: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public var name: String
    public var description: String

    public init(id: String, name: String, description: String = "") {
        self.id = id
        self.name = name
        self.description = description
    }
}

public struct AIModel: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public var name: String
    public var description: String?
    public var contextWindow: Int
    public var maxContextWindow: Int
    public var availableContextWindows: [Int]
    public var supportsTools: Bool
    public var supportsVision: Bool
    public var inputModalities: [AIInputModality]
    public var defaultReasoningEffort: String?
    public var supportedReasoningEfforts: [String]
    public var isDefault: Bool
    public var serviceTiers: [AIModelServiceTier]

    public init(
        id: String,
        name: String,
        description: String? = nil,
        contextWindow: Int = 200_000,
        maxContextWindow: Int? = nil,
        availableContextWindows: [Int] = [],
        supportsTools: Bool = true,
        supportsVision: Bool = true,
        inputModalities: [AIInputModality]? = nil,
        defaultReasoningEffort: String? = nil,
        supportedReasoningEfforts: [String] = [],
        isDefault: Bool = false,
        serviceTiers: [AIModelServiceTier] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.contextWindow = contextWindow
        self.maxContextWindow = max(maxContextWindow ?? contextWindow, contextWindow)
        self.availableContextWindows = Self.normalizedContextWindows(
            availableContextWindows,
            contextWindow: contextWindow,
            maxContextWindow: self.maxContextWindow
        )
        self.supportsTools = supportsTools
        self.supportsVision = supportsVision
        self.inputModalities = inputModalities ?? (supportsVision ? [.text, .image] : [.text])
        self.defaultReasoningEffort = defaultReasoningEffort
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.isDefault = isDefault
        self.serviceTiers = serviceTiers
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case contextWindow
        case maxContextWindow
        case availableContextWindows
        case supportsTools
        case supportsVision
        case inputModalities
        case defaultReasoningEffort
        case supportedReasoningEfforts
        case isDefault
        case serviceTiers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        contextWindow = try container.decodeIfPresent(Int.self, forKey: .contextWindow) ?? 200_000
        maxContextWindow = max(
            try container.decodeIfPresent(Int.self, forKey: .maxContextWindow) ?? contextWindow,
            contextWindow
        )
        let decodedWindows = try container.decodeIfPresent([Int].self, forKey: .availableContextWindows) ?? []
        availableContextWindows = Self.normalizedContextWindows(
            decodedWindows,
            contextWindow: contextWindow,
            maxContextWindow: maxContextWindow
        )
        supportsTools = try container.decodeIfPresent(Bool.self, forKey: .supportsTools) ?? true
        supportsVision = try container.decodeIfPresent(Bool.self, forKey: .supportsVision) ?? true
        inputModalities = try container.decodeIfPresent([AIInputModality].self, forKey: .inputModalities)
            ?? (supportsVision ? [.text, .image] : [.text])
        defaultReasoningEffort = try container.decodeIfPresent(String.self, forKey: .defaultReasoningEffort)
        supportedReasoningEfforts = try container.decodeIfPresent([String].self, forKey: .supportedReasoningEfforts) ?? []
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        serviceTiers = try container.decodeIfPresent([AIModelServiceTier].self, forKey: .serviceTiers) ?? []
    }

    private static func normalizedContextWindows(
        _ values: [Int],
        contextWindow: Int,
        maxContextWindow: Int
    ) -> [Int] {
        let candidates = values.isEmpty ? [contextWindow, maxContextWindow] : values + [contextWindow]
        return Array(Set(candidates.filter { $0 > 0 && $0 <= maxContextWindow })).sorted()
    }
}

public enum StreamEvent: Sendable {
    case initialized(sessionID: String, model: String?)
    case modelChanged(model: String, reason: String?)
    case lifecycle(ProviderLifecycleEvent)
    case textDelta(String)
    case text(String)
    case approvalRequest(ProviderApprovalRequest)
    case userInputRequest(ProviderUserInputRequest)
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
