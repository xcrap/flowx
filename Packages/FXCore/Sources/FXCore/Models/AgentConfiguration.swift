import Foundation

public enum AgentMode: String, Codable, Sendable, CaseIterable {
    case auto
    case plan
}

public enum AgentAccess: String, Codable, Sendable, CaseIterable {
    case supervised
    case acceptEdits
    case fullAccess
}

public struct AgentConfiguration: Codable, Sendable, Equatable {
    public var providerID: String?
    public var modelID: String?
    public var effort: String?
    public var systemPrompt: String?
    public var agentMode: AgentMode?
    public var agentAccess: AgentAccess?
    public var contextWindowSize: Int?

    public var resolvedMode: AgentMode {
        agentMode ?? .auto
    }

    public var resolvedAccess: AgentAccess {
        if let agentAccess {
            return agentAccess
        }
        if let raw = UserDefaults.standard.string(forKey: "defaultAccess"),
           let access = AgentAccess(rawValue: raw) {
            return access
        }
        return .fullAccess
    }

    public init(
        providerID: String? = nil,
        modelID: String? = nil,
        effort: String? = nil,
        systemPrompt: String? = nil,
        agentMode: AgentMode? = nil,
        agentAccess: AgentAccess? = nil,
        contextWindowSize: Int? = nil
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.effort = effort
        self.systemPrompt = systemPrompt
        self.agentMode = agentMode
        self.agentAccess = agentAccess
        self.contextWindowSize = contextWindowSize
    }

    private enum CodingKeys: String, CodingKey {
        case providerID
        case modelID
        case effort
        case systemPrompt
        case triggerType
        case agentMode
        case agentAccess
        case contextWindowSize
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try container.decodeIfPresent(String.self, forKey: .providerID)
        modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
        effort = try container.decodeIfPresent(String.self, forKey: .effort)
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt)
        agentMode = try container.decodeIfPresent(AgentMode.self, forKey: .agentMode)
        agentAccess = try container.decodeIfPresent(AgentAccess.self, forKey: .agentAccess)
        contextWindowSize = try container.decodeIfPresent(Int.self, forKey: .contextWindowSize)

        if agentMode == nil, agentAccess == nil, let legacy = try container.decodeIfPresent(String.self, forKey: .triggerType) {
            switch legacy {
            case "plan":
                agentMode = .plan
                agentAccess = .fullAccess
            case "acceptEdits":
                agentMode = .auto
                agentAccess = .acceptEdits
            case "default":
                agentMode = .auto
                agentAccess = .supervised
            default:
                agentMode = .auto
                agentAccess = .fullAccess
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(providerID, forKey: .providerID)
        try container.encodeIfPresent(modelID, forKey: .modelID)
        try container.encodeIfPresent(effort, forKey: .effort)
        try container.encodeIfPresent(systemPrompt, forKey: .systemPrompt)
        try container.encodeIfPresent(agentMode, forKey: .agentMode)
        try container.encodeIfPresent(agentAccess, forKey: .agentAccess)
        try container.encodeIfPresent(contextWindowSize, forKey: .contextWindowSize)

        let legacy: String? = {
            let mode = resolvedMode
            let access = resolvedAccess
            if mode == .plan {
                return "plan"
            }
            switch access {
            case .supervised:
                return "default"
            case .acceptEdits:
                return "acceptEdits"
            case .fullAccess:
                return "bypassPermissions"
            }
        }()
        try container.encodeIfPresent(legacy, forKey: .triggerType)
    }
}
