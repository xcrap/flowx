import Foundation
import FXCore
import OSLog

private let projectPersistenceLogger = Logger(
    subsystem: "com.flowx.app",
    category: "ProjectPersistence"
)

private struct LossyProjectValue<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

struct PersistedWorkspace: Codable, Sendable {
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
        splitOpen = (try? container.decode(Bool.self, forKey: .splitOpen)) ?? false
        splitContent = (try? container.decode(SplitContent.self, forKey: .splitContent)) ?? .diff
        splitRatio = min(max((try? container.decode(Double.self, forKey: .splitRatio)) ?? 0.5, 0.2), 0.8)
        terminalVisible = (try? container.decode(Bool.self, forKey: .terminalVisible)) ?? false
        terminalHeight = min(max((try? container.decode(Double.self, forKey: .terminalHeight)) ?? 220, 120), 500)
        terminalCount = min(max((try? container.decode(Int.self, forKey: .terminalCount)) ?? 1, 1), 3)
        browserURLString = (try? container.decode(String.self, forKey: .browserURLString)) ?? ""
        conversationScrollOffset = max(
            (try? container.decode(Double.self, forKey: .conversationScrollOffset)) ?? 0,
            0
        )
        conversationPinnedToBottom = (try? container.decode(Bool.self, forKey: .conversationPinnedToBottom)) ?? true
    }
}

struct PersistedNativeThreadBinding: Codable, Sendable {
    var agentID: UUID
    var binding: NativeThreadBinding
}

struct PersistedNativePresentationID: Codable, Sendable {
    var identity: NativeThreadIdentity
    var agentID: UUID
}

struct PersistedProjectRecord: Codable, Sendable {
    var project: Project
    var agents: [Agent]
    var isExpanded: Bool
    var lastSelectedAgentID: UUID?
    var selectedInspectorPath: String?
    var inspectorComparisonMode: InspectorComparisonMode
    var inspectorDiffDisplayMode: InspectorDiffDisplayMode
    var workspaces: [PersistedWorkspace]
    var nativeThreadBindings: [PersistedNativeThreadBinding]
    var nativePresentationIDs: [PersistedNativePresentationID]

    enum CodingKeys: String, CodingKey {
        case project
        case agents
        case isExpanded
        case lastSelectedAgentID
        case selectedInspectorPath
        case inspectorComparisonMode
        case inspectorDiffDisplayMode
        case workspaces
        case nativeThreadBindings
        case nativePresentationIDs
    }

    init(
        project: Project,
        agents: [Agent],
        isExpanded: Bool,
        lastSelectedAgentID: UUID?,
        selectedInspectorPath: String?,
        inspectorComparisonMode: InspectorComparisonMode,
        inspectorDiffDisplayMode: InspectorDiffDisplayMode,
        workspaces: [PersistedWorkspace],
        nativeThreadBindings: [PersistedNativeThreadBinding],
        nativePresentationIDs: [PersistedNativePresentationID]
    ) {
        self.project = project
        self.agents = agents
        self.isExpanded = isExpanded
        self.lastSelectedAgentID = lastSelectedAgentID
        self.selectedInspectorPath = selectedInspectorPath
        self.inspectorComparisonMode = inspectorComparisonMode
        self.inspectorDiffDisplayMode = inspectorDiffDisplayMode
        self.workspaces = workspaces
        self.nativeThreadBindings = nativeThreadBindings
        self.nativePresentationIDs = nativePresentationIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        project = try container.decode(Project.self, forKey: .project)
        agents = (try? container.decode([LossyProjectValue<Agent>].self, forKey: .agents))?
            .compactMap(\.value) ?? []
        isExpanded = (try? container.decode(Bool.self, forKey: .isExpanded)) ?? true
        lastSelectedAgentID = try? container.decodeIfPresent(UUID.self, forKey: .lastSelectedAgentID)
        selectedInspectorPath = try? container.decodeIfPresent(String.self, forKey: .selectedInspectorPath)
        inspectorComparisonMode = (try? container.decode(
            InspectorComparisonMode.self,
            forKey: .inspectorComparisonMode
        )) ?? .unstaged
        inspectorDiffDisplayMode = (try? container.decode(
            InspectorDiffDisplayMode.self,
            forKey: .inspectorDiffDisplayMode
        )) ?? .inline
        workspaces = (try? container.decode(
            [LossyProjectValue<PersistedWorkspace>].self,
            forKey: .workspaces
        ))?.compactMap(\.value) ?? []
        nativeThreadBindings = (try? container.decode(
            [LossyProjectValue<PersistedNativeThreadBinding>].self,
            forKey: .nativeThreadBindings
        ))?.compactMap(\.value) ?? []
        nativePresentationIDs = (try? container.decode(
            [LossyProjectValue<PersistedNativePresentationID>].self,
            forKey: .nativePresentationIDs
        ))?.compactMap(\.value) ?? []
    }
}

