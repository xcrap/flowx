import AppKit
import CryptoKit
import Darwin
import Foundation
import FXAgent
import FXCore
import FXDesign
import FXTerminal
import SwiftUI
import UniformTypeIdentifiers

private final class NotificationObserverToken: @unchecked Sendable {
    private var observers: [NSObjectProtocol] = []

    func store(_ observer: NSObjectProtocol) {
        observers.append(observer)
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

enum RightPanelTab: String, CaseIterable, Codable, Sendable {
    case changes = "CHANGES"
    case files = "FILES"
}

enum InspectorComparisonMode: String, CaseIterable, Codable, Sendable {
    case unstaged = "Unstaged"
    case staged = "Staged"
    case base = "Base"
}

enum InspectorContentKind {
    case diff
    case file
    case message
}

enum InspectorDiffDisplayMode: String, CaseIterable, Codable, Sendable {
    case inline = "Inline"
    case split = "Split"
}

enum AgentStatus: String {
    case idle
    case running
    case waitingForInput
    case waitingForApproval
    case completed
    case error
}

enum ThreadLifecycleActionKind: String, Sendable, Hashable {
    case deleteDraft
    case archiveProviderTask
    case deleteProviderTask
    case moveProviderTaskToTrash

    var title: String {
        switch self {
        case .deleteDraft: "Delete Draft"
        case .archiveProviderTask: "Archive Task"
        case .deleteProviderTask: "Delete Permanently"
        case .moveProviderTaskToTrash: "Move Task to Trash"
        }
    }

    var shortTitle: String {
        switch self {
        case .deleteDraft: "Delete"
        case .archiveProviderTask: "Archive"
        case .deleteProviderTask: "Delete Permanently"
        case .moveProviderTaskToTrash: "Move to Trash"
        }
    }

    var systemImage: String {
        switch self {
        case .deleteDraft, .deleteProviderTask, .moveProviderTaskToTrash: "trash"
        case .archiveProviderTask: "archivebox"
        }
    }

    var isDestructive: Bool {
        self != .archiveProviderTask
    }

    var isProviderAction: Bool {
        self != .deleteDraft
    }
}

struct ThreadLifecycleConfirmation: Identifiable {
    let id = UUID()
    let action: ThreadLifecycleActionKind
    let agentID: UUID?
    let projectID: UUID
    let providerIdentity: NativeThreadIdentity?
    let threadTitle: String

    var title: String { action.title }

    var message: String {
        switch action {
        case .deleteDraft:
            "Delete “\(threadTitle)” from FlowX? Its local draft, attachments, terminals, and workspace layout will be removed. Any unbound provider task is left untouched and may reappear after refresh."
        case .archiveProviderTask:
            "Archive “\(threadTitle)” in Codex? Codex also archives any spawned descendants. You can restore this parent from the project's Archived section."
        case .deleteProviderTask:
            "Permanently delete “\(threadTitle)” from Codex? Codex also deletes any spawned descendants. This cannot be undone."
        case .moveProviderTaskToTrash:
            "Move “\(threadTitle)” and its Claude session data to macOS Trash? Stop any Claude Code process using it first. Claude does not expose live task status, but the files can be recovered from Trash."
        }
    }
}

struct NativeThreadIdentity: Codable, Sendable, Hashable {
    var providerID: String
    var providerSource: String
    var sessionID: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.providerID == rhs.providerID && lhs.sessionID == rhs.sessionID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(providerID)
        hasher.combine(sessionID)
    }
}

struct NativeThreadBinding: Codable, Sendable, Equatable {
    var identity: NativeThreadIdentity
    var title: String
    var preview: String
    var workingDirectory: String
    var createdAt: Date
    var updatedAt: Date
    var model: String?
    var effort: String?
    var agentMode: AgentMode?
    var agentAccess: AgentAccess?
    var status: String?

    init(summary: ProviderNativeThreadSummary) {
        identity = NativeThreadIdentity(
            providerID: summary.providerID,
            providerSource: summary.source,
            sessionID: summary.id
        )
        title = summary.title
        preview = summary.preview
        workingDirectory = summary.workingDirectory
        createdAt = summary.createdAt
        updatedAt = summary.updatedAt
        model = summary.model
        effort = summary.effort
        agentMode = summary.agentMode
        agentAccess = summary.agentAccess
        status = summary.status
    }
}

struct EffectiveAgentConfiguration: Sendable, Equatable {
    var modelID: String?
    var effort: String?
    var agentMode: AgentMode?
    var agentAccess: AgentAccess?
}

private enum FlowXSlashCommand {
    case compact
    case goalView
    case goalSet(String)
    case goalStatus(ConversationGoalStatus)
    case goalClear

    init?(_ rawPrompt: String) {
        let trimmed = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }

        let pieces = trimmed.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard let command = pieces.first?.dropFirst().lowercased() else { return nil }
        let argument = pieces.count > 1
            ? String(pieces[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        switch command {
        case "compact":
            self = .compact
        case "goal":
            let normalizedArgument = argument.lowercased()
            switch normalizedArgument {
            case "":
                self = .goalView
            case "pause":
                self = .goalStatus(.paused)
            case "resume":
                self = .goalStatus(.active)
            case "clear":
                self = .goalClear
            default:
                self = .goalSet(argument)
            }
        default:
            return nil
        }
    }
}

private struct AttachmentLoadResult: Sendable {
    var attachments: [Attachment]
    var errors: [String]
}

enum SplitContent: String, Codable, Sendable {
    case diff
    case browser
}

@Observable
@MainActor
final class WorkspaceState {
    var splitOpen: Bool = false { didSet { notifyIfChanged(from: oldValue, to: splitOpen) } }
    var splitContent: SplitContent = .diff { didSet { notifyIfChanged(from: oldValue, to: splitContent) } }
    var splitRatio: CGFloat = 0.5 { didSet { notifyIfChanged(from: oldValue, to: splitRatio) } }
    var terminalVisible: Bool = false { didSet { notifyIfChanged(from: oldValue, to: terminalVisible) } }
    var terminalHeight: CGFloat = 220 { didSet { notifyIfChanged(from: oldValue, to: terminalHeight) } }
    var terminalCount: Int = 1 { didSet { notifyIfChanged(from: oldValue, to: terminalCount) } }
    var browserURLString: String = "" { didSet { notifyIfChanged(from: oldValue, to: browserURLString) } }
    var conversationScrollOffset: CGFloat = 0 {
        didSet { notifyIfChanged(from: oldValue, to: conversationScrollOffset) }
    }
    var conversationPinnedToBottom: Bool = true {
        didSet { notifyIfChanged(from: oldValue, to: conversationPinnedToBottom) }
    }

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

    private func notifyIfChanged<Value: Equatable>(from oldValue: Value, to newValue: Value) {
        guard oldValue != newValue else { return }
        onChange?()
    }
}

@Observable
@MainActor
final class AgentInfo: Identifiable {
    let id: UUID
    var agent: Agent
    var conversationState: ConversationState
    let projectRootPath: String
    @ObservationIgnored var terminalSessions: [TerminalSession]
    var workspace: WorkspaceState
    var nativeThreadBinding: NativeThreadBinding?
    var nativeImageSidecar: [NativeImageSidecarEntry]
    var isLoadingNativeTranscript = false
    var nativeTranscriptError: String?
    var nativeTranscriptLoadedAt: Date?
    /// Ephemeral attention state: completed work is only called out until the
    /// user opens that thread. Historical provider threads stay visually quiet.
    var hasUnseenCompletion = false

    var onChange: (() -> Void)?
    init(
        agent: Agent,
        projectRootPath: String,
        conversationState: ConversationState? = nil,
        workspace: WorkspaceState? = nil,
        nativeThreadBinding: NativeThreadBinding? = nil,
        nativeImageSidecar: [NativeImageSidecarEntry] = []
    ) {
        id = agent.id
        var normalizedAgent = agent
        normalizedAgent.configuration.providerID = Self.normalizedProviderID(
            nativeThreadBinding?.identity.providerID ?? normalizedAgent.configuration.providerID
        )
        if let modelID = normalizedAgent.configuration.modelID {
            normalizedAgent.configuration.modelID = Self.normalizedModelID(
                modelID,
                providerID: normalizedAgent.configuration.providerID
            )
        }
        if let effort = normalizedAgent.configuration.effort {
            normalizedAgent.configuration.effort = Self.normalizedEffort(effort)
        }
        self.agent = normalizedAgent
        self.projectRootPath = projectRootPath
        let resolvedConversation = conversationState ?? ConversationState(agentID: agent.id)
        if let nativeThreadBinding {
            resolvedConversation.sessionID = nativeThreadBinding.identity.sessionID
        }
        resolvedConversation.activeProviderID = normalizedAgent.configuration.providerID
        resolvedConversation.activeModelID = normalizedAgent.configuration.modelID ?? nativeThreadBinding?.model
        resolvedConversation.configuredContextWindow = agent.configuration.contextWindowSize
        self.conversationState = resolvedConversation
        self.workspace = workspace ?? WorkspaceState()
        self.nativeThreadBinding = nativeThreadBinding
        self.nativeImageSidecar = nativeImageSidecar
        terminalSessions = []
        self.workspace.onChange = { [weak self] in
            self?.onChange?()
        }
    }

    var terminalPaneCount: Int {
        max(1, min(3, workspace.terminalCount))
    }

    var visibleTerminalSessions: [TerminalSession] {
        // Provider discovery can materialize hundreds of task rows. A terminal
        // session is only useful once its panel is actually visible, so avoid
        // allocating one delegate/session graph for every dormant task during
        // startup.
        syncTerminalSessions(to: terminalPaneCount)
        return Array(terminalSessions.prefix(terminalPaneCount))
    }

    var title: String {
        get { agent.title }
        set {
            agent.title = newValue
            onChange?()
        }
    }

    var providerID: String {
        get { Self.normalizedProviderID(agent.configuration.providerID) }
        set {
            agent.configuration.providerID = Self.normalizedProviderID(newValue)
            agent.configuration.modelID = agent.configuration.modelID.map {
                Self.normalizedModelID($0, providerID: agent.configuration.providerID)
            }
            onChange?()
        }
    }

    var modelID: String {
        get {
            Self.normalizedModelID(
                agent.configuration.modelID ?? nativeThreadBinding?.model,
                providerID: providerID
            )
        }
        set {
            agent.configuration.modelID = Self.normalizedModelID(newValue, providerID: providerID)
            onChange?()
        }
    }

    var explicitModelID: String? {
        get { agent.configuration.modelID }
        set {
            agent.configuration.modelID = newValue.map { Self.normalizedModelID($0, providerID: providerID) }
            onChange?()
        }
    }

    var nativeModelID: String? {
        nativeThreadBinding?.model
    }

    var effort: String {
        get { Self.normalizedEffort(agent.configuration.effort ?? nativeThreadBinding?.effort) }
        set {
            agent.configuration.effort = Self.normalizedEffort(newValue)
            onChange?()
        }
    }

    var explicitEffort: String? {
        get { agent.configuration.effort }
        set {
            agent.configuration.effort = newValue.map { Self.normalizedEffort($0) }
            onChange?()
        }
    }

    var nativeEffort: String? {
        nativeThreadBinding?.effort
    }

    var nativeAgentMode: AgentMode? {
        nativeThreadBinding?.agentMode
    }

    var nativeAgentAccess: AgentAccess? {
        nativeThreadBinding?.agentAccess
    }

    var isProviderNativeThread: Bool {
        nativeThreadBinding != nil
    }

    var nativePreview: String? {
        guard let preview = nativeThreadBinding?.preview.trimmingCharacters(in: .whitespacesAndNewlines),
              !preview.isEmpty else {
            return nil
        }
        return preview
    }

