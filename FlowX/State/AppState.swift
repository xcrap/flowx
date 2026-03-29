import AppKit
import Foundation
import FXAgent
import FXCore
import FXDesign
import FXTerminal
import SwiftUI

struct FileChangeInfo: Identifiable, Equatable {
    var id: String { path }
    var path: String
    var additions: Int
    var deletions: Int
    var isStaged: Bool
    var status: String
}

enum RightPanelTab: String, CaseIterable, Codable {
    case changes = "CHANGES"
    case files = "FILES"
}

enum InspectorComparisonMode: String, CaseIterable, Codable {
    case unstaged = "Unstaged"
    case staged = "Staged"
    case base = "Base"
}

enum InspectorContentKind {
    case diff
    case file
    case message
}

enum InspectorDiffDisplayMode: String, CaseIterable, Codable {
    case inline = "Inline"
    case split = "Split"
}

enum AgentStatus: String {
    case idle
    case running
    case completed
    case error
}

enum SplitContent: String, Codable {
    case diff
    case browser
}

@Observable
@MainActor
final class WorkspaceState {
    var splitOpen: Bool = false { didSet { onChange?() } }
    var splitContent: SplitContent = .diff { didSet { onChange?() } }
    var splitRatio: CGFloat = 0.5 { didSet { onChange?() } }
    var terminalVisible: Bool = false { didSet { onChange?() } }
    var terminalHeight: CGFloat = 220 { didSet { onChange?() } }
    var terminalCount: Int = 1 { didSet { onChange?() } }
    var browserURLString: String = "" { didSet { onChange?() } }
    var conversationScrollOffset: CGFloat = 0 { didSet { onChange?() } }
    var conversationPinnedToBottom: Bool = true { didSet { onChange?() } }

    var onChange: (() -> Void)?

    init() {}

    init(_ persisted: PersistedWorkspace) {
        splitOpen = persisted.splitOpen
        splitContent = persisted.splitContent
        splitRatio = CGFloat(persisted.splitRatio)
        terminalVisible = persisted.terminalVisible
        terminalHeight = CGFloat(persisted.terminalHeight)
        terminalCount = persisted.terminalCount
        browserURLString = persisted.browserURLString == "https://localhost:3000" ? "" : persisted.browserURLString
        conversationScrollOffset = CGFloat(persisted.conversationScrollOffset)
        conversationPinnedToBottom = persisted.conversationPinnedToBottom
    }
}

@Observable
@MainActor
final class AgentInfo: Identifiable {
    let id: UUID
    var agent: Agent
    var conversationState: ConversationState
    let projectRootPath: String
    var terminalSessions: [TerminalSession]
    var workspace: WorkspaceState

    var branch: String = ""
    var additions: Int = 0
    var deletions: Int = 0
    var fileChanges: [FileChangeInfo] = []

    var onChange: (() -> Void)?
    init(
        agent: Agent,
        projectRootPath: String,
        conversationState: ConversationState? = nil,
        workspace: WorkspaceState? = nil
    ) {
        id = agent.id
        self.agent = agent
        self.projectRootPath = projectRootPath
        let resolvedConversation = conversationState ?? ConversationState(agentID: agent.id)
        resolvedConversation.activeProviderID = agent.configuration.providerID
        resolvedConversation.activeModelID = agent.configuration.modelID
        resolvedConversation.configuredContextWindow = agent.configuration.contextWindowSize
        self.conversationState = resolvedConversation
        self.workspace = workspace ?? WorkspaceState()
        terminalSessions = []
        syncTerminalSessions(to: self.workspace.terminalCount)
        self.workspace.onChange = { [weak self] in
            self?.onChange?()
        }
    }

    var terminalSession: TerminalSession {
        terminalSessions[0]
    }

    var terminalPaneCount: Int {
        max(1, min(3, workspace.terminalCount))
    }

    var visibleTerminalSessions: [TerminalSession] {
        Array(terminalSessions.prefix(terminalPaneCount))
    }

    var title: String {
        get { agent.title }
        set {
            agent.title = newValue
            onChange?()
        }
    }

    var providerID: String {
        get { agent.configuration.providerID ?? "claude" }
        set {
            agent.configuration.providerID = newValue
            if agent.configuration.modelID == nil {
                agent.configuration.modelID = defaultModelID(for: newValue)
            }
            onChange?()
        }
    }

    var modelID: String {
        get { agent.configuration.modelID ?? defaultModelID(for: providerID) }
        set {
            agent.configuration.modelID = newValue
            onChange?()
        }
    }

    var effort: String {
        get { agent.configuration.effort ?? "high" }
        set {
            agent.configuration.effort = newValue
            onChange?()
        }
    }

    var systemPrompt: String? {
        get { agent.configuration.systemPrompt }
        set {
            agent.configuration.systemPrompt = newValue
            onChange?()
        }
    }

    var agentMode: AgentMode {
        get { agent.configuration.resolvedMode }
        set {
            agent.configuration.agentMode = newValue
            onChange?()
        }
    }

