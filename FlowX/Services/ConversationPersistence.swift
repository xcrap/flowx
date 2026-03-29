import Foundation
import FXAgent
import FXCore

struct PersistedConversation: Codable {
    var agentID: UUID
    var sessionID: String?
    var messages: [ConversationMessage]
    var runtimeActivities: [ConversationRuntimeActivity]
    var totalCostUSD: Double
    var totalInputTokens: Int
    var totalOutputTokens: Int
    var totalCachedInputTokens: Int
    var totalReasoningOutputTokens: Int
    var totalTokens: Int
    var reportedContextWindow: Int?
}

struct PersistedProjectConversations: Codable {
    var conversations: [PersistedConversation]
}

@MainActor
enum ConversationPersistence {
    private static let maxPersistedMessages = 250

    private static var baseDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("\(AppEnvironment.appSupportDirectoryName)/conversations", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func fileURL(for projectID: UUID) -> URL {
        baseDir.appendingPathComponent("\(projectID.uuidString).json")
    }

    static func save(project: ProjectState) {
        let payload = PersistedProjectConversations(
            conversations: project.agents.map { agent in
                let state = agent.conversationState
                return PersistedConversation(
                    agentID: agent.id,
                    sessionID: state.sessionID,
                    messages: Array(state.messages.suffix(maxPersistedMessages)),
                    runtimeActivities: state.runtimeActivities,
                    totalCostUSD: state.totalCostUSD,
                    totalInputTokens: state.totalInputTokens,
                    totalOutputTokens: state.totalOutputTokens,
                    totalCachedInputTokens: state.totalCachedInputTokens,
                    totalReasoningOutputTokens: state.totalReasoningOutputTokens,
                    totalTokens: state.totalTokens,
                    reportedContextWindow: state.reportedContextWindow
                )
            }
        )

        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: fileURL(for: project.id), options: .atomic)
        } catch {
            print("Failed to save conversations: \(error)")
        }
    }

    static func load(for projectID: UUID) -> [UUID: ConversationState] {
        let url = fileURL(for: projectID)
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(PersistedProjectConversations.self, from: data) else {
            return [:]
        }

        var result: [UUID: ConversationState] = [:]
        for conversation in payload.conversations {
            let state = ConversationState(agentID: conversation.agentID)
            state.sessionID = conversation.sessionID
            state.messages = conversation.messages
            state.runtimeActivities = conversation.runtimeActivities
            state.totalCostUSD = conversation.totalCostUSD
            state.totalInputTokens = conversation.totalInputTokens
            state.totalOutputTokens = conversation.totalOutputTokens
            state.totalCachedInputTokens = conversation.totalCachedInputTokens
            state.totalReasoningOutputTokens = conversation.totalReasoningOutputTokens
            state.totalTokens = conversation.totalTokens
            state.reportedContextWindow = conversation.reportedContextWindow
            result[conversation.agentID] = state
        }
        return result
    }
}