    var nativeUpdatedAt: Date? {
        nativeThreadBinding?.updatedAt
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

    var explicitAgentMode: AgentMode? {
        get { agent.configuration.agentMode }
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

    var explicitAgentAccess: AgentAccess? {
        get { agent.configuration.agentAccess }
        set {
            agent.configuration.agentAccess = newValue
            onChange?()
        }
    }

    var providerName: String {
        switch providerID {
        case "codex":
            "Codex"
        default:
            providerID.capitalized
        }
    }

    var status: AgentStatus {
        if conversationState.error != nil
            || nativeTranscriptError != nil
            || agent.executionState == .failure
            || nativeThreadBinding?.status?.lowercased() == "systemerror" {
            return .error
        }
        if !conversationState.pendingUserInputRequests.isEmpty {
            return .waitingForInput
        }
        if conversationState.pendingToolApprovalCount > 0 {
            return .waitingForApproval
        }
        if conversationState.isStreaming
            || agent.executionState == .running
            || nativeThreadBinding?.status?.lowercased() == "active" {
            return .running
        }
        if agent.executionState == .success || nativeThreadBinding != nil {
            return .completed
        }
        return .idle
    }

    var shouldShowStatusIndicator: Bool {
        return switch status {
        case .running, .waitingForInput, .waitingForApproval, .error:
            true
        case .completed:
            hasUnseenCompletion
        case .idle:
            false
        }
    }

    var messages: [ConversationMessage] {
        conversationState.messages
    }

    var isStreaming: Bool {
        conversationState.isStreaming
    }

    var isTranscriptRunning: Bool {
        conversationState.isStreaming
            || agent.executionState == .running
            || nativeThreadBinding?.status?.lowercased() == "active"
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

    func markConversationStarted() {
        hasUnseenCompletion = false
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

    nonisolated private static let defaultProviderID = "codex"
    nonisolated private static let defaultCodexModelID = "gpt-5.6-sol"
    nonisolated private static let defaultClaudeModelID = "claude-fable-5"

    nonisolated static func normalizedProviderID(_ providerID: String?) -> String {
        guard let providerID = providerID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !providerID.isEmpty else {
            return defaultProviderID
        }

        switch providerID.lowercased() {
        case "anthropic", "claude-code":
            return "claude"
        default:
            return providerID
        }
    }

    nonisolated static func normalizedModelID(_ modelID: String?, providerID: String? = nil) -> String {
        if let modelID = modelID?.trimmingCharacters(in: .whitespacesAndNewlines), !modelID.isEmpty {
            switch modelID {
            case "fable":
                return defaultClaudeModelID
            default:
                return modelID
            }
        }

        return normalizedProviderID(providerID) == "claude" ? defaultClaudeModelID : defaultCodexModelID
    }

    nonisolated static func normalizedDefaultModelID(_ modelID: String?, providerID: String? = nil) -> String {
        normalizedModelID(modelID, providerID: providerID)
    }

    nonisolated static func normalizedEffort(_ effort: String?) -> String {
        guard let effort, !effort.isEmpty else { return "medium" }

        switch effort.lowercased() {
        case "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra":
            return effort.lowercased()
        default:
            return "medium"
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
    var nativePresentationAgentIDs: [NativeThreadIdentity: UUID] { didSet { onChange?() } }
    var archivedNativeThreadBindings: [NativeThreadBinding] = []
    var isSyncingNativeThreads = false
    var nativeThreadSyncError: String?
    var threadLifecycleNotice: String?
    var threadLifecycleNoticeIsError = false

    var gitInfo = GitStatusService.GitInfo()
    var repositoryFiles: [String] = []
    var selectedInspectorPath: String? { didSet { onChange?() } }
    var selectedInspectorText: String = ""
    var selectedInspectorContentKind: InspectorContentKind = .message
    var inspectorComparisonMode: InspectorComparisonMode = .unstaged { didSet { onChange?() } }
    var inspectorDiffDisplayMode: InspectorDiffDisplayMode = .inline { didSet { onChange?() } }
    var commitComposerVisible = false
    var commitMessageDraft = ""
    var includeUntrackedInCommit = true
    var isPerformingGitAction = false
    var gitActionMessage: String?
    var onChange: (() -> Void)?
    private var refreshFilesTask: Task<Void, Never>?

    init(
        project: Project,
        agents: [AgentInfo],
        isExpanded: Bool = true,
        nativePresentationAgentIDs: [NativeThreadIdentity: UUID] = [:]
    ) {
        id = project.id
        self.project = project
        self.agents = agents
        self.isExpanded = isExpanded
        self.lastSelectedAgentID = agents.first?.id
        self.nativePresentationAgentIDs = nativePresentationAgentIDs
        for agent in agents {
            if let identity = agent.nativeThreadBinding?.identity {
                self.nativePresentationAgentIDs[identity] = agent.id
            }
        }
        if self.project.agentOrder.isEmpty {
            self.project.agentOrder = agents.map(\.id)
        }
    }

    func refreshFiles(limit: Int = 500) {
        refreshFilesTask?.cancel()
        let rootURL = project.rootURL

        let enumerationTask = Task.detached(priority: .userInitiated) {
            Self.enumeratedFiles(at: rootURL, limit: limit)
        }
        refreshFilesTask = Task { [weak self] in
            let files = await withTaskCancellationHandler {
                await enumerationTask.value
            } onCancel: {
                enumerationTask.cancel()
            }

            guard let self, !Task.isCancelled else { return }
            self.repositoryFiles = files
            if self.selectedInspectorPath == nil
                || !files.contains(self.selectedInspectorPath ?? "") {
                self.selectedInspectorPath = files.first
            }
        }
    }

    nonisolated private static func enumeratedFiles(at rootURL: URL, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        if let gitFiles = gitIndexedFiles(at: rootURL, limit: limit) {
            return gitFiles
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var files: [String] = []
        let candidateLimit = max(limit, min(limit * 20, 20_000))
        while let url = enumerator.nextObject() as? URL {
            guard !Task.isCancelled else { return [] }
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            let relativePath = url.pathComponents
                .dropFirst(rootURL.pathComponents.count)
                .joined(separator: "/")

            if values.isSymbolicLink == true {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            if shouldSkip(relativePath, isDirectory: values.isDirectory == true) {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            if values.isRegularFile == true {
                files.append(relativePath)
                if files.count >= candidateLimit {
                    break
                }
            }
        }

        return Array(files.sorted().prefix(limit))
    }

    nonisolated private static func gitIndexedFiles(at rootURL: URL, limit: Int) -> [String]? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["ls-files", "-co", "--exclude-standard", "--deduplicate", "-z"]
        process.currentDirectoryURL = rootURL
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment

        do {
            try process.run()
        } catch {
            return nil
        }

        let timeout = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else { return }
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [weak process] in
                if process?.isRunning == true { Darwin.kill(pid, SIGKILL) }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: timeout)

        var output = Data()
        var wasTruncated = false
        let maximumBytes = 16 * 1_024 * 1_024
        while let chunk = try? pipe.fileHandleForReading.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            guard !Task.isCancelled else {
                process.terminate()
                break
            }
            let remaining = maximumBytes - output.count
            if remaining > 0 { output.append(chunk.prefix(remaining)) }
            if chunk.count > remaining || output.count >= maximumBytes {
                wasTruncated = true
                process.terminate()
                break
            }
        }
        process.waitUntilExit()
        timeout.cancel()
        guard !Task.isCancelled,
              process.terminationStatus == 0 || wasTruncated else {
            return nil
        }

        var seen: Set<String> = []
        let paths = output.split(separator: 0, omittingEmptySubsequences: true).compactMap { bytes -> String? in
            let path = String(decoding: bytes, as: UTF8.self)
            guard !path.hasPrefix("/"),
                  !NSString(string: path).pathComponents.contains(".."),
                  !ProjectFileIndexPolicy.shouldSkipFile(relativePath: path),
                  seen.insert(path).inserted else {
                return nil
            }
            return path
        }
        return Array(paths.sorted().prefix(limit))
    }

    nonisolated private static func shouldSkip(_ relativePath: String, isDirectory: Bool) -> Bool {
        ProjectFileIndexPolicy.shouldSkip(relativePath: relativePath, isDirectory: isDirectory)
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
        static let defaultFollowUpMode = "flowx.defaultFollowUpMode"
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

    var defaultFollowUpMode: PromptFollowUpMode {
        didSet { defaults.set(defaultFollowUpMode.rawValue, forKey: Keys.defaultFollowUpMode) }
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
        let restoredProviderID = AgentInfo.normalizedProviderID(defaults.string(forKey: Keys.defaultProviderID))
        defaultProviderID = restoredProviderID
        defaultModelID = AgentInfo.normalizedDefaultModelID(
            defaults.string(forKey: Keys.defaultModelID),
            providerID: restoredProviderID
        )
        defaultEffort = AgentInfo.normalizedEffort(defaults.string(forKey: Keys.defaultEffort))
        defaultAccess = AgentAccess(rawValue: defaults.string(forKey: Keys.defaultAccess) ?? "") ?? .fullAccess
        defaultMode = AgentMode(rawValue: defaults.string(forKey: Keys.defaultMode) ?? "") ?? .auto
        defaultFollowUpMode = PromptFollowUpMode(
            rawValue: defaults.string(forKey: Keys.defaultFollowUpMode) ?? ""
        ) ?? .steer
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
        defaultProviderID = AgentInfo.normalizedProviderID(providerID)
        normalizeProviderDefaults(using: registry)
    }

    func normalizeProviderDefaults(using registry: ProviderRegistry) {
        defaultProviderID = AgentInfo.normalizedProviderID(defaultProviderID)
        defaultModelID = AgentInfo.normalizedModelID(defaultModelID, providerID: defaultProviderID)
        defaultEffort = AgentInfo.normalizedEffort(defaultEffort)

        if registry.provider(for: defaultProviderID) == nil {
            defaultProviderID = registry.allProviders.sorted { $0.displayName < $1.displayName }.first?.id ?? AgentInfo.normalizedProviderID(nil)
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
        let providerID = AgentInfo.normalizedProviderID(defaultProviderID)
        if registry.provider(for: providerID) != nil {
            return providerID
        }
        return registry.allProviders.sorted { $0.displayName < $1.displayName }.first?.id ?? AgentInfo.normalizedProviderID(nil)
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
            AgentInfo.normalizedModelID(nil, providerID: "codex")
        case "claude":
            AgentInfo.normalizedModelID(nil, providerID: "claude")
        default:
            AgentInfo.normalizedModelID(nil, providerID: providerID)
        }
    }
}

enum FlowXLayoutDefaults {
    static let defaultRightPanelWidth: CGFloat = 760
    static let minRightPanelWidth: CGFloat = 560
    static let maxRightPanelWidth: CGFloat = 1100
}

@Observable
@MainActor
final class AppState {
    private struct NativeWorkspaceSyncRequest {
        var projectIDs: [UUID]
        var forceTranscriptRefresh: Bool
        var discoveryMode: ProviderNativeThreadDiscoveryMode

        mutating func merge(_ request: NativeWorkspaceSyncRequest) {
            for projectID in request.projectIDs where !projectIDs.contains(projectID) {
                projectIDs.append(projectID)
            }
            forceTranscriptRefresh = forceTranscriptRefresh || request.forceTranscriptRefresh
            if request.discoveryMode == .repair {
                discoveryMode = .repair
            }
        }
    }

    @ObservationIgnored private let browserSessionCache = BrowserSessionCache(capacity: 3)
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
    var threadLifecycleConfirmation: ThreadLifecycleConfirmation?
    var runtimeHealth: [String: BinaryHealth] = [:]
    var isBootstrapped = false

    let providerRegistry = ProviderRegistry()
    let conversationService: ConversationService
    let gitStatusService = GitStatusService()

    private let runtimeDiscovery = RuntimeDiscovery()
    private var scheduledSaveTask: Task<Void, Never>?
    @ObservationIgnored private let terminationObserver = NotificationObserverToken()
    private var nativeWorkspaceSyncTask: Task<Void, Never>?
    @ObservationIgnored private var activeNativeWorkspaceSyncRequest: NativeWorkspaceSyncRequest?
    @ObservationIgnored private var pendingNativeWorkspaceSyncRequest: NativeWorkspaceSyncRequest?
    @ObservationIgnored private var nativeSyncingProjectIDs: Set<UUID> = []
    private var nativeActiveProjectPollingTask: Task<Void, Never>?
    private var nativeTranscriptTasks: [UUID: Task<Void, Never>] = [:]
    private var nativeTranscriptLoadIDs: [UUID: UUID] = [:]
    @ObservationIgnored private var steeringPromptTasks: [UUID: Task<Void, Never>] = [:]
    private var steeringPromptSubmissionIDs: [UUID: UUID] = [:]
    private var threadLifecycleAgentIDs: Set<UUID> = []
    private var archivedThreadLifecycleIdentities: Set<NativeThreadIdentity> = []
    private var prunedNativePresentations: [UUID: [NativeThreadIdentity: AgentInfo]] = [:]
    private var isShuttingDown = false

    nonisolated private static let maximumAttachmentBytes = 20 * 1_024 * 1_024
    nonisolated private static let maximumPendingAttachmentBytes = 50 * 1_024 * 1_024
    nonisolated private static let maximumPendingAttachmentCount = 10
    nonisolated private static let maximumPrunedNativePresentationsPerProject = 32

    var activeProject: ProjectState? {
        projects.first { $0.project.id == activeProjectID }
    }

    var activeAgent: AgentInfo? {
        guard let project = activeProject, let agentID = activeAgentID else { return nil }
        return project.agents.first { $0.id == agentID }
    }

    func effectiveConfiguration(for agent: AgentInfo) -> EffectiveAgentConfiguration {
        resolvedConfiguration(for: agent, includeExplicitOverrides: true)
    }

    func inheritedConfiguration(for agent: AgentInfo) -> EffectiveAgentConfiguration {
        resolvedConfiguration(for: agent, includeExplicitOverrides: false)
    }

    private func resolvedConfiguration(
        for agent: AgentInfo,
        includeExplicitOverrides: Bool
    ) -> EffectiveAgentConfiguration {
        let defaultModelID = preferences.resolvedDefaultModelID(
            for: agent.providerID,
            using: providerRegistry
        )
        let explicitModelID = includeExplicitOverrides ? agent.explicitModelID : nil
        let explicitEffort = includeExplicitOverrides ? agent.explicitEffort : nil
        let explicitMode = includeExplicitOverrides ? agent.explicitAgentMode : nil
        let explicitAccess = includeExplicitOverrides ? agent.explicitAgentAccess : nil
        let usesAppDefaults = !agent.isProviderNativeThread
        let resolvedModelID = explicitModelID
            ?? agent.nativeModelID
            ?? (usesAppDefaults ? defaultModelID : nil)
        let resolvedEffort = explicitEffort
            ?? agent.nativeEffort
            ?? (agent.isProviderNativeThread
                ? (providerRegistry.provider(for: agent.providerID) as? any AIProviderRuntimeDefaultsProviding)?
                    .runtimeDefaultEffort
                : nil)
            ?? (usesAppDefaults ? preferences.defaultEffort : nil)

        return EffectiveAgentConfiguration(
            modelID: resolvedModelID.map {
                AgentInfo.normalizedModelID($0, providerID: agent.providerID)
            },
            effort: resolvedEffort.map(AgentInfo.normalizedEffort),
            agentMode: explicitMode
                ?? agent.nativeAgentMode
                ?? (usesAppDefaults ? preferences.defaultMode : nil),
            agentAccess: explicitAccess
                ?? agent.nativeAgentAccess
                ?? (usesAppDefaults ? preferences.defaultAccess : nil)
        )
    }

    func browserViewModel(for agentID: UUID) -> BrowserViewModel {
        browserSessionCache.model(for: agentID)
    }

    var activeProjectCanShowGitPanel: Bool {
        canShowGitPanel(for: activeProject)
    }

    func isSubmittingSteer(for agentID: UUID) -> Bool {
        steeringPromptSubmissionIDs[agentID] != nil
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
        gitStatusService.onInfoChange = { [weak self] projectID, gitInfo in
            self?.applyGitInfo(gitInfo, to: projectID)
        }
        terminationObserver.store(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.shutdownForTermination()
            }
        })
        terminationObserver.store(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleApplicationDidBecomeActive()
            }
        })

        Task { @MainActor in
            await bootstrap()
        }
    }

    func bootstrap() async {
        // Restore and hydrate the local shell before binary discovery. A
        // missing CLI can make its login-shell fallback slow, but that must
        // not hold the persisted workspace UI behind a provider probe.
        await ProjectPersistence.load(into: self)

        providerRegistry.register(CodexProvider(discovery: runtimeDiscovery))
        providerRegistry.register(ClaudeCodeProvider(discovery: runtimeDiscovery))
        preferences.normalizeProviderDefaults(using: providerRegistry)
        runtimeHealth = [
            BinarySpec.codex.id: .checking,
            BinarySpec.claude.id: .checking,
        ]
        let normalizedLegacyTitles = normalizeLegacyAgentTitles()
        for project in projects {
            hydrate(project)
        }

        #if DEBUG
        if projects.isEmpty {
            seedFromCurrentDirectoryIfUseful()
        }
        #endif

        if activeProject == nil {
            activeProjectID = projects.first?.id
        }
        if activeAgent == nil {
            activeAgentID = resolvedLastAgentID(for: activeProject)
        }
        synchronizeProjectResources()
        synchronizeActiveProjectPanels()

        isBootstrapped = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            async let codexRegistration: Void = runtimeDiscovery.register(.codex)
            async let claudeRegistration: Void = runtimeDiscovery.register(.claude)
            _ = await (codexRegistration, claudeRegistration)
            runtimeHealth = await runtimeDiscovery.allHealth()

            // Provider-native repair can begin as soon as executable paths are
            // known; model/version probes continue independently.
            scheduleNativeThreadSynchronization(
                prioritizing: activeProjectID,
                includeAllProjects: true,
                discoveryMode: .repair
            )
            startActiveProjectNativePolling()
            await refreshProviderModelsUsingDiscoveredRuntimes()
            await runtimeDiscovery.waitForVersionChecks()
            runtimeHealth = await runtimeDiscovery.allHealth()
        }

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
        guard url.isFileURL else { return }
        var isDirectory: ObjCBool = false
        let standardizedPath = Project.normalizedRootPath(url.path)
        guard FileManager.default.fileExists(atPath: standardizedPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return
        }
        let canonicalPath = URL(fileURLWithPath: standardizedPath, isDirectory: true)
            .resolvingSymlinksInPath().path

        if let existing = projects.first(where: { $0.project.canonicalRootPath == canonicalPath }) {
            activateProject(existing.id)
            return
        }

        let name = url.lastPathComponent.isEmpty ? "Project" : url.lastPathComponent
        let project = Project(name: name, rootPath: standardizedPath)
        let state = ProjectState(project: project, agents: [])
        projects.append(state)
        hydrate(state)
        refreshNativeThreads(for: state)
        scheduleSave()
    }

    func removeProject(_ projectID: UUID) {
        guard let removedProject = projects.first(where: { $0.id == projectID }) else { return }

        browserSessionCache.remove(removedProject.agents.map(\.id))
        for agent in removedProject.agents {
            cancelSteeringSubmission(for: agent.id)
            nativeTranscriptTasks[agent.id]?.cancel()
            nativeTranscriptTasks[agent.id] = nil
            nativeTranscriptLoadIDs[agent.id] = nil
            conversationService.cancelStreaming(for: agent.id)
            conversationService.clearPendingRequests(for: agent.id)
            releaseProviderSession(for: agent)
            for session in agent.terminalSessions {
                session.shutdown()
            }
        }
        gitStatusService.removeProject(projectID: projectID)
        ConversationPersistence.remove(projectID: projectID)
        prunedNativePresentations[projectID] = nil
        projects.removeAll { $0.id == projectID }

        if activeProjectID == projectID {
            if let nextProject = projects.first {
                activateProject(nextProject.id)
            } else {
                activeProjectID = nil
                activeAgentID = nil
                synchronizeProjectResources()
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

    @discardableResult
    private func addFreshDraft(to project: ProjectState, copying source: AgentInfo) -> AgentInfo {
        var configuration = source.agent.configuration
        configuration.providerID = source.providerID
        let draft = Agent(title: "New Thread", configuration: configuration)
        let info = AgentInfo(agent: draft, projectRootPath: project.project.rootPath)
        configureAgent(info)
        reconcileConfiguration(for: info)
        project.agents.append(info)
        project.project.agentOrder = project.agents.map(\.id)
        project.project.updatedAt = Date()
        activateAgent(info.id, in: project.id)
        scheduleSave()
        return info
    }

    func threadLifecycleActions(for agent: AgentInfo) -> [ThreadLifecycleActionKind] {
        // A provider session id alone does not make a FlowX draft a native
        // provider task. Stale or interrupted drafts can retain ids that have
        // no provider rollout behind them. Only provider-discovered bindings
        // may expose provider lifecycle operations.
        guard agent.nativeThreadBinding != nil else { return [.deleteDraft] }
        guard let provider = providerRegistry.provider(for: agent.providerID) else { return [] }
        var actions: [ThreadLifecycleActionKind] = []
        if provider is any AIProviderNativeThreadArchiving {
            actions.append(.archiveProviderTask)
        }
        if provider is any AIProviderNativeThreadDeleting {
            actions.append(.deleteProviderTask)
        }
        if provider is any AIProviderNativeThreadTrashManaging {
            actions.append(.moveProviderTaskToTrash)
        }
        return actions
    }

    func threadLifecycleBlockedReason(for agent: AgentInfo, in project: ProjectState) -> String? {
        if agent.isStreaming {
            return "Stop the current FlowX run before managing this task."
        }
        if agent.nativeThreadBinding?.status?.lowercased() == "active" {
            return "This task is currently running in Codex. Stop it before managing it."
        }
        if project.isSyncingNativeThreads {
            return "Wait for provider task refresh to finish, then try again."
        }
        if threadLifecycleAgentIDs.contains(agent.id) {
            return "A task action is already in progress."
        }
        return nil
    }

    func isThreadLifecycleActionInProgress(for agentID: UUID) -> Bool {
        threadLifecycleAgentIDs.contains(agentID)
    }

    func isArchivedThreadActionInProgress(_ identity: NativeThreadIdentity) -> Bool {
        archivedThreadLifecycleIdentities.contains(identity)
    }

    func requestThreadLifecycleAction(
        _ action: ThreadLifecycleActionKind,
        for agent: AgentInfo
    ) {
        guard let project = project(for: agent.id),
              threadLifecycleActions(for: agent).contains(action) else {
            reportThreadLifecycleError(
                "This provider does not expose a safe archive or recoverable delete action.",
                for: agent
            )
            return
        }
        if let blockedReason = threadLifecycleBlockedReason(for: agent, in: project) {
            reportThreadLifecycleError(blockedReason, for: agent)
            return
        }

        if action == .deleteDraft, !hasMeaningfulDraftContent(agent) {
            removeAgent(agent.id)
            project.threadLifecycleNotice = nil
            project.threadLifecycleNoticeIsError = false
            return
        }

        threadLifecycleConfirmation = ThreadLifecycleConfirmation(
            action: action,
            agentID: agent.id,
            projectID: project.id,
            providerIdentity: action.isProviderAction ? agent.nativeThreadBinding?.identity : nil,
            threadTitle: agent.nativeThreadBinding?.title ?? agent.title
        )
    }

    func requestArchivedThreadDeletion(
        _ binding: NativeThreadBinding,
        in project: ProjectState
    ) {
        let identity = binding.identity
        guard projects.contains(where: { $0.id == project.id }),
              project.archivedNativeThreadBindings.contains(where: { $0.identity == identity }),
              providerRegistry.provider(for: identity.providerID) is any AIProviderNativeThreadDeleting else {
            project.threadLifecycleNotice = "Permanent delete is unavailable for this archived task."
            project.threadLifecycleNoticeIsError = true
            return
        }
        guard !project.isSyncingNativeThreads else {
            project.threadLifecycleNotice = "Wait for provider task refresh to finish, then try again."
            project.threadLifecycleNoticeIsError = true
            return
        }
        guard !archivedThreadLifecycleIdentities.contains(identity) else { return }

        threadLifecycleConfirmation = ThreadLifecycleConfirmation(
            action: .deleteProviderTask,
            agentID: nil,
            projectID: project.id,
            providerIdentity: identity,
            threadTitle: binding.title
        )
    }

    func cancelThreadLifecycleConfirmation() {
        threadLifecycleConfirmation = nil
    }

    func confirmThreadLifecycleAction() {
        guard let confirmation = threadLifecycleConfirmation else { return }
        threadLifecycleConfirmation = nil
        Task { @MainActor [weak self] in
            await self?.performThreadLifecycleAction(confirmation)
        }
    }

    func unarchiveNativeThread(_ binding: NativeThreadBinding, in project: ProjectState) {
        let identity = binding.identity
        let projectID = project.id
        guard projects.contains(where: { $0.id == project.id }) else { return }
        guard !project.isSyncingNativeThreads else {
            project.threadLifecycleNotice = "Wait for provider task refresh to finish, then restore the task."
            project.threadLifecycleNoticeIsError = true
            return
        }
        guard !archivedThreadLifecycleIdentities.contains(identity),
              let provider = providerRegistry.provider(for: identity.providerID)
                as? any AIProviderNativeThreadArchiving else {
            return
        }

        archivedThreadLifecycleIdentities.insert(identity)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.archivedThreadLifecycleIdentities.remove(identity) }
            guard let project = self.projects.first(where: { $0.id == projectID }) else { return }
            do {
                try await provider.unarchiveNativeThread(
                    id: identity.sessionID,
                    workingDirectory: project.project.rootURL
                )
                guard self.projects.contains(where: { $0.id == project.id }) else { return }
                project.archivedNativeThreadBindings.removeAll { $0.identity == identity }
                project.threadLifecycleNotice = nil
                project.threadLifecycleNoticeIsError = false
                self.refreshNativeThreads(for: project, discoveryMode: .indexed)
            } catch {
                project.threadLifecycleNotice = "Could not restore “\(binding.title)”: \(error.localizedDescription)"
                project.threadLifecycleNoticeIsError = true
            }
        }
    }

    private func performThreadLifecycleAction(_ confirmation: ThreadLifecycleConfirmation) async {
        guard let project = projects.first(where: { $0.id == confirmation.projectID }) else {
            return
        }
        guard !project.isSyncingNativeThreads else {
            project.threadLifecycleNotice = "The task list changed while confirmation was open. Refresh completed actions and try again."
            project.threadLifecycleNoticeIsError = true
            return
        }

        if confirmation.action == .deleteProviderTask, confirmation.agentID == nil {
            await performArchivedThreadDeletion(confirmation, in: project)
            return
        }

        guard let agentID = confirmation.agentID,
              let agent = project.agents.first(where: { $0.id == agentID }) else {
            project.threadLifecycleNotice = "The task changed while confirmation was open. No action was performed."
            project.threadLifecycleNoticeIsError = true
            return
        }
        if let blockedReason = threadLifecycleBlockedReason(for: agent, in: project) {
            reportThreadLifecycleError(blockedReason, for: agent)
            return
        }
        guard threadLifecycleActions(for: agent).contains(confirmation.action) else {
            reportThreadLifecycleError("The task changed while confirmation was open. No action was performed.", for: agent)
            return
        }
        if confirmation.action.isProviderAction,
           agent.nativeThreadBinding?.identity != confirmation.providerIdentity {
            reportThreadLifecycleError("The provider task changed while confirmation was open. No action was performed.", for: agent)
            return
        }

        threadLifecycleAgentIDs.insert(agent.id)
        defer { threadLifecycleAgentIDs.remove(agent.id) }

        switch confirmation.action {
        case .deleteDraft:
            removeAgent(agent.id)
            project.threadLifecycleNotice = nil
            project.threadLifecycleNoticeIsError = false

        case .archiveProviderTask:
            guard let identity = confirmation.providerIdentity,
                  let provider = providerRegistry.provider(for: identity.providerID)
                    as? any AIProviderNativeThreadArchiving else {
                reportThreadLifecycleError("Codex archive is unavailable for this task.", for: agent)
                return
            }
            do {
                try await provider.archiveNativeThread(
                    id: identity.sessionID,
                    workingDirectory: project.project.rootURL
                )
                guard projects.contains(where: { $0.id == project.id }),
                      project.agents.contains(where: { $0.id == agent.id }) else {
                    return
                }
                if let binding = agent.nativeThreadBinding {
                    project.archivedNativeThreadBindings.removeAll { $0.identity == identity }
                    project.archivedNativeThreadBindings.append(binding)
                    sortArchivedNativeBindings(for: project)
                }
                removeProviderPresentation(
                    agent,
                    from: project,
                    preservePresentationIdentity: true
                )
                project.threadLifecycleNotice = nil
                project.threadLifecycleNoticeIsError = false
                refreshNativeThreads(for: project, discoveryMode: .indexed)
            } catch {
                reportThreadLifecycleError(
                    "Could not archive “\(confirmation.threadTitle)”: \(error.localizedDescription)",
                    for: agent
                )
            }

        case .deleteProviderTask:
            guard let identity = confirmation.providerIdentity,
                  let provider = providerRegistry.provider(for: identity.providerID)
                    as? any AIProviderNativeThreadDeleting else {
                reportThreadLifecycleError("Permanent Codex deletion is unavailable for this task.", for: agent)
                return
            }
            do {
                try await provider.deleteNativeThread(
                    id: identity.sessionID,
                    workingDirectory: project.project.rootURL
                )
                guard projects.contains(where: { $0.id == project.id }),
                      project.agents.contains(where: { $0.id == agent.id }) else {
                    return
                }
                removeProviderPresentation(
                    agent,
                    from: project,
                    preservePresentationIdentity: false
                )
                project.threadLifecycleNotice = nil
                project.threadLifecycleNoticeIsError = false
                refreshNativeThreads(for: project, discoveryMode: .indexed)
            } catch {
                reportThreadLifecycleError(
                    "Could not permanently delete “\(confirmation.threadTitle)”: \(error.localizedDescription)",
                    for: agent
                )
            }

        case .moveProviderTaskToTrash:
            guard let identity = confirmation.providerIdentity,
                  let provider = providerRegistry.provider(for: identity.providerID)
                    as? any AIProviderNativeThreadTrashManaging else {
                reportThreadLifecycleError("Recoverable deletion is unavailable for this task.", for: agent)
                return
            }
            do {
                try await provider.moveNativeThreadToTrash(
                    id: identity.sessionID,
                    workingDirectory: project.project.rootURL
                )
                guard projects.contains(where: { $0.id == project.id }),
                      project.agents.contains(where: { $0.id == agent.id }) else {
                    return
                }
                removeProviderPresentation(
                    agent,
                    from: project,
                    preservePresentationIdentity: false
                )
                project.threadLifecycleNotice = nil
                project.threadLifecycleNoticeIsError = false
                refreshNativeThreads(for: project, discoveryMode: .indexed)
            } catch {
                reportThreadLifecycleError(
                    "Could not move “\(confirmation.threadTitle)” to Trash: \(error.localizedDescription)",
                    for: agent
                )
            }
        }
    }

    private func performArchivedThreadDeletion(
        _ confirmation: ThreadLifecycleConfirmation,
        in project: ProjectState
    ) async {
        guard let identity = confirmation.providerIdentity,
              project.archivedNativeThreadBindings.contains(where: { $0.identity == identity }),
              !archivedThreadLifecycleIdentities.contains(identity),
              let provider = providerRegistry.provider(for: identity.providerID)
                as? any AIProviderNativeThreadDeleting else {
            project.threadLifecycleNotice = "The archived task changed while confirmation was open. No action was performed."
            project.threadLifecycleNoticeIsError = true
            return
        }

        archivedThreadLifecycleIdentities.insert(identity)
        defer { archivedThreadLifecycleIdentities.remove(identity) }
        do {
            try await provider.deleteNativeThread(
                id: identity.sessionID,
                workingDirectory: project.project.rootURL
            )
            guard projects.contains(where: { $0.id == project.id }) else { return }
            project.archivedNativeThreadBindings.removeAll { $0.identity == identity }
            discardNativePresentation(identity, from: project)
            project.threadLifecycleNotice = nil
            project.threadLifecycleNoticeIsError = false
            refreshNativeThreads(for: project, discoveryMode: .indexed)
        } catch {
            project.threadLifecycleNotice = "Could not permanently delete “\(confirmation.threadTitle)”: \(error.localizedDescription)"
            project.threadLifecycleNoticeIsError = true
        }
    }

    private func removeProviderPresentation(
        _ agent: AgentInfo,
        from project: ProjectState,
        preservePresentationIdentity: Bool
    ) {
        let identity = agent.nativeThreadBinding?.identity
        let agentID = agent.id
        removeAgent(agentID)

        if let identity {
            if preservePresentationIdentity {
                // Archive hides the provider task but preserves its stable
                // presentation identity and conversation/image sidecar cache.
                project.nativePresentationAgentIDs[identity] = agentID
            } else {
                ConversationPersistence.remove(agentID: agentID, projectID: project.id)
                var cache = prunedNativePresentations[project.id] ?? [:]
                cache[identity] = nil
                prunedNativePresentations[project.id] = cache.isEmpty ? nil : cache
                project.nativePresentationAgentIDs[identity] = nil
            }
        } else if !preservePresentationIdentity {
            ConversationPersistence.remove(agentID: agentID, projectID: project.id)
        }
        scheduleSave()
    }

    private func discardNativePresentation(
        _ identity: NativeThreadIdentity,
        from project: ProjectState
    ) {
        let presentationID = project.nativePresentationAgentIDs.removeValue(forKey: identity)
            ?? Self.deterministicAgentID(for: identity)
        browserSessionCache.remove(presentationID)
        ConversationPersistence.remove(agentID: presentationID, projectID: project.id)
        var cache = prunedNativePresentations[project.id] ?? [:]
        cache[identity] = nil
        prunedNativePresentations[project.id] = cache.isEmpty ? nil : cache
        scheduleSave()
    }

    private func hasMeaningfulDraftContent(_ agent: AgentInfo) -> Bool {
        !agent.messages.isEmpty
            || !agent.conversationState.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !agent.conversationState.pendingAttachments.isEmpty
            || agent.conversationState.queuedPromptCount > 0
            || agent.conversationState.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || agent.terminalSessions.contains(where: { $0.isRunning })
            || agent.workspace.terminalVisible
            || agent.workspace.splitOpen
            || !agent.workspace.browserURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func reportThreadLifecycleError(_ message: String, for agent: AgentInfo) {
        agent.conversationState.recordRuntimeActivity(
            kind: .error,
            tone: .error,
            summary: "Task action failed",
            detail: message,
            state: "failed",
            turnID: agent.conversationState.activeTurnID
        )
        project(for: agent.id)?.threadLifecycleNotice = message
        project(for: agent.id)?.threadLifecycleNoticeIsError = true
    }

    private func sortArchivedNativeBindings(for project: ProjectState) {
        project.archivedNativeThreadBindings.sort {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return Self.nativeIdentitySortKey($0.identity) < Self.nativeIdentitySortKey($1.identity)
        }
    }

    func removeAgent(_ agentID: UUID) {
        guard let project = project(for: agentID),
              let agentIndex = project.agents.firstIndex(where: { $0.id == agentID }) else {
            return
        }

        cancelSteeringSubmission(for: agentID)
        conversationService.cancelStreaming(for: agentID)
        conversationService.clearPendingRequests(for: agentID)
        nativeTranscriptTasks[agentID]?.cancel()
        nativeTranscriptTasks[agentID] = nil
        nativeTranscriptLoadIDs[agentID] = nil
        releaseProviderSession(for: project.agents[agentIndex])
        browserSessionCache.remove(agentID)

        let removedAgent = project.agents.remove(at: agentIndex)
        if removedAgent.nativeThreadBinding != nil {
            cachePrunedNativePresentation(removedAgent, projectID: project.id)
            trimNativePresentationAgentIDs(for: project)
        }
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

        if removedAgent.nativeThreadBinding == nil {
            ConversationPersistence.remove(agentID: agentID, projectID: project.id)
        }
        synchronizeActiveProjectPanels()
        scheduleSave()
    }

    func attachFiles(to agent: AgentInfo) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        let supportedKinds = supportedAttachmentKinds(for: agent)
        guard !supportedKinds.isEmpty else {
            agent.conversationState.error = "Attachments are not supported by this provider."
            return
        }
        var supportedTypeIdentifiers: Set<String> = []
        if supportedKinds.contains(.image) {
            supportedTypeIdentifiers.formUnion(Attachment.supportedImageTypes)
        }
        if supportedKinds.contains(.pdf) {
            supportedTypeIdentifiers.insert("com.adobe.pdf")
        }
        panel.allowedContentTypes = supportedTypeIdentifiers.compactMap(UTType.init)
        panel.prompt = "Attach"

        guard panel.runModal() == .OK else { return }

        Task { [weak self, weak agent] in
            guard let self, let agent else { return }
            if let error = await attachFiles(at: panel.urls, to: agent) {
                agent.conversationState.error = error
            }
        }
    }

    func attachFiles(at urls: [URL], to agent: AgentInfo) async -> String? {
        guard !urls.isEmpty else { return nil }

        let supportedKinds = supportedAttachmentKinds(for: agent)
        let existingBytes = agent.conversationState.pendingAttachments.reduce(into: 0) { partial, attachment in
            partial += attachment.data.count
        }
        let existingCount = agent.conversationState.pendingAttachments.count

        let result = await Task.detached(priority: .userInitiated) {
            Self.loadAttachments(
                from: urls,
                existingBytes: existingBytes,
                existingCount: existingCount,
                supportedKinds: supportedKinds
            )
        }.value
        guard project(for: agent.id) != nil else { return nil }
        return applyLoadedAttachments(result, to: agent)
    }

    func attachImageData(_ data: Data, mimeType: String, filename: String, to agent: AgentInfo) async -> String? {
        let supportedKinds = supportedAttachmentKinds(for: agent)
        guard supportedKinds.contains(.image), mimeType.hasPrefix("image/") else {
            return "Images are not supported by this provider."
        }
        guard !data.isEmpty else {
            return "The pasted image is empty."
        }
        guard data.count <= Self.maximumAttachmentBytes else {
            return "The pasted image exceeds the 20 MB per-file limit."
        }

        return applyLoadedAttachments(
            AttachmentLoadResult(
                attachments: [Attachment(data: data, mimeType: mimeType, filename: filename)],
                errors: []
            ),
            to: agent
        )
    }

    private func supportedAttachmentKinds(for agent: AgentInfo) -> Set<ProviderAttachmentKind> {
        providerRegistry.provider(for: agent.providerID)?.capabilities.supportedAttachments ?? []
    }

    private func applyLoadedAttachments(_ result: AttachmentLoadResult, to agent: AgentInfo) -> String? {
        var totalBytes = agent.conversationState.pendingAttachments.reduce(into: 0) { partial, attachment in
            partial += attachment.data.count
        }
        var errors = result.errors
        for attachment in result.attachments {
            guard agent.conversationState.pendingAttachments.count < Self.maximumPendingAttachmentCount,
                  totalBytes + attachment.data.count <= Self.maximumPendingAttachmentBytes else {
                errors.append("The pending attachment limit was reached.")
                break
            }
            agent.conversationState.addAttachment(attachment)
            totalBytes += attachment.data.count
        }

        return errors.isEmpty ? nil : Self.attachmentErrorSummary(errors)
    }

    func sendPrompt(
        for agent: AgentInfo,
        followUpMode: PromptFollowUpMode? = nil
    ) {
        guard !isSubmittingSteer(for: agent.id) else { return }
        let prompt = agent.conversationState.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = agent.conversationState.pendingAttachments
        guard !prompt.isEmpty || !attachments.isEmpty else { return }

        if FlowXSlashCommand(prompt) != nil, !attachments.isEmpty {
            agent.conversationState.error = "Attachments cannot be used with slash commands. Remove them or send them with a regular prompt."
            return
        }

        if FlowXSlashCommand(prompt) != nil,
           providerRegistry.provider(for: agent.providerID)?.capabilities.supportsThreadControls != true {
            agent.conversationState.error = "Thread-control slash commands are not supported by this provider."
            return
        }

        if let slashCommand = FlowXSlashCommand(prompt) {
            // Keep the composer draft and image bytes intact when the provider
            // is still starting, unavailable, or bound to another workspace.
            guard preflightPromptDispatch(for: agent) != nil else { return }
            agent.conversationState.inputText = ""
            agent.conversationState.clearAttachments()
            handleSlashCommand(slashCommand, attachments: attachments, for: agent)
            return
        }

        let resolvedFollowUpMode = followUpMode ?? preferences.defaultFollowUpMode
        if agent.isStreaming, resolvedFollowUpMode == .steer {
            submitSteeringPrompt(
                prompt,
                draftText: agent.conversationState.inputText,
                attachments: attachments,
                for: agent
            )
            return
        }

        // ConversationService can reject a queued prompt at its bounded queue
        // or attachment limits. Clear the composer only after it accepts the
        // request so typed text and image bytes are never silently lost.
        if dispatchPrompt(prompt, attachments: attachments, for: agent) {
            agent.conversationState.inputText = ""
            agent.conversationState.clearAttachments()
        }
    }

    func activateProject(_ projectID: UUID) {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }
        let projectChanged = activeProjectID != projectID
        activeProjectID = projectID
        activeAgentID = resolvedLastAgentID(for: project)
        if let activeAgentID,
           let selectedAgent = project.agents.first(where: { $0.id == activeAgentID }) {
            selectedAgent.hasUnseenCompletion = false
        }
        cancelNativeTranscriptLoads(except: activeAgentID)
        if projectChanged {
            synchronizeProjectResources()
            scheduleNativeThreadSynchronization(prioritizing: project.id, includeAllProjects: false)
        }
        if let agent = activeAgent {
            loadNativeTranscriptIfNeeded(for: agent, in: project)
        }
        synchronizeActiveProjectPanels()
        persistStateIfBootstrapped()
    }

    func activateAgent(_ agentID: UUID, in projectID: UUID) {
        guard let project = projects.first(where: { $0.id == projectID }),
              project.agents.contains(where: { $0.id == agentID }) else {
            return
        }

        let projectChanged = activeProjectID != projectID
        activeProjectID = projectID
        activeAgentID = agentID
        if let selectedAgent = project.agents.first(where: { $0.id == agentID }) {
            selectedAgent.hasUnseenCompletion = false
        }
        cancelNativeTranscriptLoads(except: agentID)
        if project.lastSelectedAgentID != agentID {
            project.lastSelectedAgentID = agentID
        }
        if projectChanged {
            synchronizeProjectResources()
            scheduleNativeThreadSynchronization(prioritizing: project.id, includeAllProjects: false)
        }
        if let agent = project.agents.first(where: { $0.id == agentID }) {
            loadNativeTranscriptIfNeeded(for: agent, in: project)
        }
        synchronizeActiveProjectPanels()
        persistStateIfBootstrapped()
    }

    func cancelPrompt(for agent: AgentInfo) {
        conversationService.cancelStreaming(for: agent.id)
        agent.syncExecutionStateFromConversation()
        if let project = project(for: agent.id) {
            ConversationPersistence.save(agent: agent, projectID: project.id)
        }
        scheduleSave()
    }

    func resetConversation(for agent: AgentInfo) {
        cancelSteeringSubmission(for: agent.id)
        conversationService.cancelStreaming(for: agent.id)
        conversationService.clearPendingRequests(for: agent.id)
        releaseProviderSession(for: agent)
        if let project = project(for: agent.id), agent.nativeThreadBinding != nil {
            _ = addFreshDraft(to: project, copying: agent)
            return
        }
        agent.conversationState.resetConversation()
        agent.syncExecutionStateFromConversation()
        if let project = project(for: agent.id) {
            ConversationPersistence.save(agent: agent, projectID: project.id)
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
        cancelSteeringSubmission(for: agent.id)
        conversationService.cancelStreaming(for: agent.id)
        releaseProviderSession(for: agent)

        let latestPrompt = agent.conversationState.latestUserPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let project = project(for: agent.id), agent.nativeThreadBinding != nil {
            let draft = addFreshDraft(to: project, copying: agent)
            if let latestPrompt, !latestPrompt.isEmpty {
                dispatchPrompt(latestPrompt, for: draft)
            }
            return
        }

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

    func respondToUserInput(
        _ requestID: UUID,
        answers: ProviderUserInputAnswers,
        for agent: AgentInfo
    ) {
        guard let request = agent.conversationState.removeUserInputRequest(requestID) else { return }
        agent.conversationState.recordRuntimeActivity(
            kind: .note,
            tone: .info,
            summary: "Input submitted",
            detail: request.questions.map(\.header).joined(separator: ", "),
            state: "answered",
            turnID: agent.conversationState.activeTurnID
        )
        persistConversation(for: agent)

        Task { @MainActor in
            await conversationService.respondToUserInput(
                requestID,
                answers: answers,
                for: agent.id
            )
        }
    }

    func cancelUserInput(_ requestID: UUID, for agent: AgentInfo) {
        guard let request = agent.conversationState.removeUserInputRequest(requestID) else { return }
        agent.conversationState.recordRuntimeActivity(
            kind: .note,
            tone: .warning,
            summary: "Input cancelled",
            detail: request.title,
            state: "cancelled",
            turnID: agent.conversationState.activeTurnID
        )
        persistConversation(for: agent)

        Task { @MainActor in
            await conversationService.cancelUserInput(requestID, for: agent.id)
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

    /// Refreshes the provider-owned thread index for one project. FlowX only
    /// stores the resulting presentation binding and workspace layout; the
    /// provider remains the transcript authority.
    func refreshNativeThreads(
        for project: ProjectState,
        discoveryMode: ProviderNativeThreadDiscoveryMode = .repair
    ) {
        guard projects.contains(where: { $0.id == project.id }) else {
            return
        }
        scheduleNativeThreadSynchronization(
            prioritizing: project.id,
            includeAllProjects: false,
            forceTranscriptRefresh: true,
            discoveryMode: discoveryMode
        )
    }

    private func startActiveProjectNativePolling() {
        nativeActiveProjectPollingTask?.cancel()
        nativeActiveProjectPollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
                guard !Task.isCancelled, NSApplication.shared.isActive else { continue }
                self?.refreshActiveNativeThreadsIfIdle()
            }
        }
    }

    private func refreshActiveNativeThreadsIfIdle() {
        guard isBootstrapped,
              NSApplication.shared.isActive,
              let project = activeProject else {
            return
        }
        scheduleNativeThreadSynchronization(
            prioritizing: project.id,
            includeAllProjects: false
        )
    }

    private func handleApplicationDidBecomeActive() {
        guard isBootstrapped else { return }
        if let project = activeProject {
            gitStatusService.forceRefresh(projectID: project.id)
            project.refreshFiles()
        }
        refreshActiveNativeThreadsIfIdle()
    }

    private func scheduleNativeThreadSynchronization(
        prioritizing projectID: UUID?,
        includeAllProjects: Bool,
        forceTranscriptRefresh: Bool = false,
        discoveryMode: ProviderNativeThreadDiscoveryMode = .indexed
    ) {
        var projectIDs: [UUID] = []
        if let projectID, projects.contains(where: { $0.id == projectID }) {
            projectIDs.append(projectID)
        }
        if includeAllProjects {
            projectIDs.append(contentsOf: projects.map(\.id).filter { !projectIDs.contains($0) })
        }
        guard !projectIDs.isEmpty else { return }

        var request = NativeWorkspaceSyncRequest(
            projectIDs: projectIDs,
            forceTranscriptRefresh: forceTranscriptRefresh,
            discoveryMode: discoveryMode
        )
        if let activeRequest = activeNativeWorkspaceSyncRequest {
            let upgradesActiveRequest = forceTranscriptRefresh && !activeRequest.forceTranscriptRefresh
                || discoveryMode == .repair && activeRequest.discoveryMode != .repair
            if !upgradesActiveRequest {
                request.projectIDs.removeAll { activeRequest.projectIDs.contains($0) }
            }
            guard !request.projectIDs.isEmpty else { return }

            if pendingNativeWorkspaceSyncRequest == nil {
                pendingNativeWorkspaceSyncRequest = request
            } else {
                pendingNativeWorkspaceSyncRequest?.merge(request)
            }
            return
        }

        beginNativeThreadSynchronization(request)
    }

    private func beginNativeThreadSynchronization(_ request: NativeWorkspaceSyncRequest) {
        activeNativeWorkspaceSyncRequest = request
        nativeWorkspaceSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for projectID in request.projectIDs {
                guard !Task.isCancelled else { break }
                await synchronizeNativeThreads(
                    projectID: projectID,
                    forceTranscriptRefresh: request.forceTranscriptRefresh,
                    discoveryMode: request.discoveryMode
                )
            }

            nativeWorkspaceSyncTask = nil
            activeNativeWorkspaceSyncRequest = nil
            guard !Task.isCancelled, !isShuttingDown,
                  let pendingRequest = pendingNativeWorkspaceSyncRequest else {
                return
            }
            pendingNativeWorkspaceSyncRequest = nil
            beginNativeThreadSynchronization(pendingRequest)
        }
    }

    private func synchronizeNativeThreads(
        projectID: UUID,
        forceTranscriptRefresh: Bool,
        discoveryMode: ProviderNativeThreadDiscoveryMode
    ) async {
        guard let project = projects.first(where: { $0.id == projectID }),
              !nativeSyncingProjectIDs.contains(projectID) else {
            return
        }
        nativeSyncingProjectIDs.insert(projectID)
        let projectRootURL = project.project.rootURL
        let expectedCanonicalPath = project.project.canonicalRootPath
        let providers = providerRegistry.allProviders
            .compactMap { $0 as? any AIProviderNativeThreads }
            .sorted { $0.displayName < $1.displayName }

        let previousAgentIDs = project.agents.map(\.id)
        let previousBindings = project.agents.compactMap(\.nativeThreadBinding)
        let previousConfigurations = Dictionary(
            uniqueKeysWithValues: project.agents.map { ($0.id, $0.agent.configuration) }
        )
        let previousArchivedBindings = project.archivedNativeThreadBindings
        let previousPresentationIDs = project.nativePresentationAgentIDs
        let previousSyncError = project.nativeThreadSyncError

        let presentsSyncActivity = forceTranscriptRefresh || discoveryMode == .repair
        if presentsSyncActivity {
            project.isSyncingNativeThreads = true
        }
        defer {
            nativeSyncingProjectIDs.remove(projectID)
            if presentsSyncActivity,
               let currentProject = projects.first(where: { $0.id == projectID }) {
                currentProject.isSyncingNativeThreads = false
            }
        }

        var bindingsByIdentity: [NativeThreadIdentity: NativeThreadBinding] = [:]
        var archivedBindingsByIdentity: [NativeThreadIdentity: NativeThreadBinding] = [:]
        var successfullyListedProviderIDs: Set<String> = []
        var successfullyListedArchivedProviderIDs: Set<String> = []
        var errors: [String] = []
        for provider in providers {
            guard !Task.isCancelled else { return }
            if runtimeHealth[provider.id]?.isUsable == false {
                continue
            }
            do {
                let listLimit = 250
                let summaries = try await provider.listNativeThreads(
                    workingDirectory: projectRootURL,
                    limit: listLimit,
                    discoveryMode: discoveryMode
                )
                guard !Task.isCancelled else { return }
                let providerID = AgentInfo.normalizedProviderID(provider.id)
                successfullyListedProviderIDs.insert(providerID)
                for summary in summaries {
                    guard let binding = Self.validatedNativeBinding(
                        summary,
                        expectedCanonicalPath: expectedCanonicalPath
                    ), binding.identity.providerID == providerID else {
                        continue
                    }
                    if let existing = bindingsByIdentity[binding.identity],
                       existing.updatedAt >= binding.updatedAt {
                        continue
                    }
                    bindingsByIdentity[binding.identity] = binding
                }
            } catch is CancellationError {
                return
            } catch {
                errors.append("\(provider.displayName): \(error.localizedDescription)")
            }

            if let archivingProvider = provider as? any AIProviderNativeThreadArchiving {
                do {
                    let summaries = try await archivingProvider.listArchivedNativeThreads(
                        workingDirectory: projectRootURL,
                        limit: 250
                    )
                    guard !Task.isCancelled else { return }
                    let providerID = AgentInfo.normalizedProviderID(provider.id)
                    successfullyListedArchivedProviderIDs.insert(providerID)
                    for summary in summaries {
                        guard let binding = Self.validatedNativeBinding(
                            summary,
                            expectedCanonicalPath: expectedCanonicalPath
                        ), binding.identity.providerID == providerID else {
                            continue
                        }
                        if let existing = archivedBindingsByIdentity[binding.identity],
                           existing.updatedAt >= binding.updatedAt {
                            continue
                        }
                        archivedBindingsByIdentity[binding.identity] = binding
                    }
                } catch is CancellationError {
                    return
                } catch {
                    errors.append("\(provider.displayName) archived tasks: \(error.localizedDescription)")
                }
            }
        }

        guard !Task.isCancelled,
              let currentProject = projects.first(where: { $0.id == projectID }) else {
            return
        }

        let orderedBindings = bindingsByIdentity.values.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return Self.nativeIdentitySortKey($0.identity) < Self.nativeIdentitySortKey($1.identity)
        }
        // Keep the last provider-authoritative archived projection across a
        // transient runtime/list failure. A successful empty list still
        // clears that provider's archived tasks as expected.
        for binding in currentProject.archivedNativeThreadBindings
            where !successfullyListedArchivedProviderIDs.contains(binding.identity.providerID) {
            if archivedBindingsByIdentity[binding.identity] == nil {
                archivedBindingsByIdentity[binding.identity] = binding
            }
        }
        let resolvedArchivedBindings = archivedBindingsByIdentity.values.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return Self.nativeIdentitySortKey($0.identity) < Self.nativeIdentitySortKey($1.identity)
        }
        if currentProject.archivedNativeThreadBindings != resolvedArchivedBindings {
            currentProject.archivedNativeThreadBindings = resolvedArchivedBindings
        }
        await mergeNativeBindings(
            orderedBindings,
            successfullyListedProviderIDs: successfullyListedProviderIDs,
            into: currentProject
        )
        let resolvedSyncError = errors.isEmpty ? nil : errors.joined(separator: "\n")
        if currentProject.nativeThreadSyncError != resolvedSyncError {
            currentProject.nativeThreadSyncError = resolvedSyncError
        }

        if activeProjectID == currentProject.id,
           let activeAgentID,
           let activeAgent = currentProject.agents.first(where: { $0.id == activeAgentID }) {
            loadNativeTranscriptIfNeeded(
                for: activeAgent,
                in: currentProject,
                force: forceTranscriptRefresh
            )
        }
        let projectionChanged = previousAgentIDs != currentProject.agents.map(\.id)
            || previousBindings != currentProject.agents.compactMap(\.nativeThreadBinding)
            || previousConfigurations != Dictionary(
                uniqueKeysWithValues: currentProject.agents.map { ($0.id, $0.agent.configuration) }
            )
            || previousArchivedBindings != currentProject.archivedNativeThreadBindings
            || previousPresentationIDs != currentProject.nativePresentationAgentIDs
            || previousSyncError != currentProject.nativeThreadSyncError
        if projectionChanged {
            scheduleSave()
        }
    }

    private func mergeNativeBindings(
        _ bindings: [NativeThreadBinding],
        successfullyListedProviderIDs: Set<String>,
        into project: ProjectState
    ) async {
        removeStaleNativeAgents(
            from: project,
            retaining: Set(bindings.map(\.identity)),
            successfullyListedProviderIDs: successfullyListedProviderIDs
        )

        var agentsByIdentity: [NativeThreadIdentity: AgentInfo] = [:]
        for agent in project.agents {
            if let identity = agent.nativeThreadBinding?.identity,
               agentsByIdentity[identity] == nil {
                agentsByIdentity[identity] = agent
            }
        }

        let cachedPresentations = prunedNativePresentations[project.id] ?? [:]
        let persistedAgentIDs = Set(bindings.compactMap { binding -> UUID? in
            guard agentsByIdentity[binding.identity] == nil,
                  cachedPresentations[binding.identity] == nil else {
                return nil
            }
            return project.nativePresentationAgentIDs[binding.identity]
                ?? Self.deterministicAgentID(for: binding.identity)
        })
        let persistedConversations = await ConversationPersistence.load(
            agentIDs: persistedAgentIDs,
            for: project.id
        )
        guard projects.contains(where: { $0.id == project.id }) else { return }

        for binding in bindings {
            let matchingAgent = agentsByIdentity[binding.identity]
                ?? project.agents.first(where: { agent in
                    agent.nativeThreadBinding == nil
                        && agent.providerID == binding.identity.providerID
                        && agent.conversationState.sessionID == binding.identity.sessionID
                })

            if let agent = matchingAgent {
                let previousNativeTitle = agent.nativeThreadBinding?.title
                if (previousNativeTitle == nil || agent.agent.title == previousNativeTitle),
                   agent.agent.title != binding.title {
                    agent.agent.title = binding.title
                }
                updateNativeThreadBinding(binding, for: agent)
                if agent.agent.configuration.providerID != binding.identity.providerID {
                    agent.agent.configuration.providerID = binding.identity.providerID
                }
                if agent.conversationState.sessionID != binding.identity.sessionID {
                    agent.conversationState.sessionID = binding.identity.sessionID
                }
                if project.nativePresentationAgentIDs[binding.identity] != agent.id {
                    project.nativePresentationAgentIDs[binding.identity] = agent.id
                }
                reconcileConfiguration(for: agent)
                agentsByIdentity[binding.identity] = agent
                continue
            }

            if let cachedAgent = takePrunedNativePresentation(
                identity: binding.identity,
                projectID: project.id
            ) {
                updateNativeThreadBinding(binding, for: cachedAgent)
                cachedAgent.agent.configuration.providerID = binding.identity.providerID
                cachedAgent.conversationState.sessionID = binding.identity.sessionID
                cachedAgent.terminalSessions.removeAll()
                configureAgent(cachedAgent)
                reconcileConfiguration(for: cachedAgent)
                project.agents.append(cachedAgent)
                project.nativePresentationAgentIDs[binding.identity] = cachedAgent.id
                agentsByIdentity[binding.identity] = cachedAgent
                continue
            }

            let nativeAgentID = project.nativePresentationAgentIDs[binding.identity]
                ?? Self.deterministicAgentID(for: binding.identity)
            let persistedConversation = persistedConversations[nativeAgentID].flatMap { conversation in
                conversation.sessionID == binding.identity.sessionID ? conversation : nil
            }
            let nativeAgent = Agent(
                id: nativeAgentID,
                title: binding.title,
                configuration: AgentConfiguration(
                    providerID: binding.identity.providerID,
                    modelID: nil,
                    effort: nil,
                    agentMode: nil,
                    agentAccess: nil
                )
            )
            let info = AgentInfo(
                agent: nativeAgent,
                projectRootPath: project.project.rootPath,
                conversationState: persistedConversation.map(ConversationPersistence.state),
                nativeThreadBinding: binding,
                nativeImageSidecar: persistedConversation?.nativeImageSidecar ?? []
            )
            configureAgent(info)
            reconcileConfiguration(for: info)
            project.agents.append(info)
            project.nativePresentationAgentIDs[binding.identity] = info.id
            agentsByIdentity[binding.identity] = info
        }

        // Keep draft rows in their existing slots while ordering every native
        // slot by provider recency. This makes the current task immediately
        // visible without reshuffling explicit local drafts.
        var nativeAgents = project.agents
            .filter { $0.nativeThreadBinding != nil }
            .sorted {
                let lhsDate = $0.nativeUpdatedAt ?? .distantPast
                let rhsDate = $1.nativeUpdatedAt ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                let lhsIdentity = $0.nativeThreadBinding.map { Self.nativeIdentitySortKey($0.identity) } ?? ""
                let rhsIdentity = $1.nativeThreadBinding.map { Self.nativeIdentitySortKey($0.identity) } ?? ""
                return lhsIdentity < rhsIdentity
            }
        let reorderedAgents = project.agents.map { agent in
            guard agent.nativeThreadBinding != nil else { return agent }
            return nativeAgents.removeFirst()
        }
        if reorderedAgents.map(\.id) != project.agents.map(\.id) {
            project.agents = reorderedAgents
        }

        let orderedAgentIDs = project.agents.map(\.id)
        if project.project.agentOrder != orderedAgentIDs {
            project.project.agentOrder = orderedAgentIDs
        }
        if project.lastSelectedAgentID == nil {
            project.lastSelectedAgentID = project.agents.first?.id
        }
        if activeProjectID == project.id,
           activeAgentID.flatMap({ selectedID in
               project.agents.contains(where: { $0.id == selectedID }) ? selectedID : nil
           }) == nil {
            activeAgentID = project.lastSelectedAgentID ?? project.agents.first?.id
        }
        trimNativePresentationAgentIDs(for: project)
    }

    private func updateNativeThreadBinding(_ binding: NativeThreadBinding, for agent: AgentInfo) {
        guard agent.nativeThreadBinding != binding else { return }
        let wasActive = agent.nativeThreadBinding?.status?.lowercased() == "active"
        let normalizedStatus = binding.status?.lowercased()
        let isActive = normalizedStatus == "active"

        agent.nativeThreadBinding = binding
        if isActive, !wasActive {
            agent.hasUnseenCompletion = false
            // A provider-native run started after any previously cancelled
            // FlowX turn. Do not let that stale stop reason suppress this
            // new run's eventual completion marker.
            agent.conversationState.lastStopReason = nil
        } else if wasActive,
                  normalizedStatus != "systemerror",
                  !completionWasCancelled(for: agent) {
            agent.hasUnseenCompletion = agent.hasUnseenCompletion
                || completionNeedsAttention(for: agent)
        }
    }

    private func completionNeedsAttention(for agent: AgentInfo) -> Bool {
        activeAgentID != agent.id || !NSApplication.shared.isActive
    }

    private func completionWasCancelled(for agent: AgentInfo) -> Bool {
        guard let stopReason = agent.conversationState.lastStopReason?.lowercased() else {
            return false
        }
        return stopReason.contains("cancel")
            || stopReason.contains("interrupt")
            || stopReason.contains("abort")
    }

    private func removeStaleNativeAgents(
        from project: ProjectState,
        retaining currentIdentities: Set<NativeThreadIdentity>,
        successfullyListedProviderIDs: Set<String>
    ) {
        let visibleIdentities = project.agents.compactMap { $0.nativeThreadBinding?.identity }
        let streamingIdentities: Set<NativeThreadIdentity> = Set(project.agents.compactMap { agent -> NativeThreadIdentity? in
            guard agent.conversationState.isStreaming else { return nil }
            return agent.nativeThreadBinding?.identity
        })
        var protectedIdentities = streamingIdentities
        if let selectedAgentID = project.lastSelectedAgentID,
           let selectedIdentity = project.agents.first(where: { $0.id == selectedAgentID })?
            .nativeThreadBinding?.identity {
            protectedIdentities.insert(selectedIdentity)
        }
        let identitiesToRemove = NativeProjectionPolicy.identitiesToRemove(
            visibleIdentities: visibleIdentities,
            returnedIdentities: currentIdentities,
            successfullyListedProviders: successfullyListedProviderIDs,
            protectedIdentities: protectedIdentities,
            providerID: \.providerID
        )
        let staleAgents: [AgentInfo] = project.agents.filter { agent in
            guard let identity = agent.nativeThreadBinding?.identity else { return false }
            return identitiesToRemove.contains(identity)
        }
        guard !staleAgents.isEmpty else { return }

        let staleIDs: Set<UUID> = Set(staleAgents.map(\.id))
        for agent in staleAgents {
            nativeTranscriptTasks[agent.id]?.cancel()
            nativeTranscriptTasks[agent.id] = nil
            nativeTranscriptLoadIDs[agent.id] = nil
            conversationService.cancelStreaming(for: agent.id)
            conversationService.clearPendingRequests(for: agent.id)
            releaseProviderSession(for: agent)
            for terminal in agent.terminalSessions {
                terminal.shutdown()
            }
            cachePrunedNativePresentation(agent, projectID: project.id)
        }
        project.agents.removeAll { staleIDs.contains($0.id) }
        if project.lastSelectedAgentID.map(staleIDs.contains) == true {
            project.lastSelectedAgentID = project.agents.first?.id
        }
        if activeProjectID == project.id,
           activeAgentID.map(staleIDs.contains) == true {
            activeAgentID = project.lastSelectedAgentID ?? project.agents.first?.id
        }
        trimNativePresentationAgentIDs(for: project)
    }

    private func cachePrunedNativePresentation(_ agent: AgentInfo, projectID: UUID) {
        guard let identity = agent.nativeThreadBinding?.identity else { return }
        agent.isLoadingNativeTranscript = false
        for terminal in agent.terminalSessions {
            terminal.shutdown()
        }
        agent.terminalSessions.removeAll()
        var cache = prunedNativePresentations[projectID] ?? [:]
        cache[identity] = agent
        if cache.count > Self.maximumPrunedNativePresentationsPerProject,
           let oldestIdentity = cache.min(by: {
               ($0.value.nativeUpdatedAt ?? .distantPast) < ($1.value.nativeUpdatedAt ?? .distantPast)
           })?.key {
            cache[oldestIdentity] = nil
        }
        prunedNativePresentations[projectID] = cache
    }

    private func takePrunedNativePresentation(
        identity: NativeThreadIdentity,
        projectID: UUID
    ) -> AgentInfo? {
        guard var cache = prunedNativePresentations[projectID] else { return nil }
        let agent = cache.removeValue(forKey: identity)
        prunedNativePresentations[projectID] = cache.isEmpty ? nil : cache
        return agent
    }

    private func trimNativePresentationAgentIDs(for project: ProjectState) {
        var boundedMappings: [NativeThreadIdentity: UUID] = [:]
        for agent in project.agents {
            if let identity = agent.nativeThreadBinding?.identity {
                boundedMappings[identity] = agent.id
            }
        }

        let activeIdentities = Set(boundedMappings.keys)
        let reserve = (prunedNativePresentations[project.id] ?? [:]).values
            .compactMap { agent -> (identity: NativeThreadIdentity, agent: AgentInfo)? in
                guard let identity = agent.nativeThreadBinding?.identity,
                      !activeIdentities.contains(identity) else {
                    return nil
                }
                return (identity, agent)
            }
            .sorted {
                let lhsDate = $0.agent.nativeUpdatedAt ?? .distantPast
                let rhsDate = $1.agent.nativeUpdatedAt ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return Self.nativeIdentitySortKey($0.identity) < Self.nativeIdentitySortKey($1.identity)
            }

        for entry in reserve.prefix(Self.maximumPrunedNativePresentationsPerProject) {
            boundedMappings[entry.identity] = entry.agent.id
        }
        for binding in project.archivedNativeThreadBindings {
            boundedMappings[binding.identity] = project.nativePresentationAgentIDs[binding.identity]
                ?? Self.deterministicAgentID(for: binding.identity)
        }
        if project.nativePresentationAgentIDs != boundedMappings {
            project.nativePresentationAgentIDs = boundedMappings
        }
    }

    private func loadNativeTranscriptIfNeeded(
        for agent: AgentInfo,
        in project: ProjectState,
        force: Bool = false
    ) {
        guard let binding = agent.nativeThreadBinding,
              !agent.conversationState.isStreaming,
              let provider = providerRegistry.provider(for: binding.identity.providerID)
                as? any AIProviderNativeThreads,
              Self.canonicalDirectoryPath(binding.workingDirectory) == project.project.canonicalRootPath else {
            return
        }
        if !force,
           let loadedAt = agent.nativeTranscriptLoadedAt,
           loadedAt >= binding.updatedAt {
            return
        }

        nativeTranscriptTasks[agent.id]?.cancel()
        agent.isLoadingNativeTranscript = true
        agent.nativeTranscriptError = nil
        let agentID = agent.id
        let projectID = project.id
        let loadID = UUID()
        nativeTranscriptLoadIDs[agentID] = loadID

        nativeTranscriptTasks[agentID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if nativeTranscriptLoadIDs[agentID] == loadID {
                    nativeTranscriptTasks[agentID] = nil
                    nativeTranscriptLoadIDs[agentID] = nil
                    projects.first(where: { $0.id == projectID })?
                        .agents.first(where: { $0.id == agentID })?
                        .isLoadingNativeTranscript = false
                }
            }
            do {
                let cachedConversation = await ConversationPersistence.load(
                    agentIDs: [agentID],
                    for: projectID
                )[agentID]
                guard !Task.isCancelled,
                      nativeTranscriptLoadIDs[agentID] == loadID,
                      let cachedProject = projects.first(where: { $0.id == projectID }),
                      let cachedAgent = cachedProject.agents.first(where: { $0.id == agentID }),
                      !cachedAgent.conversationState.isStreaming,
                      cachedAgent.nativeThreadBinding?.identity == binding.identity else {
                    return
                }
                if let cachedConversation,
                   cachedConversation.sessionID == binding.identity.sessionID {
                    if cachedAgent.conversationState.messages.isEmpty {
                        ConversationPersistence.hydrate(
                            cachedAgent.conversationState,
                            from: cachedConversation
                        )
                        cachedAgent.syncExecutionStateFromConversation()
                    }
                    cachedAgent.nativeImageSidecar = ConversationAssetStore.updatedNativeImageSidecar(
                        existing: cachedConversation.nativeImageSidecar + cachedAgent.nativeImageSidecar,
                        messages: cachedAgent.conversationState.messages,
                        sessionID: binding.identity.sessionID,
                        projectID: projectID,
                        agentID: agentID
                    )
                }

                let nativeThread = try await provider.readNativeThread(
                    id: binding.identity.sessionID,
                    workingDirectory: project.project.rootURL
                )
                guard !Task.isCancelled,
                      let currentProject = projects.first(where: { $0.id == projectID }),
                      let currentAgent = currentProject.agents.first(where: { $0.id == agentID }),
                      !currentAgent.conversationState.isStreaming,
                      let refreshedBinding = Self.validatedNativeBinding(
                        nativeThread.summary,
                        expectedCanonicalPath: currentProject.project.canonicalRootPath
                      ), refreshedBinding.identity == binding.identity else {
                    return
                }

                updateNativeThreadBinding(refreshedBinding, for: currentAgent)
                let restoredMessages = ConversationAssetStore.reattachingNativeImages(
                    to: nativeThread.messages,
                    from: currentAgent.conversationState.messages,
                    sidecar: currentAgent.nativeImageSidecar,
                    sessionID: refreshedBinding.identity.sessionID,
                    projectID: projectID,
                    agentID: agentID
                )
                currentAgent.conversationState.replaceMessages(restoredMessages)
                currentAgent.conversationState.sessionID = refreshedBinding.identity.sessionID
                currentAgent.conversationState.activeProviderID = refreshedBinding.identity.providerID
                currentAgent.conversationState.activeModelID = effectiveConfiguration(for: currentAgent).modelID
                currentAgent.nativeTranscriptLoadedAt = Date()
                currentAgent.nativeTranscriptError = nil
                currentAgent.isLoadingNativeTranscript = false
                currentAgent.syncExecutionStateFromConversation()
                ConversationPersistence.save(agent: currentAgent, projectID: projectID)
                scheduleSave()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      let currentProject = projects.first(where: { $0.id == projectID }),
                      let currentAgent = currentProject.agents.first(where: { $0.id == agentID }) else {
                    return
                }
                currentAgent.isLoadingNativeTranscript = false
                currentAgent.nativeTranscriptError = error.localizedDescription
            }
        }
    }