    var agentAccess: AgentAccess {
        get { agent.configuration.resolvedAccess }
        set {
            agent.configuration.agentAccess = newValue
            onChange?()
        }
    }

    var providerName: String {
        switch providerID {
        case "claude":
            "Claude"
        case "codex":
            "Codex"
        default:
            providerID.capitalized
        }
    }

    var status: AgentStatus {
        if conversationState.error != nil || agent.executionState == .failure {
            return .error
        }
        if conversationState.isStreaming || agent.executionState == .running {
            return .running
        }
        if agent.executionState == .success {
            return .completed
        }
        return .idle
    }

    var messages: [ConversationMessage] {
        conversationState.messages
    }

    var activities: [ConversationRuntimeActivity] {
        conversationState.runtimeActivities
    }

    var toolCallCount: Int {
        conversationState.runtimeActivities.filter { $0.kind == .tool }.count
    }

    var isStreaming: Bool {
        conversationState.isStreaming
    }

    func setTerminalCount(_ count: Int) {
        let normalized = max(1, min(3, count))
        syncTerminalSessions(to: normalized)
    }

    func addTerminalPane() {
        setTerminalCount(terminalPaneCount + 1)
    }

    func removeTerminalPane() {
        setTerminalCount(terminalPaneCount - 1)
    }

    func closeTerminalPane(at index: Int) {
        guard terminalSessions.indices.contains(index) else { return }

        if terminalPaneCount <= 1 {
            workspace.terminalVisible = false
            return
        }

        terminalSessions.remove(at: index).shutdown()
        workspace.terminalCount = max(1, min(3, terminalSessions.count))
    }

    func setTerminalLaunchDirectory(_ directory: String) {
        for session in terminalSessions {
            session.setLaunchDirectory(directory)
        }
    }

    func applyGitInfo(_ gitInfo: GitStatusService.GitInfo) {
        branch = gitInfo.branch
        additions = gitInfo.additions
        deletions = gitInfo.deletions
        fileChanges = gitInfo.files.map {
            FileChangeInfo(
                path: $0.path,
                additions: $0.additions,
                deletions: $0.deletions,
                isStaged: $0.isStaged,
                status: $0.status
            )
        }
    }

    func markConversationStarted() {
        agent.executionState = .running
    }

    func syncExecutionStateFromConversation() {
        if conversationState.error != nil {
            agent.executionState = .failure
        } else if conversationState.isStreaming {
            agent.executionState = .running
        } else if !conversationState.messages.isEmpty {
            agent.executionState = .success
        } else {
            agent.executionState = .idle
        }
    }

    private func defaultModelID(for providerID: String) -> String {
        switch providerID {
        case "codex":
            "gpt-5.4"
        default:
            "sonnet"
        }
    }

    private func syncTerminalSessions(to requestedCount: Int) {
        let normalized = max(1, min(3, requestedCount))

        if workspace.terminalCount != normalized {
            workspace.terminalCount = normalized
        }

        while terminalSessions.count < normalized {
            terminalSessions.append(
                TerminalSession(id: UUID(), currentDirectory: projectRootPath)
            )
        }

        while terminalSessions.count > normalized {
            terminalSessions.removeLast().shutdown()
        }
    }
}

@Observable
@MainActor
final class ProjectState: Identifiable {
    let id: UUID
    var project: Project
    var agents: [AgentInfo]
    var isExpanded: Bool { didSet { onChange?() } }
    var lastSelectedAgentID: UUID? { didSet { onChange?() } }

    var gitInfo = GitStatusService.GitInfo()
    var repositoryFiles: [String] = []
    var selectedInspectorPath: String? { didSet { onChange?() } }
    var selectedInspectorText: String = ""
    var selectedInspectorContentKind: InspectorContentKind = .message
    var inspectorComparisonMode: InspectorComparisonMode = .unstaged { didSet { onChange?() } }
    var inspectorDiffDisplayMode: InspectorDiffDisplayMode = .inline { didSet { onChange?() } }
    var changedFilesRailWidth: CGFloat = FlowXLayoutDefaults.defaultChangedFilesRailWidth { didSet { onChange?() } }
    var commitComposerVisible = false
    var commitMessageDraft = ""
    var includeUntrackedInCommit = true
    var isPerformingGitAction = false
    var gitActionMessage: String?
    var onChange: (() -> Void)?
    init(project: Project, agents: [AgentInfo], isExpanded: Bool = true) {
        id = project.id
        self.project = project
        self.agents = agents
        self.isExpanded = isExpanded
        self.lastSelectedAgentID = agents.first?.id
        if self.project.agentOrder.isEmpty {
            self.project.agentOrder = agents.map(\.id)
        }
    }

    func refreshFiles(limit: Int = 500) {
        let rootURL = project.rootURL
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            repositoryFiles = []
            return
        }

        var files: [String] = []
        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let relativePath = String(url.path.dropFirst(rootURL.path.count + 1))

