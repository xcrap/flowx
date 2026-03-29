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
    var conversationScrollOffset: Double
    var conversationPinnedToBottom: Bool

    enum CodingKeys: String, CodingKey {
        case agentID
        case splitOpen
        case splitContent
        case splitRatio
        case terminalVisible
        case terminalHeight
        case terminalCount
        case browserURLString
        case conversationScrollOffset
        case conversationPinnedToBottom
    }

    init(
        agentID: UUID,
        splitOpen: Bool,
        splitContent: SplitContent,
        splitRatio: Double,
        terminalVisible: Bool,
        terminalHeight: Double,
        terminalCount: Int,
        browserURLString: String,
        conversationScrollOffset: Double,
        conversationPinnedToBottom: Bool
    ) {
        self.agentID = agentID
        self.splitOpen = splitOpen
        self.splitContent = splitContent
        self.splitRatio = splitRatio
        self.terminalVisible = terminalVisible
        self.terminalHeight = terminalHeight
        self.terminalCount = terminalCount
        self.browserURLString = browserURLString
        self.conversationScrollOffset = conversationScrollOffset
        self.conversationPinnedToBottom = conversationPinnedToBottom
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
        conversationScrollOffset = try container.decodeIfPresent(Double.self, forKey: .conversationScrollOffset) ?? 0
        conversationPinnedToBottom = try container.decodeIfPresent(Bool.self, forKey: .conversationPinnedToBottom) ?? true
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
        try container.encode(conversationScrollOffset, forKey: .conversationScrollOffset)
        try container.encode(conversationPinnedToBottom, forKey: .conversationPinnedToBottom)
    }
}

struct PersistedProjectRecord: Codable {
    var project: Project
    var agents: [Agent]
    var isExpanded: Bool
    var lastSelectedAgentID: UUID?
    var selectedInspectorPath: String?
    var inspectorComparisonMode: InspectorComparisonMode
    var inspectorDiffDisplayMode: InspectorDiffDisplayMode
    var workspaces: [PersistedWorkspace]

    enum CodingKeys: String, CodingKey {
        case project
        case agents
        case isExpanded
        case lastSelectedAgentID
        case selectedInspectorPath
        case inspectorComparisonMode
        case inspectorDiffDisplayMode
        case workspaces
    }

    init(
        project: Project,
        agents: [Agent],
        isExpanded: Bool,
        lastSelectedAgentID: UUID?,
        selectedInspectorPath: String?,
        inspectorComparisonMode: InspectorComparisonMode,
        inspectorDiffDisplayMode: InspectorDiffDisplayMode,
        workspaces: [PersistedWorkspace]
    ) {
        self.project = project
        self.agents = agents
        self.isExpanded = isExpanded
        self.lastSelectedAgentID = lastSelectedAgentID
        self.selectedInspectorPath = selectedInspectorPath
        self.inspectorComparisonMode = inspectorComparisonMode
        self.inspectorDiffDisplayMode = inspectorDiffDisplayMode
        self.workspaces = workspaces
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        project = try container.decode(Project.self, forKey: .project)
        agents = try container.decode([Agent].self, forKey: .agents)
        isExpanded = try container.decode(Bool.self, forKey: .isExpanded)
        lastSelectedAgentID = try container.decodeIfPresent(UUID.self, forKey: .lastSelectedAgentID)
        selectedInspectorPath = try container.decodeIfPresent(String.self, forKey: .selectedInspectorPath)
        inspectorComparisonMode = try container.decodeIfPresent(InspectorComparisonMode.self, forKey: .inspectorComparisonMode) ?? .unstaged
        inspectorDiffDisplayMode = try container.decodeIfPresent(InspectorDiffDisplayMode.self, forKey: .inspectorDiffDisplayMode) ?? .inline
        workspaces = try container.decodeIfPresent([PersistedWorkspace].self, forKey: .workspaces) ?? []
    }
}

struct PersistedFlowXAppState: Codable {
    var projects: [PersistedProjectRecord]
    var activeProjectID: UUID?
    var activeAgentID: UUID?
    var sidebarVisible: Bool
    var rightPanelVisible: Bool
    var rightPanelTab: RightPanelTab

    enum CodingKeys: String, CodingKey {
        case projects
        case activeProjectID
        case activeAgentID
        case sidebarVisible
        case rightPanelVisible
        case rightPanelTab
    }

    init(
        projects: [PersistedProjectRecord],
        activeProjectID: UUID?,
        activeAgentID: UUID?,
        sidebarVisible: Bool,
        rightPanelVisible: Bool,
        rightPanelTab: RightPanelTab
    ) {
        self.projects = projects
        self.activeProjectID = activeProjectID
        self.activeAgentID = activeAgentID
        self.sidebarVisible = sidebarVisible
        self.rightPanelVisible = rightPanelVisible
        self.rightPanelTab = rightPanelTab
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projects = try container.decode([PersistedProjectRecord].self, forKey: .projects)
        activeProjectID = try container.decodeIfPresent(UUID.self, forKey: .activeProjectID)
        activeAgentID = try container.decodeIfPresent(UUID.self, forKey: .activeAgentID)
        sidebarVisible = try container.decodeIfPresent(Bool.self, forKey: .sidebarVisible) ?? true
        rightPanelVisible = try container.decodeIfPresent(Bool.self, forKey: .rightPanelVisible) ?? false
        rightPanelTab = try container.decodeIfPresent(RightPanelTab.self, forKey: .rightPanelTab) ?? .changes
    }
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
                    lastSelectedAgentID: project.lastSelectedAgentID,
                    selectedInspectorPath: project.selectedInspectorPath,
                    inspectorComparisonMode: project.inspectorComparisonMode,
                    inspectorDiffDisplayMode: project.inspectorDiffDisplayMode,
                    workspaces: project.agents.map { agent in
                        PersistedWorkspace(
                            agentID: agent.id,
                            splitOpen: agent.workspace.splitOpen,
                            splitContent: agent.workspace.splitContent,
                            splitRatio: Double(agent.workspace.splitRatio),
                            terminalVisible: agent.workspace.terminalVisible,
                            terminalHeight: Double(agent.workspace.terminalHeight),
                            terminalCount: agent.terminalPaneCount,
                            browserURLString: agent.workspace.browserURLString,
                            conversationScrollOffset: Double(agent.workspace.conversationScrollOffset),
                            conversationPinnedToBottom: agent.workspace.conversationPinnedToBottom
                        )
                    }
                )
            },
            activeProjectID: appState.activeProjectID,
            activeAgentID: appState.activeAgentID,
            sidebarVisible: appState.sidebarVisible,
            rightPanelVisible: appState.rightPanelVisible,
            rightPanelTab: appState.rightPanelTab
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

            let projectState = ProjectState(
                project: persisted.project,
                agents: agents,
                isExpanded: persisted.isExpanded
            )
            projectState.lastSelectedAgentID = persisted.lastSelectedAgentID
            projectState.selectedInspectorPath = persisted.selectedInspectorPath
            projectState.inspectorComparisonMode = persisted.inspectorComparisonMode
            projectState.inspectorDiffDisplayMode = persisted.inspectorDiffDisplayMode
            return projectState
        }
        appState.activeProjectID = payload.activeProjectID
        appState.activeAgentID = payload.activeAgentID
        appState.sidebarVisible = payload.sidebarVisible
        appState.rightPanelVisible = payload.rightPanelVisible
        appState.rightPanelTab = payload.rightPanelTab
    }
}