    private func cancelNativeTranscriptLoads(except retainedAgentID: UUID?) {
        for agentID in Array(nativeTranscriptTasks.keys) where agentID != retainedAgentID {
            nativeTranscriptTasks[agentID]?.cancel()
            nativeTranscriptTasks[agentID] = nil
            nativeTranscriptLoadIDs[agentID] = nil
            project(for: agentID)?.agents.first(where: { $0.id == agentID })?
                .isLoadingNativeTranscript = false
        }
    }

    nonisolated private static func validatedNativeBinding(
        _ summary: ProviderNativeThreadSummary,
        expectedCanonicalPath: String
    ) -> NativeThreadBinding? {
        let providerID = AgentInfo.normalizedProviderID(summary.providerID)
        let sessionID = summary.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionID.isEmpty,
              let canonicalPath = canonicalDirectoryPath(summary.workingDirectory),
              canonicalPath == expectedCanonicalPath else {
            return nil
        }

        let source = normalizedProviderSource(summary.source, fallback: providerID)
        let title = summary.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSummary = ProviderNativeThreadSummary(
            providerID: providerID,
            id: sessionID,
            title: title.isEmpty ? "\(providerID.capitalized) Thread" : title,
            preview: String(summary.preview.prefix(500)),
            workingDirectory: canonicalPath,
            createdAt: summary.createdAt,
            updatedAt: summary.updatedAt,
            model: summary.model?.trimmingCharacters(in: .whitespacesAndNewlines),
            effort: summary.effort?.trimmingCharacters(in: .whitespacesAndNewlines),
            agentMode: summary.agentMode,
            agentAccess: summary.agentAccess,
            status: summary.status,
            source: source
        )
        return NativeThreadBinding(summary: normalizedSummary)
    }

