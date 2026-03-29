import Foundation
import FXCore

struct PersistedWorkspace: Codable {
    var agentID: UUID
    var splitOpen: Bool
    var splitContent: SplitContent
    var splitRatio: Double
    var terminalVisible: Bool
    var terminalHeight: Double
    var terminalCount: Int
    var browserURLString: String

    enum CodingKeys: String, CodingKey {
        case agentID
        case splitOpen
        case splitContent
        case splitRatio
        case terminalVisible
        case terminalHeight
        case terminalCount
        case browserURLString
    }

    init(
        agentID: UUID,
        splitOpen: Bool,
        splitContent: SplitContent,
        splitRatio: Double,
        terminalVisible: Bool,
        terminalHeight: Double,
        terminalCount: Int,
        browserURLString: String
    ) {
        self.agentID = agentID
        self.splitOpen = splitOpen
        self.splitContent = splitContent
        self.splitRatio = splitRatio
        self.terminalVisible = terminalVisible
        self.terminalHeight = terminalHeight
        self.terminalCount = terminalCount
        self.browserURLString = browserURLString
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agentID = try container.decode(UUID.self, forKey: .agentID)
        splitOpen = try container.decode(Bool.self, forKey: .splitOpen)
        splitContent = try container.decode(SplitContent.self, forKey: .splitContent)
        splitRatio = try container.decode(Double.self, forKey: .splitRatio)
        terminalVisible = try container.decode(Bool.self, forKey: .terminalVisible)
        terminalHeight = try container.decode(Double.self, forKey: .terminalHeight)
        terminalCount = try container.decodeIfPresent(Int.self, forKey: .terminalCount) ?? 1
        browserURLString = try container.decode(String.self, forKey: .browserURLString)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(agentID, forKey: .agentID)
        try container.encode(splitOpen, forKey: .splitOpen)
        try container.encode(splitContent, forKey: .splitContent)
        try container.encode(splitRatio, forKey: .splitRatio)
        try container.encode(terminalVisible, forKey: .terminalVisible)
        try container.encode(terminalHeight, forKey: .terminalHeight)
        try container.encode(terminalCount, forKey: .terminalCount)
        try container.encode(browserURLString, forKey: .browserURLString)
    }
}

struct PersistedProjectRecord: Codable {
    var project: Project
    var agents: [Agent]
    var isExpanded: Bool
    var workspaces: [PersistedWorkspace]
}

struct PersistedFlowXAppState: Codable {
    var projects: [PersistedProjectRecord]
    var activeProjectID: UUID?
    var activeAgentID: UUID?
}

@MainActor
enum ProjectPersistence {
    private static var saveURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent(AppEnvironment.appSupportDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("projects.json")
    }

    static func save(_ appState: AppState) {
        let payload = PersistedFlowXAppState(
            projects: appState.projects.map { project in
                PersistedProjectRecord(
                    project: project.project,
                    agents: project.agents.map(\.agent),
                    isExpanded: project.isExpanded,
                    workspaces: project.agents.map { agent in
                        PersistedWorkspace(
                            agentID: agent.id,
                            splitOpen: agent.workspace.splitOpen,
                            splitContent: agent.workspace.splitContent,
                            splitRatio: Double(agent.workspace.splitRatio),
                            terminalVisible: agent.workspace.terminalVisible,
                            terminalHeight: Double(agent.workspace.terminalHeight),
                            terminalCount: agent.terminalPaneCount,
                            browserURLString: agent.workspace.browserURLString
                        )
                    }
                )
            },
            activeProjectID: appState.activeProjectID,
            activeAgentID: appState.activeAgentID
        )

        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: saveURL, options: .atomic)
        } catch {
            print("Failed to save projects: \(error)")
        }
    }

    static func load(into appState: AppState) {
        guard let data = try? Data(contentsOf: saveURL),
              let payload = try? JSONDecoder().decode(PersistedFlowXAppState.self, from: data) else {
            return
        }

        appState.projects = payload.projects.map { persisted in
            let conversations = ConversationPersistence.load(for: persisted.project.id)
            let workspaceMap = Dictionary(uniqueKeysWithValues: persisted.workspaces.map { ($0.agentID, $0) })

            let agents = persisted.agents.map { agent in
                let workspace = workspaceMap[agent.id]
                return AgentInfo(
                    agent: agent,
                    projectRootPath: persisted.project.rootPath,
                    conversationState: conversations[agent.id],
                    workspace: workspace.map(WorkspaceState.init)
                )
            }

            return ProjectState(
                project: persisted.project,
                agents: agents,
                isExpanded: persisted.isExpanded
            )
        }
        appState.activeProjectID = payload.activeProjectID
        appState.activeAgentID = payload.activeAgentID
    }
}