            if shouldSkip(relativePath, isDirectory: values.isDirectory == true) {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            if values.isRegularFile == true {
                files.append(relativePath)
                if files.count >= limit {
                    break
                }
            }
        }

        repositoryFiles = files.sorted()
        if selectedInspectorPath == nil {
            selectedInspectorPath = repositoryFiles.first
        }
    }

    private func shouldSkip(_ relativePath: String, isDirectory: Bool) -> Bool {
        guard let first = relativePath.split(separator: "/").first else { return false }
        let blocked = [".git", "node_modules", ".build", "build", "dist", "DerivedData"]
        if blocked.contains(String(first)) {
            return true
        }
        return false
    }
}

@Observable
@MainActor
final class AppPreferences {
    private enum Keys {
        static let defaultProviderID = "flowx.defaultProviderID"
        static let defaultModelID = "flowx.defaultModelID"
        static let defaultEffort = "flowx.defaultEffort"
        static let defaultAccess = "flowx.defaultAccess"
        static let defaultMode = "flowx.defaultMode"
        static let appearanceMode = "flowx.appearanceMode"
        static let baseTone = "flowx.baseTone"
        static let accentColor = "flowx.accentColor"
        static let textSizePreset = "flowx.textSizePreset"
    }

    private let defaults: UserDefaults

    var defaultProviderID: String {
        didSet { defaults.set(defaultProviderID, forKey: Keys.defaultProviderID) }
    }

    var defaultModelID: String {
        didSet { defaults.set(defaultModelID, forKey: Keys.defaultModelID) }
    }

    var defaultEffort: String {
        didSet { defaults.set(defaultEffort, forKey: Keys.defaultEffort) }
    }

    var defaultAccess: AgentAccess {
        didSet {
            defaults.set(defaultAccess.rawValue, forKey: Keys.defaultAccess)
            defaults.set(defaultAccess.rawValue, forKey: "defaultAccess")
        }
    }

    var defaultMode: AgentMode {
        didSet { defaults.set(defaultMode.rawValue, forKey: Keys.defaultMode) }
    }

    var appearanceMode: FXAppearanceMode {
        didSet {
            defaults.set(appearanceMode.rawValue, forKey: Keys.appearanceMode)
            applyTheme()
        }
    }

    var baseTone: FXBaseTone {
        didSet {
            defaults.set(baseTone.rawValue, forKey: Keys.baseTone)
            applyTheme()
        }
    }

    var accentColor: FXAccentColorOption {
        didSet {
            defaults.set(accentColor.rawValue, forKey: Keys.accentColor)
            applyTheme()
        }
    }

    var textSizePreset: FXTextSizePreset {
        didSet {
            defaults.set(textSizePreset.rawValue, forKey: Keys.textSizePreset)
            applyTheme()
        }
    }

    var themeVersion: Int = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaultProviderID = defaults.string(forKey: Keys.defaultProviderID) ?? "claude"
        defaultModelID = defaults.string(forKey: Keys.defaultModelID) ?? "sonnet"
        defaultEffort = defaults.string(forKey: Keys.defaultEffort) ?? "high"
        defaultAccess = AgentAccess(rawValue: defaults.string(forKey: Keys.defaultAccess) ?? "") ?? .fullAccess
        defaultMode = AgentMode(rawValue: defaults.string(forKey: Keys.defaultMode) ?? "") ?? .auto
        appearanceMode = FXAppearanceMode(rawValue: defaults.string(forKey: Keys.appearanceMode) ?? "") ?? .dark
        baseTone = FXBaseTone(rawValue: defaults.string(forKey: Keys.baseTone) ?? "") ?? .zinc
        accentColor = FXAccentColorOption(rawValue: defaults.string(forKey: Keys.accentColor) ?? "") ?? .violet
        textSizePreset = FXTextSizePreset(rawValue: defaults.string(forKey: Keys.textSizePreset) ?? "") ?? .standard
        applyTheme()
        defaults.set(defaultAccess.rawValue, forKey: "defaultAccess")
    }

    var preferredColorScheme: ColorScheme? {
        FXTheme.preferredColorScheme
    }

    var windowBackgroundColor: NSColor {
        FXTheme.windowBackgroundColor
    }

    func setDefaultProvider(_ providerID: String, using registry: ProviderRegistry) {
        defaultProviderID = providerID
        normalizeProviderDefaults(using: registry)
    }

    func normalizeProviderDefaults(using registry: ProviderRegistry) {
        if registry.provider(for: defaultProviderID) == nil {
            defaultProviderID = registry.allProviders.sorted { $0.displayName < $1.displayName }.first?.id ?? "claude"
        }

        guard let provider = registry.provider(for: defaultProviderID) else {
            defaultModelID = Self.fallbackModelID(for: defaultProviderID)
            return
        }

        if !provider.availableModels.contains(where: { $0.id == defaultModelID }) {
            defaultModelID = provider.availableModels.first?.id ?? Self.fallbackModelID(for: provider.id)
        }
    }

    func resolvedDefaultProviderID(using registry: ProviderRegistry) -> String {
        if registry.provider(for: defaultProviderID) != nil {
            return defaultProviderID
        }
        return registry.allProviders.sorted { $0.displayName < $1.displayName }.first?.id ?? "claude"
    }

    func resolvedDefaultModelID(for providerID: String, using registry: ProviderRegistry) -> String {
        guard let provider = registry.provider(for: providerID) else {
            return Self.fallbackModelID(for: providerID)
        }

        if providerID == defaultProviderID,
           provider.availableModels.contains(where: { $0.id == defaultModelID }) {
            return defaultModelID
        }

        return provider.availableModels.first?.id ?? Self.fallbackModelID(for: providerID)
    }

    private func applyTheme() {
        FXTheme.appearanceMode = appearanceMode
        FXTheme.baseTone = baseTone
        FXTheme.accentColorOption = accentColor
        FXTheme.textSizePreset = textSizePreset
        themeVersion &+= 1
    }

    private static func fallbackModelID(for providerID: String) -> String {
        switch providerID {
        case "codex":
            "gpt-5.4"
        default:
            "sonnet"
        }
    }
}