    nonisolated private static func canonicalDirectoryPath(_ rawPath: String) -> String? {
        let trimmedPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return nil }
        let expandedPath = (trimmedPath as NSString).expandingTildeInPath
        guard (expandedPath as NSString).isAbsolutePath else { return nil }
        return URL(fileURLWithPath: expandedPath, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    nonisolated private static func normalizedProviderSource(_ source: String, fallback: String) -> String {
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty else { return fallback }
        let expandedSource = (trimmedSource as NSString).expandingTildeInPath
        if (expandedSource as NSString).isAbsolutePath {
            return URL(fileURLWithPath: expandedSource)
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
        }
        return trimmedSource.lowercased()
    }

    nonisolated private static func nativeIdentitySortKey(_ identity: NativeThreadIdentity) -> String {
        "\(identity.providerID)\u{0}\(identity.providerSource)\u{0}\(identity.sessionID)"
    }

    nonisolated private static func stableNativeIdentityKey(_ identity: NativeThreadIdentity) -> String {
        "\(identity.providerID)\u{0}\(identity.sessionID)"
    }

    nonisolated private static func deterministicAgentID(for identity: NativeThreadIdentity) -> UUID {
        let digest = SHA256.hash(data: Data(stableNativeIdentityKey(identity).utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    func refreshRuntimeHealth() async {
        await runtimeDiscovery.refreshAll()
        runtimeHealth = await runtimeDiscovery.allHealth()
        await refreshProviderModelsUsingDiscoveredRuntimes()
    }

    private func refreshProviderModelsUsingDiscoveredRuntimes() async {
        runtimeHealth = await runtimeDiscovery.allHealth()
        let providers = providerRegistry.allProviders
        for provider in providers where runtimeHealth[provider.id]?.isUsable != false {
            _ = await provider.refreshAvailableModels()
            providerRegistry.register(provider)
        }
        preferences.normalizeProviderDefaults(using: providerRegistry)
        if isBootstrapped {
            for project in projects {
                for agent in project.agents {
                    reconcileConfiguration(for: agent)
                }
            }
            scheduleSave()
        }
    }

    func pushActiveProject() async {
        guard let project = activeProject else { return }
        project.gitActionMessage = nil
        project.isPerformingGitAction = true
        let success = await gitStatusService.push(projectID: project.id)
        project.isPerformingGitAction = false
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
        guard !isShuttingDown else { return }
        scheduledSaveTask?.cancel()
        scheduledSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            ProjectPersistence.save(self)
        }
    }

    private func hydrate(_ project: ProjectState) {
        configureProject(project)
        if !project.agents.isEmpty {
            for agent in project.agents {
                reconcileConfiguration(for: agent)
                configureAgent(agent)
                agent.setTerminalLaunchDirectory(project.project.rootPath)
                agent.syncExecutionStateFromConversation()
            }
        }
    }

    private func synchronizeProjectResources() {
        guard let project = activeProject else {
            gitStatusService.stopAll()
            return
        }

        gitStatusService.pollOnly(projectID: project.id, rootPath: project.project.rootPath)
        project.refreshFiles()
    }

    private func reconcileConfiguration(for agent: AgentInfo) {
        var providerID = AgentInfo.normalizedProviderID(
            agent.nativeThreadBinding?.identity.providerID ?? agent.agent.configuration.providerID
        )
        if providerRegistry.provider(for: providerID) == nil, agent.nativeThreadBinding == nil {
            providerID = preferredProviderID()
        }

        guard let provider = providerRegistry.provider(for: providerID) else {
            agent.agent.configuration.providerID = providerID
            agent.conversationState.activeProviderID = providerID
            agent.conversationState.activeModelID = effectiveConfiguration(for: agent).modelID
            return
        }
        let availableModels = provider.availableModels

        var configuration = agent.agent.configuration
        configuration.providerID = providerID
        if let explicitModelID = configuration.modelID {
            configuration.modelID = AgentInfo.normalizedModelID(explicitModelID, providerID: providerID)
        }
        if let explicitEffort = configuration.effort {
            configuration.effort = AgentInfo.normalizedEffort(explicitEffort)
        }

        let effectiveModelID = effectiveConfiguration(for: agent).modelID
        let model = effectiveModelID.flatMap { effectiveModelID in
            availableModels.first(where: { $0.id == effectiveModelID })
        }
        if let model {
            let requestedWindow = configuration.contextWindowSize ?? model.contextWindow
            if model.availableContextWindows.contains(requestedWindow) {
                configuration.contextWindowSize = requestedWindow
            } else {
                configuration.contextWindowSize = model.availableContextWindows
                    .filter { $0 <= requestedWindow }
                    .max() ?? model.contextWindow
            }
        }
        if agent.agent.configuration != configuration {
            agent.agent.configuration = configuration
        }
        if agent.conversationState.activeProviderID != providerID {
            agent.conversationState.activeProviderID = providerID
        }
        if agent.conversationState.activeModelID != effectiveModelID {
            agent.conversationState.activeModelID = effectiveModelID
        }
        if agent.conversationState.configuredContextWindow != configuration.contextWindowSize {
            agent.conversationState.configuredContextWindow = configuration.contextWindowSize
        }
    }

    private func applyGitInfo(_ gitInfo: GitStatusService.GitInfo, to projectID: UUID) {
        guard let project = projects.first(where: { $0.id == projectID }) else {
            return
        }

        guard project.gitInfo != gitInfo else { return }

        project.gitInfo = gitInfo
        if !gitInfo.hasChanges {
            project.commitComposerVisible = false
            project.commitMessageDraft = ""
            project.gitActionMessage = nil
        }

        for agent in project.agents
        where agent.workspace.splitContent == .diff && agent.workspace.splitOpen {
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

        let shouldShowPanel = settingsVisible || !rightPanelVisible || rightPanelTab != .changes
        settingsVisible = false
        rightPanelTab = .changes
        rightPanelVisible = shouldShowPanel
    }

    func toggleBrowserPreview() {
        guard let agent = activeAgent else { return }

        if agent.workspace.splitOpen && agent.workspace.splitContent == .browser {
            agent.workspace.splitOpen = false
        } else {
            agent.workspace.splitContent = .browser
            agent.workspace.splitOpen = true
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

    private func submitSteeringPrompt(
        _ prompt: String,
        draftText: String,
        attachments: [Attachment],
        for agent: AgentInfo
    ) {
        guard let project = preflightPromptDispatch(for: agent) else { return }

        let agentID = agent.id
        let projectID = project.id
        let attachmentIDs = attachments.map(\.id)
        let submissionID = UUID()
        steeringPromptSubmissionIDs[agentID] = submissionID

        let task = Task { @MainActor [weak self, weak agent] in
            guard let self else { return }
            guard let agent else {
                if self.steeringPromptSubmissionIDs[agentID] == submissionID {
                    self.steeringPromptTasks[agentID] = nil
                    self.steeringPromptSubmissionIDs[agentID] = nil
                }
                return
            }
            let accepted = await self.conversationService.steer(
                prompt: prompt,
                attachments: attachments,
                conversationState: agent.conversationState,
                onAccepted: {
                    ConversationPersistence.save(agent: agent, projectID: projectID)
                }
            )

            // Removal/reset can invalidate an in-flight submission. In that
            // case its owner already canceled and cleaned the UI state.
            guard self.steeringPromptSubmissionIDs[agentID] == submissionID else { return }
            self.steeringPromptTasks[agentID] = nil
            self.steeringPromptSubmissionIDs[agentID] = nil

            guard self.project(for: agentID)?.id == projectID else { return }
            if accepted {
                // The composer is disabled while awaiting provider acceptance,
                // but keep this identity check so programmatic changes can
                // never erase a newer draft or newly attached images.
                if agent.conversationState.inputText == draftText,
                   agent.conversationState.pendingAttachments.map(\.id) == attachmentIDs {
                    agent.conversationState.inputText = ""
                    agent.conversationState.clearAttachments()
                }
                agent.markConversationStarted()
                ConversationPersistence.save(agent: agent, projectID: projectID)
                self.scheduleSave()
            } else {
                self.persistConversation(for: agent)
            }
        }
        steeringPromptTasks[agentID] = task
    }

    @discardableResult
    private func dispatchPrompt(
        _ prompt: String,
        attachments: [Attachment] = [],
        for agent: AgentInfo,
        resumeSessionID: String? = nil
    ) -> Bool {
        guard let project = preflightPromptDispatch(for: agent) else { return false }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty || !attachments.isEmpty else { return false }

        agent.markConversationStarted()
        let configuration = effectiveConfiguration(for: agent)

        let accepted = conversationService.send(
            prompt: trimmedPrompt,
            attachments: attachments,
            to: agent.conversationState,
            providerID: agent.providerID,
            model: configuration.modelID,
            effort: configuration.effort,
            systemPrompt: agent.systemPrompt,
            agentMode: configuration.agentMode,
            agentAccess: configuration.agentAccess,
            workingDirectory: project.project.rootURL,
            resumeSessionID: resumeSessionID,
            onStart: {
                ConversationPersistence.save(agent: agent, projectID: project.id)
            },
            onSessionReady: {
                ConversationPersistence.save(agent: agent, projectID: project.id)
            },
            onComplete: { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    guard self.project(for: agent.id)?.id == project.id else { return }
                    agent.syncExecutionStateFromConversation()
                    agent.hasUnseenCompletion = agent.status == .completed
                        && !self.completionWasCancelled(for: agent)
                        && self.completionNeedsAttention(for: agent)
                    ConversationPersistence.save(agent: agent, projectID: project.id)
                    gitStatusService.forceRefresh(projectID: project.id)
                    await refreshInspector(for: project)
                    refreshNativeThreads(for: project, discoveryMode: .indexed)
                    scheduleSave()
                }
            }
        )

        if accepted {
            scheduleSave()
        }
        return accepted
    }

    private func preflightPromptDispatch(for agent: AgentInfo) -> ProjectState? {
        guard let project = project(for: agent.id) else { return nil }
        guard runtimeHealth[agent.providerID]?.isUsable == true else {
            let isChecking = runtimeHealth[agent.providerID] == .checking
            agent.conversationState.error = isChecking
                ? "\(agent.providerName) is still starting. Try again in a moment."
                : "\(agent.providerName) is unavailable. Install or refresh its runtime in Settings."
            return nil
        }
        if let binding = agent.nativeThreadBinding,
           Self.canonicalDirectoryPath(binding.workingDirectory) != project.project.canonicalRootPath {
            agent.conversationState.error = "This provider thread belongs to a different workspace. Refresh native threads before sending."
            refreshNativeThreads(for: project)
            return nil
        }
        return project
    }

    private func handleSlashCommand(_ command: FlowXSlashCommand, attachments: [Attachment], for agent: AgentInfo) {
        guard let project = project(for: agent.id) else { return }

        Task { @MainActor in
            do {
                let configuration = effectiveConfiguration(for: agent)
                switch command {
                case .compact:
                    guard agent.conversationState.sessionID != nil else {
                        agent.conversationState.recordRuntimeActivity(
                            kind: .contextCompaction,
                            tone: .warning,
                            summary: "Nothing to compact",
                            detail: "Start a provider session first.",
                            state: "skipped",
                            turnID: agent.conversationState.activeTurnID
                        )
                        persistConversation(for: agent)
                        return
                    }

                    try await conversationService.compactThread(
                        for: agent.conversationState,
                        providerID: agent.providerID,
                        systemPrompt: agent.systemPrompt,
                        agentMode: configuration.agentMode,
                        agentAccess: configuration.agentAccess,
                        workingDirectory: project.project.rootURL,
                        resumeSessionID: agent.conversationState.sessionID
                    )
                    persistConversation(for: agent)

                case .goalView:
                    try await conversationService.refreshGoal(
                        for: agent.conversationState,
                        providerID: agent.providerID,
                        systemPrompt: agent.systemPrompt,
                        agentMode: configuration.agentMode,
                        agentAccess: configuration.agentAccess,
                        workingDirectory: project.project.rootURL,
                        resumeSessionID: agent.conversationState.sessionID
                    )
                    persistConversation(for: agent)

                case .goalSet(let objective):
                    let trimmedObjective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedObjective.isEmpty else { return }

                    let goal = try await conversationService.setGoal(
                        objective: trimmedObjective,
                        status: .active,
                        for: agent.conversationState,
                        providerID: agent.providerID,
                        systemPrompt: agent.systemPrompt,
                        agentMode: configuration.agentMode,
                        agentAccess: configuration.agentAccess,
                        workingDirectory: project.project.rootURL,
                        resumeSessionID: agent.conversationState.sessionID
                    )
                    persistConversation(for: agent)

                    if !agent.conversationState.isStreaming {
                        dispatchPrompt(trimmedObjective, attachments: attachments, for: agent, resumeSessionID: goal.threadID)
                    }

                case .goalStatus(let status):
                    try await conversationService.setGoal(
                        objective: nil,
                        status: status,
                        for: agent.conversationState,
                        providerID: agent.providerID,
                        systemPrompt: agent.systemPrompt,
                        agentMode: configuration.agentMode,
                        agentAccess: configuration.agentAccess,
                        workingDirectory: project.project.rootURL,
                        resumeSessionID: agent.conversationState.sessionID
                    )
                    persistConversation(for: agent)

                case .goalClear:
                    try await conversationService.clearGoal(
                        for: agent.conversationState,
                        providerID: agent.providerID,
                        systemPrompt: agent.systemPrompt,
                        agentMode: configuration.agentMode,
                        agentAccess: configuration.agentAccess,
                        workingDirectory: project.project.rootURL,
                        resumeSessionID: agent.conversationState.sessionID
                    )
                    persistConversation(for: agent)
                }
            } catch {
                agent.conversationState.recordRuntimeActivity(
                    kind: .error,
                    tone: .error,
                    summary: "Slash command failed",
                    detail: error.localizedDescription,
                    state: "failed",
                    turnID: agent.conversationState.activeTurnID
                )
                persistConversation(for: agent)
            }
        }
    }

    private func persistConversation(for agent: AgentInfo) {
        if let project = project(for: agent.id) {
            ConversationPersistence.save(agent: agent, projectID: project.id)
        }
        scheduleSave()
    }

    private func cancelSteeringSubmission(for agentID: UUID) {
        steeringPromptTasks.removeValue(forKey: agentID)?.cancel()
        steeringPromptSubmissionIDs[agentID] = nil
    }

    private func releaseProviderSession(for agent: AgentInfo) {
        guard let sessionID = agent.conversationState.sessionID, !sessionID.isEmpty else { return }
        let providerID = agent.providerID
        Task { [conversationService] in
            await conversationService.releaseProviderSession(sessionID, providerID: providerID)
        }
    }

    private func shutdownForTermination() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        scheduledSaveTask?.cancel()
        nativeWorkspaceSyncTask?.cancel()
        activeNativeWorkspaceSyncRequest = nil
        pendingNativeWorkspaceSyncRequest = nil
        nativeSyncingProjectIDs.removeAll()
        nativeActiveProjectPollingTask?.cancel()
        for task in nativeTranscriptTasks.values {
            task.cancel()
        }
        nativeTranscriptTasks.removeAll()
        nativeTranscriptLoadIDs.removeAll()
        for task in steeringPromptTasks.values {
            task.cancel()
        }
        steeringPromptTasks.removeAll()
        steeringPromptSubmissionIDs.removeAll()

        for project in projects {
            for agent in project.agents {
                conversationService.cancelStreaming(for: agent.id)
                conversationService.clearPendingRequests(for: agent.id)
                for session in agent.terminalSessions {
                    session.shutdown()
                }
            }
            ConversationPersistence.save(project: project)
        }
        ProjectPersistence.save(self)
        gitStatusService.stopAll()
        Task { [conversationService] in
            await conversationService.releaseAllProviderSessions()
        }
        ConversationPersistence.flush()
        ProjectPersistence.flush()
    }

    nonisolated private static func loadAttachments(
        from urls: [URL],
        existingBytes: Int,
        existingCount: Int,
        supportedKinds: Set<ProviderAttachmentKind>
    ) -> AttachmentLoadResult {
        var attachments: [Attachment] = []
        var errors: [String] = []
        var totalBytes = existingBytes
        var totalCount = existingCount

        for url in urls {
            guard !Task.isCancelled else { break }
            let filename = url.lastPathComponent
            let mimeType = Attachment.mimeType(forExtension: url.pathExtension)
            let kind: ProviderAttachmentKind?
            if mimeType.hasPrefix("image/") {
                kind = .image
            } else if mimeType == "application/pdf" {
                kind = .pdf
            } else {
                kind = nil
            }
            guard let kind, supportedKinds.contains(kind) else {
                errors.append("\(filename) is not supported by this provider.")
                continue
            }
            guard totalCount < maximumPendingAttachmentCount else {
                errors.append("Only \(maximumPendingAttachmentCount) attachments can be queued at once.")
                break
            }
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize,
                  fileSize > 0 else {
                errors.append("\(filename) is empty or unreadable.")
                continue
            }
            guard fileSize <= maximumAttachmentBytes else {
                errors.append("\(filename) exceeds the 20 MB per-file limit.")
                continue
            }
            guard totalBytes + fileSize <= maximumPendingAttachmentBytes else {
                errors.append("Attachments cannot exceed 50 MB in total.")
                break
            }

            do {
                let data = try Data(contentsOf: url)
                guard !data.isEmpty else {
                    errors.append("\(filename) is empty.")
                    continue
                }
                guard data.count <= maximumAttachmentBytes,
                      totalBytes + data.count <= maximumPendingAttachmentBytes else {
                    errors.append("\(filename) exceeds the attachment size limit.")
                    continue
                }
                attachments.append(Attachment(data: data, mimeType: mimeType, filename: filename))
                totalBytes += data.count
                totalCount += 1
            } catch {
                errors.append("\(filename) could not be read.")
            }
        }

        return AttachmentLoadResult(attachments: attachments, errors: errors)
    }

    nonisolated private static func attachmentErrorSummary(_ errors: [String]) -> String {
        let uniqueErrors = Array(Set(errors)).sorted()
        let visibleErrors = uniqueErrors.prefix(3)
        let suffix = uniqueErrors.count > visibleErrors.count
            ? " \(uniqueErrors.count - visibleErrors.count) more file(s) were skipped."
            : ""
        return visibleErrors.joined(separator: " ") + suffix
    }

    private func preferredProviderID() -> String {
        let configuredProviderID = preferences.resolvedDefaultProviderID(using: providerRegistry)
        if providerRegistry.provider(for: configuredProviderID) != nil,
           runtimeHealth[configuredProviderID]?.isUsable != false {
            return configuredProviderID
        }
        for providerID in ["codex", "claude"] where runtimeHealth[providerID]?.isUsable == true {
            if providerRegistry.provider(for: providerID) != nil {
                return providerID
            }
        }
        return providerRegistry.allProviders
            .sorted { $0.displayName < $1.displayName }
            .first?.id ?? configuredProviderID
    }

    private func defaultAgentTitle(for index: Int) -> String {
        "New Thread"
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