struct PersistedFlowXAppState: Codable, Sendable {
    var projects: [PersistedProjectRecord]
    var activeProjectID: UUID?
    var activeAgentID: UUID?
    var sidebarVisible: Bool
    var rightPanelVisible: Bool
    var rightPanelWidth: Double
    var rightPanelTab: RightPanelTab

    enum CodingKeys: String, CodingKey {
        case projects
        case activeProjectID
        case activeAgentID
        case sidebarVisible
        case rightPanelVisible
        case rightPanelWidth
        case rightPanelTab
    }

    init(
        projects: [PersistedProjectRecord],
        activeProjectID: UUID?,
        activeAgentID: UUID?,
        sidebarVisible: Bool,
        rightPanelVisible: Bool,
        rightPanelWidth: Double,
        rightPanelTab: RightPanelTab
    ) {
        self.projects = projects
        self.activeProjectID = activeProjectID
        self.activeAgentID = activeAgentID
        self.sidebarVisible = sidebarVisible
        self.rightPanelVisible = rightPanelVisible
        self.rightPanelWidth = rightPanelWidth
        self.rightPanelTab = rightPanelTab
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projects = (try? container.decode(
            [LossyProjectValue<PersistedProjectRecord>].self,
            forKey: .projects
        ))?.compactMap(\.value) ?? []
        activeProjectID = try? container.decodeIfPresent(UUID.self, forKey: .activeProjectID)
        activeAgentID = try? container.decodeIfPresent(UUID.self, forKey: .activeAgentID)
        sidebarVisible = (try? container.decode(Bool.self, forKey: .sidebarVisible)) ?? true
        rightPanelVisible = (try? container.decode(Bool.self, forKey: .rightPanelVisible)) ?? false
        rightPanelWidth = min(
            max(
                (try? container.decode(Double.self, forKey: .rightPanelWidth))
                    ?? Double(FlowXLayoutDefaults.defaultRightPanelWidth),
                Double(FlowXLayoutDefaults.minRightPanelWidth)
            ),
            Double(FlowXLayoutDefaults.maxRightPanelWidth)
        )
        rightPanelTab = (try? container.decode(RightPanelTab.self, forKey: .rightPanelTab)) ?? .changes
    }
}