enum FlowXLayoutDefaults {
    static let defaultRightPanelWidth: CGFloat = 760
    static let minRightPanelWidth: CGFloat = 560
    static let maxRightPanelWidth: CGFloat = 1100
    static let defaultChangedFilesRailWidth: CGFloat = 248
    static let minChangedFilesRailWidth: CGFloat = 188
    static let maxChangedFilesRailWidth: CGFloat = 360
}

@Observable
@MainActor
final class AppState {
    let preferences: AppPreferences
    var projects: [ProjectState] = []
    var activeProjectID: UUID?
    var activeAgentID: UUID?
    var rightPanelVisible = false { didSet { persistStateIfBootstrapped() } }
    var rightPanelWidth: CGFloat = FlowXLayoutDefaults.defaultRightPanelWidth {
        didSet {
            let clampedWidth = min(max(rightPanelWidth, FlowXLayoutDefaults.minRightPanelWidth), FlowXLayoutDefaults.maxRightPanelWidth)
            if rightPanelWidth != clampedWidth {
                rightPanelWidth = clampedWidth
                return
            }
            persistStateIfBootstrapped()
        }
    }
    var rightPanelTab: RightPanelTab = .changes { didSet { persistStateIfBootstrapped() } }
    var sidebarVisible = true { didSet { persistStateIfBootstrapped() } }
    var settingsVisible = false
    var settingsTab: SettingsPanel.SettingsTab = .general
    var commandPaletteVisible = false
    var runtimeHealth: [String: BinaryHealth] = [:]
    var isBootstrapped = false

    let providerRegistry = ProviderRegistry()
    let conversationService: ConversationService
    let gitStatusService = GitStatusService()

    private let runtimeDiscovery = RuntimeDiscovery()
    private var gitMirrorTasks: [UUID: Task<Void, Never>] = [:]
    private var scheduledSaveTask: Task<Void, Never>?

    var activeProject: ProjectState? {
        projects.first { $0.project.id == activeProjectID }
    }

    var activeAgent: AgentInfo? {
        guard let project = activeProject, let agentID = activeAgentID else { return nil }
        return project.agents.first { $0.id == agentID }
    }

    var activeProjectCanShowGitPanel: Bool {
        canShowGitPanel(for: activeProject)
    }

    var windowTitle: String {
        guard let project = activeProject else { return "FlowX" }

        if let agent = activeAgent {
            return "\(project.project.name) - \(agent.title)"
        }

        return project.project.name
    }

    init(preferences: AppPreferences) {
        self.preferences = preferences
        conversationService = ConversationService(registry: providerRegistry)

        Task { @MainActor in
            await bootstrap()
        }
    }

    func bootstrap() async {
        await runtimeDiscovery.register(.claude)
        await runtimeDiscovery.register(.codex)

        providerRegistry.register(ClaudeCodeProvider(discovery: runtimeDiscovery))
        providerRegistry.register(CodexProvider(discovery: runtimeDiscovery))
        preferences.normalizeProviderDefaults(using: providerRegistry)
        await refreshRuntimeHealth()

        ProjectPersistence.load(into: self)
        let normalizedLegacyTitles = normalizeLegacyAgentTitles()
        for project in projects {
            hydrate(project)
        }

        #if DEBUG
        if projects.isEmpty {
            seedFromCurrentDirectoryIfUseful()
        }
        #endif

        activeProjectID = activeProjectID ?? projects.first?.id
        if activeAgent == nil {
            activeAgentID = resolvedLastAgentID(for: activeProject)
        }
        synchronizeActiveProjectPanels()

        isBootstrapped = true

        if normalizedLegacyTitles {
            ProjectPersistence.save(self)
        }
    }

    func openAddProjectPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"

        guard panel.runModal() == .OK, let url = panel.urls.first else { return }
        addProject(at: url)
    }

    func addProject(at url: URL) {
        let standardizedPath = url.standardizedFileURL.path

        if let existing = projects.first(where: { $0.project.rootPath == standardizedPath }) {
            activateProject(existing.id)
            return
        }

        let name = url.lastPathComponent.isEmpty ? "Project" : url.lastPathComponent
        let project = Project(name: name, rootPath: standardizedPath)
        let state = ProjectState(project: project, agents: [])
        projects.append(state)
        hydrate(state)
        _ = addAgent(to: state)
        scheduleSave()
    }

    func removeProject(_ projectID: UUID) {
        gitStatusService.stopPolling(projectID: projectID)
        gitMirrorTasks[projectID]?.cancel()
        gitMirrorTasks.removeValue(forKey: projectID)
        projects.removeAll { $0.id == projectID }

        if activeProjectID == projectID {
            if let nextProject = projects.first {
                activateProject(nextProject.id)
            } else {
                activeProjectID = nil
                activeAgentID = nil
            }
        }

        scheduleSave()
    }

    @discardableResult
    func addAgent(to project: ProjectState, title: String? = nil) -> AgentInfo {
        let providerID = preferredProviderID()
        let modelID = preferences.resolvedDefaultModelID(for: providerID, using: providerRegistry)

        let agent = Agent(
            title: title ?? defaultAgentTitle(for: project.agents.count + 1),
            configuration: AgentConfiguration(
                providerID: providerID,
                modelID: modelID,
                effort: preferences.defaultEffort,
                agentMode: preferences.defaultMode,
                agentAccess: preferences.defaultAccess
            )
        )

        let info = AgentInfo(agent: agent, projectRootPath: project.project.rootPath)
        configureAgent(info)
        project.agents.append(info)
        project.project.agentOrder = project.agents.map(\.id)
        project.project.updatedAt = Date()
        activateAgent(info.id, in: project.id)
        scheduleSave()
        return info
    }

    func removeAgent(_ agentID: UUID) {
        guard let project = project(for: agentID),
              let agentIndex = project.agents.firstIndex(where: { $0.id == agentID }) else {
            return
        }

        conversationService.cancelStreaming(for: agentID)
        conversationService.clearPendingRequests(for: agentID)

        let removedAgent = project.agents.remove(at: agentIndex)
        for session in removedAgent.terminalSessions {
            session.shutdown()
        }

        project.project.agentOrder = project.agents.map(\.id)
        project.project.updatedAt = Date()

        if activeAgentID == agentID {
            if project.agents.isEmpty {
                activeProjectID = project.id
                activeAgentID = nil
            } else {
                let fallbackIndex = min(agentIndex, max(0, project.agents.count - 1))
                activateAgent(project.agents[fallbackIndex].id, in: project.id)
            }
        }

        if project.lastSelectedAgentID == agentID {
            project.lastSelectedAgentID = project.agents.first?.id
        }

        ConversationPersistence.save(project: project)
        synchronizeActiveProjectPanels()
        scheduleSave()
    }

    func attachFiles(to agent: AgentInfo) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"

        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let attachment = Attachment(
                data: data,
                mimeType: Attachment.mimeType(forExtension: url.pathExtension),
                filename: url.lastPathComponent
            )
            agent.conversationState.addAttachment(attachment)
        }
    }

    func sendPrompt(for agent: AgentInfo) {
        let prompt = agent.conversationState.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        let attachments = agent.conversationState.pendingAttachments
        agent.conversationState.inputText = ""
        agent.conversationState.clearAttachments()
        dispatchPrompt(prompt, attachments: attachments, for: agent)
    }

    func activateProject(_ projectID: UUID) {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }
        activeProjectID = projectID
        activeAgentID = resolvedLastAgentID(for: project)
        synchronizeActiveProjectPanels()
    }

    func activateAgent(_ agentID: UUID, in projectID: UUID) {
        guard let project = projects.first(where: { $0.id == projectID }),
              project.agents.contains(where: { $0.id == agentID }) else {
            return
        }

        activeProjectID = projectID
        activeAgentID = agentID
        if project.lastSelectedAgentID != agentID {
            project.lastSelectedAgentID = agentID
        }
        synchronizeActiveProjectPanels()
    }

    func cancelPrompt(for agent: AgentInfo) {
        conversationService.cancelStreaming(for: agent.id)
        agent.syncExecutionStateFromConversation()
        if let project = project(for: agent.id) {
            ConversationPersistence.save(project: project)
        }
        scheduleSave()
    }

    func resetConversation(for agent: AgentInfo) {
        conversationService.cancelStreaming(for: agent.id)
        conversationService.clearPendingRequests(for: agent.id)
        agent.conversationState.resetConversation()
        agent.syncExecutionStateFromConversation()
        if let project = project(for: agent.id) {
            ConversationPersistence.save(project: project)
        }
        scheduleSave()
    }

    func queuedPromptText(at index: Int, for agent: AgentInfo) -> String? {
        conversationService.queuedPrompt(at: index, for: agent.id)
    }

    func updateQueuedPrompt(at index: Int, with prompt: String, for agent: AgentInfo) {
        conversationService.updateQueuedPrompt(
            at: index,
            with: prompt,
            for: agent.id,
            conversationState: agent.conversationState
        )
        persistConversation(for: agent)
    }

    func removeQueuedPrompt(at index: Int, for agent: AgentInfo) {
        conversationService.removeQueuedPrompt(at: index, for: agent.id, conversationState: agent.conversationState)
        persistConversation(for: agent)
    }

    func resumeConversation(for agent: AgentInfo) {
        guard let sessionID = agent.conversationState.sessionID, !sessionID.isEmpty else { return }
        agent.conversationState.dismissError()
        dispatchPrompt("continue", for: agent, resumeSessionID: sessionID)
    }

    func retryLastPrompt(for agent: AgentInfo) {
        guard let prompt = agent.conversationState.latestUserPrompt, !prompt.isEmpty else { return }
        agent.conversationState.dismissError()
        dispatchPrompt(prompt, for: agent)
    }

    func restartConversationSession(for agent: AgentInfo) {
        conversationService.cancelStreaming(for: agent.id)

        let latestPrompt = agent.conversationState.latestUserPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)

        agent.conversationState.sessionID = nil
        agent.conversationState.activeTurnID = nil
        agent.conversationState.lastStopReason = nil
        agent.conversationState.clearToolApprovalRequests()
        agent.conversationState.dismissError()
        agent.conversationState.applyLifecyclePhase(.idle)
        agent.conversationState.recordRuntimeActivity(
            kind: .session,
            tone: .warning,
            summary: "Session restarted",
            detail: "Started a fresh provider session.",
            state: "reset",
            turnID: nil
        )

        if let latestPrompt, !latestPrompt.isEmpty {
            dispatchPrompt(latestPrompt, for: agent)
        } else {
            persistConversation(for: agent)
        }
    }

    func dismissConversationError(for agent: AgentInfo) {
        agent.conversationState.dismissError()
        persistConversation(for: agent)
    }

    func respondToToolApproval(_ approvalID: UUID, approved: Bool, for agent: AgentInfo) {
        guard let approval = agent.conversationState.removeToolApprovalRequest(approvalID) else { return }

        let summary = approved ? "Approval granted" : "Approval denied"
        let detail = approval.parameters["command"] ?? approval.toolName
        agent.conversationState.recordRuntimeActivity(
            kind: .note,
            tone: approved ? .success : .warning,
            summary: summary,
            detail: detail,
            state: approved ? "approved" : "denied",
            turnID: agent.conversationState.activeTurnID
        )
        persistConversation(for: agent)

        Task { @MainActor in
            await conversationService.respondToToolApproval(approvalID, approved: approved, for: agent.id)
        }
    }

    func selectInspectorPath(_ path: String, for project: ProjectState) {
        project.selectedInspectorPath = path
    }

    func setInspectorComparisonMode(_ mode: InspectorComparisonMode, for project: ProjectState) {
        guard project.inspectorComparisonMode != mode else { return }
        project.inspectorComparisonMode = mode
        let visiblePaths = project.gitInfo.files
            .filter { file in
                switch mode {
                case .unstaged:
                    file.hasUnstagedChanges
                case .staged:
                    file.hasStagedChanges
                case .base:
                    true
                }
            }
            .map(\.path)

        if let selectedPath = project.selectedInspectorPath, !visiblePaths.contains(selectedPath) {
            project.selectedInspectorPath = visiblePaths.first
        } else if project.selectedInspectorPath == nil {
            project.selectedInspectorPath = visiblePaths.first
        }
        Task { @MainActor in
            await refreshInspector(for: project)
        }
    }

    func refreshRuntimeHealth() async {
        runtimeHealth = await runtimeDiscovery.allHealth()
    }

    func pushActiveProject() async {
        guard let project = activeProject else { return }
        project.gitActionMessage = nil
        project.isPerformingGitAction = true
        let success = await gitStatusService.push(projectID: project.id)
        project.isPerformingGitAction = false
        applyGitInfo(to: project.id)
        if !success {
            project.gitActionMessage = gitStatusService.lastFailureMessage[project.id] ?? "Push failed."
        }
    }

    func toggleCommitComposer() {
        guard let project = activeProject, project.gitInfo.isGitRepo, project.gitInfo.hasChanges else { return }
        project.gitActionMessage = nil
        withAnimation(FXAnimation.quick) {
            project.commitComposerVisible.toggle()
        }
    }

    func commitActiveProject() async {
        guard let project = activeProject else { return }

        let message = project.commitMessageDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            project.gitActionMessage = "Enter a commit message."
            return
        }

        project.gitActionMessage = nil
        project.isPerformingGitAction = true
        let success = await gitStatusService.commit(
            projectID: project.id,
            message: message,
            includeUntracked: project.includeUntrackedInCommit
        )
        project.isPerformingGitAction = false
        applyGitInfo(to: project.id)
        await refreshInspector(for: project)

        if success {
            project.commitMessageDraft = ""
            project.includeUntrackedInCommit = true
            withAnimation(FXAnimation.quick) {
                project.commitComposerVisible = false
            }
        } else {
            project.gitActionMessage = gitStatusService.lastFailureMessage[project.id] ?? "Commit failed."
        }
    }

    func refreshInspector(for project: ProjectState) async {
        guard let selectedPath = project.selectedInspectorPath else {
            project.selectedInspectorText = ""
            project.selectedInspectorContentKind = .message
            return
        }

        let fileStatus = project.gitInfo.files.first(where: { $0.path == selectedPath })

        switch project.inspectorComparisonMode {
        case .unstaged:
            guard fileStatus?.hasUnstagedChanges == true else {
                project.selectedInspectorText = fileStatus?.hasStagedChanges == true
                    ? "This file only has staged changes right now."
                    : "This file has no unstaged changes."
                project.selectedInspectorContentKind = .message
                return
            }

            let diff = await gitStatusService.diffUnstaged(projectID: project.id, path: selectedPath)
            if !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                project.selectedInspectorText = diff
                project.selectedInspectorContentKind = .diff
                return
            }

            let contents = await gitStatusService.fileContents(projectID: project.id, path: selectedPath)
            if !contents.isEmpty {
                project.selectedInspectorText = contents
                project.selectedInspectorContentKind = .file
            } else {
                project.selectedInspectorText = "No local content available for this file."
                project.selectedInspectorContentKind = .message
            }

        case .staged:
            guard fileStatus?.hasStagedChanges == true else {
                project.selectedInspectorText = fileStatus?.hasUnstagedChanges == true
                    ? "This file has unstaged changes, but nothing staged yet."
                    : "This file has no staged changes."
                project.selectedInspectorContentKind = .message
                return
            }

            let diff = await gitStatusService.diffStaged(projectID: project.id, path: selectedPath)
            if !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                project.selectedInspectorText = diff
                project.selectedInspectorContentKind = .diff
                return
            }

            if let stagedContents = await gitStatusService.fileContentsFromIndex(projectID: project.id, path: selectedPath),
               !stagedContents.isEmpty {
                project.selectedInspectorText = stagedContents
                project.selectedInspectorContentKind = .file
            } else {
                project.selectedInspectorText = "No staged content is available for this file."
                project.selectedInspectorContentKind = .message
            }

        case .base:
            guard project.gitInfo.hasCommits else {
                project.selectedInspectorText = "This repository has no committed base revision yet."
                project.selectedInspectorContentKind = .message
                return
            }

            if fileStatus?.isUntracked == true {
                project.selectedInspectorText = "This file is new locally and does not exist in HEAD."
                project.selectedInspectorContentKind = .message
                return
            }

            let diff = await gitStatusService.diffAgainstHead(projectID: project.id, path: selectedPath)
            if !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                project.selectedInspectorText = diff
                project.selectedInspectorContentKind = .diff
                return
            }

            if let baseContents = await gitStatusService.fileContentsAtHead(projectID: project.id, path: selectedPath) {
                project.selectedInspectorText = baseContents
                project.selectedInspectorContentKind = .file
            } else {
                project.selectedInspectorText = "This file does not exist in the current base revision."
                project.selectedInspectorContentKind = .message
            }
        }
    }

    func scheduleSave() {
        scheduledSaveTask?.cancel()
        scheduledSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            ProjectPersistence.save(self)
        }
    }

    private func hydrate(_ project: ProjectState) {
        configureProject(project)
        project.refreshFiles()
        if !project.agents.isEmpty {
            for agent in project.agents {
                configureAgent(agent)
                agent.setTerminalLaunchDirectory(project.project.rootPath)
                agent.syncExecutionStateFromConversation()
            }
        }

        gitStatusService.startPolling(projectID: project.id, rootPath: project.project.rootPath)
        gitMirrorTasks[project.id]?.cancel()
        gitMirrorTasks[project.id] = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                applyGitInfo(to: project.id)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func applyGitInfo(to projectID: UUID) {
        guard let project = projects.first(where: { $0.id == projectID }),
              let gitInfo = gitStatusService.info[projectID] else {
            return
        }

        project.gitInfo = gitInfo
        for agent in project.agents {
            agent.applyGitInfo(gitInfo)
        }

        if !gitInfo.hasChanges {
            project.commitComposerVisible = false
            project.commitMessageDraft = ""
            project.gitActionMessage = nil
        }

        for agent in project.agents where agent.workspace.splitContent == .diff {
            agent.workspace.splitOpen = false
        }

        if activeProjectID == projectID, rightPanelTab == .files {
            rightPanelTab = .changes
        }

        if activeProjectID == projectID {
            synchronizeActiveProjectPanels()
        }

        if project.selectedInspectorPath == nil {
            project.selectedInspectorPath = gitInfo.files.first?.path ?? project.repositoryFiles.first
        }
    }

    private func canShowGitPanel(for project: ProjectState?) -> Bool {
        guard let project else { return false }
        return project.gitInfo.isGitRepo && project.gitInfo.hasChanges
    }

    func toggleGitPanel() {
        guard activeProjectCanShowGitPanel else { return }

        withAnimation(FXAnimation.panel) {
            let shouldShowPanel = settingsVisible || !rightPanelVisible || rightPanelTab != .changes
            settingsVisible = false
            rightPanelTab = .changes
            rightPanelVisible = shouldShowPanel
        }
    }

    func toggleBrowserPreview() {
        guard let agent = activeAgent else { return }

        withAnimation(FXAnimation.panel) {
            if agent.workspace.splitOpen && agent.workspace.splitContent == .browser {
                agent.workspace.splitOpen = false
            } else {
                agent.workspace.splitContent = .browser
                agent.workspace.splitOpen = true
            }
        }
    }

    private func synchronizeActiveProjectPanels() {
        if !canShowGitPanel(for: activeProject) {
            rightPanelVisible = false
        }
    }

    private func configureAgent(_ agent: AgentInfo) {
        agent.onChange = { [weak self] in
            self?.persistStateIfBootstrapped()
        }
    }

    private func configureProject(_ project: ProjectState) {
        project.onChange = { [weak self] in
            self?.persistStateIfBootstrapped()
        }
    }

    private func persistStateIfBootstrapped() {
        guard isBootstrapped else { return }
        scheduleSave()
    }

    private func project(for agentID: UUID) -> ProjectState? {
        projects.first { project in
            project.agents.contains { $0.id == agentID }
        }
    }

    private func resolvedLastAgentID(for project: ProjectState?) -> UUID? {
        guard let project else { return nil }
        if let lastSelectedAgentID = project.lastSelectedAgentID,
           project.agents.contains(where: { $0.id == lastSelectedAgentID }) {
            return lastSelectedAgentID
        }
        return project.agents.first?.id
    }

    private func dispatchPrompt(
        _ prompt: String,
        attachments: [Attachment] = [],
        for agent: AgentInfo,
        resumeSessionID: String? = nil
    ) {
        guard let project = project(for: agent.id) else { return }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }

        agent.markConversationStarted()

        conversationService.send(
            prompt: trimmedPrompt,
            attachments: attachments,
            to: agent.conversationState,
            providerID: agent.providerID,
            model: agent.modelID,
            effort: agent.effort,
            systemPrompt: agent.systemPrompt,
            agentMode: agent.agentMode,
            agentAccess: agent.agentAccess,
            workingDirectory: project.project.rootURL,
            resumeSessionID: resumeSessionID,
            onComplete: { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    agent.syncExecutionStateFromConversation()
                    ConversationPersistence.save(project: project)
                    gitStatusService.forceRefresh(projectID: project.id)
                    await refreshInspector(for: project)
                    scheduleSave()
                }
            }
        )

        scheduleSave()
    }

    private func persistConversation(for agent: AgentInfo) {
        if let project = project(for: agent.id) {
            ConversationPersistence.save(project: project)
        }
        scheduleSave()
    }

    private func preferredProviderID() -> String {
        let configuredProviderID = preferences.resolvedDefaultProviderID(using: providerRegistry)
        if providerRegistry.provider(for: configuredProviderID) != nil {
            return configuredProviderID
        }
        if runtimeHealth["claude"]?.isUsable == true {
            return "claude"
        }
        if runtimeHealth["codex"]?.isUsable == true {
            return "codex"
        }
        return configuredProviderID
    }

    private func defaultModelID(for providerID: String) -> String {
        switch providerID {
        case "codex":
            "gpt-5.4"
        default:
            "sonnet"
        }
    }

    private func defaultAgentTitle(for index: Int) -> String {
        "Agent \(index)"
    }

    private func normalizeLegacyAgentTitles() -> Bool {
        var didChange = false

        for project in projects {
            for (index, agent) in project.agents.enumerated() {
                guard agent.conversationState.messages.isEmpty,
                      agent.conversationState.runtimeActivities.isEmpty,
                      let normalized = normalizedLegacyTitle(agent.title, fallbackIndex: index + 1),
                      normalized != agent.title else {
                    continue
                }

                agent.agent.title = normalized
                project.project.updatedAt = Date()
                didChange = true
            }
        }

        return didChange
    }

    private func normalizedLegacyTitle(_ title: String, fallbackIndex: Int) -> String? {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if normalized == "main" {
            return defaultAgentTitle(for: fallbackIndex)
        }

        if normalized.hasPrefix("agent-"),
           let index = Int(normalized.dropFirst("agent-".count)) {
            return defaultAgentTitle(for: index)
        }

        return nil
    }

    #if DEBUG
    private func seedFromCurrentDirectoryIfUseful() {
        let path = FileManager.default.currentDirectoryPath
        guard path != "/", FileManager.default.fileExists(atPath: path) else { return }
        addProject(at: URL(fileURLWithPath: path))
    }
    #endif
}