private final class ProjectPersistenceWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.flowx.persistence.projects", qos: .utility)
    private let lock = NSLock()
    private var pending: (payload: PersistedFlowXAppState, url: URL)?
    private var draining = false

    func enqueue(_ payload: PersistedFlowXAppState, to url: URL) {
        lock.lock()
        pending = (payload, url)
        let shouldStartDrain = !draining
        if shouldStartDrain {
            draining = true
        }
        lock.unlock()

        if shouldStartDrain {
            queue.async { [weak self] in
                self?.drain()
            }
        }
    }

    func flush() {
        queue.sync {}
    }

    private func drain() {
        while true {
            lock.lock()
            guard let request = pending else {
                draining = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()

            do {
                let data = try JSONEncoder().encode(request.payload)
                try Self.writePrimaryAndRecoveryCopy(data, to: request.url)
            } catch {
                projectPersistenceLogger.error(
                    "Failed to save projects: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private static func writePrimaryAndRecoveryCopy(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try data.write(to: url, options: .atomic)
        let backupURL = url.appendingPathExtension("backup")
        try data.write(to: backupURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
    }
}

@MainActor
enum ProjectPersistence {
    private static let maxProjectFileBytes = 16 * 1_024 * 1_024
    private static let maximumDormantNativePresentationIDs = 32
    private static let writer = ProjectPersistenceWriter()

    private static var saveURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent(AppEnvironment.appSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("projects.json")
    }

    static func save(_ appState: AppState) {
        writer.enqueue(snapshot(of: appState), to: saveURL)
    }

    static func flush() {
        writer.flush()
    }

    static func load(into appState: AppState) async {
        let url = saveURL
        let maxBytes = maxProjectFileBytes
        guard let payload = await Task.detached(priority: .userInitiated, operation: {
            decode(PersistedFlowXAppState.self, primaryURL: url, maxBytes: maxBytes)
        }).value else {
            return
        }

        var seenProjectIDs: Set<UUID> = []
        var seenRootPaths: Set<String> = []
        var seenAgentIDs: Set<UUID> = []
        var restoredProjects: [ProjectState] = []

        for persisted in payload.projects {
            var project = persisted.project
            guard let validatedRootPath = Project.validatedPersistedRootPath(project.rootPath) else {
                projectPersistenceLogger.error(
                    "Ignored project with unsafe root path for ID \(project.id.uuidString, privacy: .public)"
                )
                continue
            }
            project.rootPath = validatedRootPath
            let canonicalPath = project.canonicalRootPath
            guard seenProjectIDs.insert(project.id).inserted,
                  seenRootPaths.insert(canonicalPath).inserted else {
                continue
            }

            let uniqueAgents = persisted.agents.filter { seenAgentIDs.insert($0.id).inserted }
            var order: [UUID: Int] = [:]
            for (index, agentID) in project.agentOrder.enumerated() where order[agentID] == nil {
                order[agentID] = index
            }
            let orderedAgents = uniqueAgents.enumerated().sorted { lhs, rhs in
                let lhsOrder = order[lhs.element.id] ?? (order.count + lhs.offset)
                let rhsOrder = order[rhs.element.id] ?? (order.count + rhs.offset)
                return lhsOrder < rhsOrder
            }.map(\.element)
            project.agentOrder = orderedAgents.map(\.id)

            var workspaceMap: [UUID: PersistedWorkspace] = [:]
            for workspace in persisted.workspaces where workspaceMap[workspace.agentID] == nil {
                workspaceMap[workspace.agentID] = workspace
            }

            var bindingMap: [UUID: NativeThreadBinding] = [:]
            var seenNativeIdentities: Set<NativeThreadIdentity> = []
            let persistedBindingAgentIDs = Set(persisted.nativeThreadBindings.map(\.agentID))
            for persistedBinding in persisted.nativeThreadBindings {
                guard bindingMap[persistedBinding.agentID] == nil,
                      let binding = Self.validatedNativeBinding(
                        persistedBinding.binding,
                        expectedCanonicalPath: canonicalPath
                      ), seenNativeIdentities.insert(binding.identity).inserted else {
                    continue
                }
                bindingMap[persistedBinding.agentID] = binding
            }
            let invalidBindingAgentIDs = persistedBindingAgentIDs.subtracting(bindingMap.keys)
            let activeNativeIdentities = Set(bindingMap.values.map(\.identity))
            var dormantNativePresentationAgentIDs: [NativeThreadIdentity: UUID] = [:]
            for presentation in persisted.nativePresentationIDs {
                let providerID = AgentInfo.normalizedProviderID(presentation.identity.providerID)
                let sessionID = presentation.identity.sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !sessionID.isEmpty else { continue }
                var identity = presentation.identity
                identity.providerID = providerID
                identity.sessionID = sessionID
                guard !activeNativeIdentities.contains(identity),
                      dormantNativePresentationAgentIDs[identity] == nil else {
                    continue
                }
                dormantNativePresentationAgentIDs[identity] = presentation.agentID
            }
            var nativePresentationAgentIDs: [NativeThreadIdentity: UUID] = [:]
            let sortedDormantPresentationIDs = dormantNativePresentationAgentIDs.sorted {
                Self.nativeIdentitySortKey($0.key) < Self.nativeIdentitySortKey($1.key)
            }
            for (identity, agentID) in sortedDormantPresentationIDs {
                guard nativePresentationAgentIDs.count < maximumDormantNativePresentationIDs else { break }
                nativePresentationAgentIDs[identity] = agentID
            }
            for (agentID, binding) in bindingMap {
                nativePresentationAgentIDs[binding.identity] = agentID
            }

            // Drafts are FlowX-owned and load eagerly. Provider-native rows use
            // their binding for sidebar presentation; only the selected native
            // cache is decoded now and other caches hydrate lazily on activation.
            let selectedConversationIDs = Set(
                [persisted.lastSelectedAgentID, payload.activeAgentID].compactMap { $0 }
            )
            let eagerConversationIDs = Set(orderedAgents.compactMap { agent -> UUID? in
                bindingMap[agent.id] == nil || selectedConversationIDs.contains(agent.id)
                    ? agent.id
                    : nil
            })
            let conversations = await ConversationPersistence.load(
                agentIDs: eagerConversationIDs,
                for: project.id
            )
            let agents = orderedAgents.map { agent in
                let conversation = conversations[agent.id]
                let safeConversation = invalidBindingAgentIDs.contains(agent.id) ? nil : conversation
                return AgentInfo(
                    agent: agent,
                    projectRootPath: project.rootPath,
                    conversationState: safeConversation.map(ConversationPersistence.state),
                    workspace: workspaceMap[agent.id].map(WorkspaceState.init),
                    nativeThreadBinding: bindingMap[agent.id],
                    nativeImageSidecar: safeConversation?.nativeImageSidecar ?? []
                )
            }

            let projectState = ProjectState(
                project: project,
                agents: agents,
                isExpanded: persisted.isExpanded,
                nativePresentationAgentIDs: nativePresentationAgentIDs
            )
            projectState.lastSelectedAgentID = persisted.lastSelectedAgentID.flatMap { selectedID in
                agents.contains(where: { $0.id == selectedID }) ? selectedID : nil
            } ?? agents.first?.id
            projectState.selectedInspectorPath = Self.validatedRelativePath(persisted.selectedInspectorPath)
            projectState.inspectorComparisonMode = persisted.inspectorComparisonMode
            projectState.inspectorDiffDisplayMode = persisted.inspectorDiffDisplayMode
            restoredProjects.append(projectState)
        }

        appState.projects = restoredProjects
        appState.activeProjectID = payload.activeProjectID.flatMap { selectedID in
            restoredProjects.contains(where: { $0.id == selectedID }) ? selectedID : nil
        }
        appState.activeAgentID = payload.activeAgentID
        appState.sidebarVisible = payload.sidebarVisible
        appState.rightPanelVisible = payload.rightPanelVisible
        appState.rightPanelWidth = CGFloat(payload.rightPanelWidth)
        appState.rightPanelTab = payload.rightPanelTab
    }

    private static func snapshot(of appState: AppState) -> PersistedFlowXAppState {
        PersistedFlowXAppState(
            projects: appState.projects.map { project in
                PersistedProjectRecord(
                    project: project.project,
                    agents: project.agents.map(\.agent),
                    isExpanded: project.isExpanded,
                    lastSelectedAgentID: project.lastSelectedAgentID,
                    selectedInspectorPath: Self.validatedRelativePath(project.selectedInspectorPath),
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
                    },
                    nativeThreadBindings: project.agents.compactMap { agent in
                        agent.nativeThreadBinding.map {
                            PersistedNativeThreadBinding(agentID: agent.id, binding: $0)
                        }
                    },
                    nativePresentationIDs: Self.boundedNativePresentationIDs(for: project)
                )
            },
            activeProjectID: appState.activeProjectID,
            activeAgentID: appState.activeAgentID,
            sidebarVisible: appState.sidebarVisible,
            rightPanelVisible: appState.rightPanelVisible,
            rightPanelWidth: Double(appState.rightPanelWidth),
            rightPanelTab: appState.rightPanelTab
        )
    }

    nonisolated private static func validatedRelativePath(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else { return nil }
        let components = NSString(string: trimmed).pathComponents
        guard !components.contains("..") else { return nil }
        return trimmed
    }

    nonisolated private static func validatedNativeBinding(
        _ binding: NativeThreadBinding,
        expectedCanonicalPath: String
    ) -> NativeThreadBinding? {
        let rawPath = binding.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let expandedPath = (rawPath as NSString).expandingTildeInPath
        guard !rawPath.isEmpty, (expandedPath as NSString).isAbsolutePath else { return nil }
        let canonicalPath = URL(fileURLWithPath: expandedPath, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let sessionID = binding.identity.sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canonicalPath == expectedCanonicalPath, !sessionID.isEmpty else { return nil }

        var normalized = binding
        normalized.identity.providerID = AgentInfo.normalizedProviderID(binding.identity.providerID)
        normalized.identity.providerSource = binding.identity.providerSource
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.identity.providerSource.isEmpty {
            normalized.identity.providerSource = normalized.identity.providerID
        }
        normalized.identity.sessionID = sessionID
        normalized.workingDirectory = canonicalPath
        normalized.model = normalized.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.effort = normalized.effort?.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized
    }

    nonisolated private static func nativeIdentitySortKey(_ identity: NativeThreadIdentity) -> String {
        "\(identity.providerID)\u{0}\(identity.sessionID)\u{0}\(identity.providerSource)"
    }

    private static func boundedNativePresentationIDs(
        for project: ProjectState
    ) -> [PersistedNativePresentationID] {
        var bounded: [NativeThreadIdentity: UUID] = [:]
        for agent in project.agents {
            if let identity = agent.nativeThreadBinding?.identity {
                bounded[identity] = agent.id
            }
        }

        let activeIdentities = Set(bounded.keys)
        let dormant = project.nativePresentationAgentIDs
            .filter { !activeIdentities.contains($0.key) }
            .sorted { Self.nativeIdentitySortKey($0.key) < Self.nativeIdentitySortKey($1.key) }
            .prefix(maximumDormantNativePresentationIDs)
        for (identity, agentID) in dormant {
            bounded[identity] = agentID
        }

        return bounded.map {
            PersistedNativePresentationID(identity: $0.key, agentID: $0.value)
        }.sorted {
            Self.nativeIdentitySortKey($0.identity) < Self.nativeIdentitySortKey($1.identity)
        }
    }

    nonisolated private static func decode<Value: Decodable>(
        _ type: Value.Type,
        primaryURL: URL,
        maxBytes: Int
    ) -> Value? {
        for url in [primaryURL, primaryURL.appendingPathExtension("backup")] {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize,
                  fileSize <= maxBytes,
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let decoded = try? JSONDecoder().decode(type, from: data) else {
                continue
            }
            return decoded
        }
        return nil
    }
}
