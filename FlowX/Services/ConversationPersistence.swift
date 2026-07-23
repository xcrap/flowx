import Foundation
import FXAgent
import FXCore
import OSLog

private let conversationPersistenceLogger = Logger(
    subsystem: "com.flowx.app",
    category: "ConversationPersistence"
)
private let maximumPersistedConversationMessages = 250
private let maximumNativeThreadCacheMessages = 40
private let maximumPersistedConversationActivities = 200

private struct LossyConversationValue<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

struct NativeImageSidecarEntry: Codable, Sendable, Equatable {
    var sessionID: String
    var correlation: ConversationImageCorrelationKey
    var references: [ConversationImageAssetReference]
}

struct PersistedConversation: Codable, Sendable {
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
    var currentContextTokens: Int?
    var reportedContextWindow: Int?
    var activeGoal: ConversationGoal?
    var nativeImageSidecar: [NativeImageSidecarEntry]

    private enum CodingKeys: String, CodingKey {
        case agentID
        case sessionID
        case messages
        case runtimeActivities
        case totalCostUSD
        case totalInputTokens
        case totalOutputTokens
        case totalCachedInputTokens
        case totalReasoningOutputTokens
        case totalTokens
        case currentContextTokens
        case reportedContextWindow
        case activeGoal
        case nativeImageSidecar
    }

    init(
        agentID: UUID,
        sessionID: String?,
        messages: [ConversationMessage],
        runtimeActivities: [ConversationRuntimeActivity],
        totalCostUSD: Double,
        totalInputTokens: Int,
        totalOutputTokens: Int,
        totalCachedInputTokens: Int,
        totalReasoningOutputTokens: Int,
        totalTokens: Int,
        currentContextTokens: Int?,
        reportedContextWindow: Int?,
        activeGoal: ConversationGoal?,
        nativeImageSidecar: [NativeImageSidecarEntry]
    ) {
        self.agentID = agentID
        self.sessionID = sessionID
        self.messages = messages
        self.runtimeActivities = runtimeActivities
        self.totalCostUSD = totalCostUSD
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.totalCachedInputTokens = totalCachedInputTokens
        self.totalReasoningOutputTokens = totalReasoningOutputTokens
        self.totalTokens = totalTokens
        self.currentContextTokens = currentContextTokens
        self.reportedContextWindow = reportedContextWindow
        self.activeGoal = activeGoal
        self.nativeImageSidecar = nativeImageSidecar
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agentID = try container.decode(UUID.self, forKey: .agentID)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        messages = (try? container.decode([LossyConversationValue<ConversationMessage>].self, forKey: .messages))?
            .compactMap(\.value) ?? []
        runtimeActivities = (try? container.decode(
            [LossyConversationValue<ConversationRuntimeActivity>].self,
            forKey: .runtimeActivities
        ))?.compactMap(\.value) ?? []
        totalCostUSD = (try? container.decode(Double.self, forKey: .totalCostUSD)) ?? 0
        totalInputTokens = (try? container.decode(Int.self, forKey: .totalInputTokens)) ?? 0
        totalOutputTokens = (try? container.decode(Int.self, forKey: .totalOutputTokens)) ?? 0
        totalCachedInputTokens = (try? container.decode(Int.self, forKey: .totalCachedInputTokens)) ?? 0
        totalReasoningOutputTokens = (try? container.decode(Int.self, forKey: .totalReasoningOutputTokens)) ?? 0
        totalTokens = (try? container.decode(Int.self, forKey: .totalTokens)) ?? 0
        currentContextTokens = try? container.decodeIfPresent(Int.self, forKey: .currentContextTokens)
        reportedContextWindow = try? container.decodeIfPresent(Int.self, forKey: .reportedContextWindow)
        activeGoal = try? container.decodeIfPresent(ConversationGoal.self, forKey: .activeGoal)
        nativeImageSidecar = (try? container.decode(
            [LossyConversationValue<NativeImageSidecarEntry>].self,
            forKey: .nativeImageSidecar
        ))?.compactMap(\.value) ?? []
    }
}

struct PersistedProjectConversations: Codable, Sendable {
    var conversations: [PersistedConversation]
}

private struct ConversationWriteRequest: Sendable {
    let projectID: UUID
    let url: URL
    let payload: PersistedConversation
    let imageMaterializationMessages: [ConversationMessage]
    let didPersist: @MainActor @Sendable (
        PersistedConversation,
        Set<ConversationImageAssetReference>
    ) -> Void
}

private final class ConversationPersistenceWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.flowx.persistence.conversations", qos: .utility)
    private let lock = NSLock()
    private var pending: [URL: ConversationWriteRequest] = [:]
    private var draining = false
    private var removedProjects: Set<UUID> = []
    private var removedConversations: Set<URL> = []

    func enqueue(_ request: ConversationWriteRequest, projectID: UUID) {
        lock.lock()
        guard !removedProjects.contains(projectID), !removedConversations.contains(request.url) else {
            lock.unlock()
            return
        }
        let mergedRequest: ConversationWriteRequest
        if let existing = pending[request.url] {
            mergedRequest = ConversationWriteRequest(
                projectID: request.projectID,
                url: request.url,
                payload: request.payload,
                imageMaterializationMessages: ConversationImagePersistencePolicy
                    .mergingMaterializationMessages(
                        existing: existing.imageMaterializationMessages,
                        newer: request.imageMaterializationMessages
                    ),
                didPersist: request.didPersist
            )
        } else {
            mergedRequest = request
        }
        pending[request.url] = mergedRequest
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

    func removeConversation(at url: URL, assetDirectoryURL: URL) {
        lock.lock()
        removedConversations.insert(url)
        pending[url] = nil
        lock.unlock()

        queue.async {
            Self.removeFileAndBackup(at: url)
            try? FileManager.default.removeItem(at: assetDirectoryURL)
        }
    }

    func removeProject(projectID: UUID, legacyURL: URL, directoryURL: URL) {
        lock.lock()
        removedProjects.insert(projectID)
        pending = pending.filter { !$0.key.path.hasPrefix(directoryURL.path + "/") }
        lock.unlock()

        queue.async {
            Self.removeFileAndBackup(at: legacyURL)
            try? FileManager.default.removeItem(at: directoryURL)
        }
    }

    func flush() {
        queue.sync {}
    }

    private func drain() {
        while true {
            lock.lock()
            guard let request = pending.values.first else {
                draining = false
                lock.unlock()
                return
            }
            pending[request.url] = nil
            let wasRemoved = removedConversations.contains(request.url)
            lock.unlock()

            guard !wasRemoved else { continue }

            do {
                let sanitized = ConversationPersistence.sanitizedConversation(request.payload)
                let assetResult = try ConversationAssetStore.persistAssets(
                    in: sanitized,
                    projectID: request.projectID
                )
                let materializedImageReferences = try ConversationAssetStore.persistImageAssets(
                    in: request.imageMaterializationMessages,
                    projectID: request.projectID,
                    agentID: sanitized.agentID,
                    alreadyPersisted: assetResult.references
                )
                var persistedConversation = assetResult.conversation
                persistedConversation.nativeImageSidecar = ConversationAssetStore.updatedNativeImageSidecar(
                    existing: sanitized.nativeImageSidecar,
                    messages: persistedConversation.messages,
                    sessionID: persistedConversation.sessionID,
                    projectID: request.projectID,
                    agentID: persistedConversation.agentID
                )
                let data = try JSONEncoder().encode(persistedConversation)
                try Self.writeAtomicallyWithRecoveryCopy(data, to: request.url)
                let retainedReferences = assetResult.references
                    .union(materializedImageReferences)
                    .union(
                        ConversationAssetStore.nativeImageReferences(
                            in: persistedConversation.nativeImageSidecar,
                            projectID: request.projectID,
                            agentID: persistedConversation.agentID
                        )
                    )
                ConversationAssetStore.removeUnreferencedAssets(
                    projectID: request.projectID,
                    agentID: request.payload.agentID,
                    retaining: retainedReferences
                )
                Task { @MainActor in
                    request.didPersist(persistedConversation, materializedImageReferences)
                }
            } catch {
                conversationPersistenceLogger.error(
                    "Failed to save conversation: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private static func writeAtomicallyWithRecoveryCopy(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        let projectDirectory = url.deletingLastPathComponent()
        let conversationsDirectory = projectDirectory.deletingLastPathComponent()
        let appDirectory = conversationsDirectory.deletingLastPathComponent()
        for directory in [appDirectory, conversationsDirectory, projectDirectory] {
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }

        try data.write(to: url, options: .atomic)
        let backupURL = url.appendingPathExtension("backup")
        try data.write(to: backupURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
    }

    private static func removeFileAndBackup(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("backup"))
    }
}

@MainActor
enum ConversationPersistence {
    private static let maxConversationFileBytes = 32 * 1_024 * 1_024
    private static let writer = ConversationPersistenceWriter()

    private static var baseDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent(AppEnvironment.appSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("conversations", isDirectory: true)
    }

    private static func legacyFileURL(for projectID: UUID) -> URL {
        baseDirectoryURL.appendingPathComponent("\(projectID.uuidString).json")
    }

    private static func projectDirectoryURL(for projectID: UUID) -> URL {
        baseDirectoryURL.appendingPathComponent(projectID.uuidString, isDirectory: true)
    }

    private static func conversationFileURL(agentID: UUID, projectID: UUID) -> URL {
        projectDirectoryURL(for: projectID).appendingPathComponent("\(agentID.uuidString).json")
    }

    static func save(agent: AgentInfo, projectID: UUID) {
        let state = agent.conversationState
        agent.nativeImageSidecar = ConversationAssetStore.updatedNativeImageSidecar(
            existing: agent.nativeImageSidecar,
            messages: state.messages,
            sessionID: state.sessionID,
            projectID: projectID,
            agentID: agent.id
        )
        // Provider-native storage owns the transcript. This is deliberately a
        // small, replaceable cache; it also retains durable image references
        // until the authoritative transcript refresh completes.
        let messageLimit = state.sessionID == nil
            ? maximumPersistedConversationMessages
            : maximumNativeThreadCacheMessages
        let payload = PersistedConversation(
            agentID: agent.id,
            sessionID: state.sessionID,
            messages: Array(state.messages.suffix(messageLimit)),
            runtimeActivities: Array(state.runtimeActivities.suffix(maximumPersistedConversationActivities)),
            totalCostUSD: state.totalCostUSD,
            totalInputTokens: state.totalInputTokens,
            totalOutputTokens: state.totalOutputTokens,
            totalCachedInputTokens: state.totalCachedInputTokens,
            totalReasoningOutputTokens: state.totalReasoningOutputTokens,
            totalTokens: state.totalTokens,
            currentContextTokens: state.currentContextTokens,
            reportedContextWindow: state.reportedContextWindow,
            activeGoal: state.activeGoal,
            nativeImageSidecar: agent.nativeImageSidecar
        )
        let url = conversationFileURL(agentID: agent.id, projectID: projectID)
        writer.enqueue(
            ConversationWriteRequest(
                projectID: projectID,
                url: url,
                payload: payload,
                imageMaterializationMessages: ConversationImagePersistencePolicy.materializationMessages(
                    from: state.messages
                ),
                didPersist: { [weak agent] persistedConversation, materializedImageReferences in
                    guard let agent,
                          agent.id == persistedConversation.agentID,
                          agent.conversationState.sessionID == persistedConversation.sessionID else {
                        return
                    }
                    agent.nativeImageSidecar = persistedConversation.nativeImageSidecar
                    if let materializedMessages = ConversationAssetStore.materializingPersistedImages(
                        in: agent.conversationState.messages,
                        from: materializedImageReferences,
                        projectID: projectID,
                        agentID: agent.id
                    ) {
                        agent.conversationState.replaceMessages(materializedMessages)
                    }
                }
            ),
            projectID: projectID
        )
    }

    static func save(project: ProjectState) {
        for agent in project.agents {
            save(agent: agent, projectID: project.id)
        }
    }

    static func remove(agentID: UUID, projectID: UUID) {
        writer.removeConversation(
            at: conversationFileURL(agentID: agentID, projectID: projectID),
            assetDirectoryURL: ConversationAssetStore.agentDirectoryURL(projectID: projectID, agentID: agentID)
        )
    }

    static func remove(projectID: UUID) {
        writer.removeProject(
            projectID: projectID,
            legacyURL: legacyFileURL(for: projectID),
            directoryURL: projectDirectoryURL(for: projectID)
        )
    }

    static func flush() {
        writer.flush()
    }

    static func load(for projectID: UUID) async -> [UUID: PersistedConversation] {
        let legacyURL = legacyFileURL(for: projectID)
        let directoryURL = projectDirectoryURL(for: projectID)
        let maxBytes = maxConversationFileBytes

        let readTask = Task.detached(priority: .userInitiated) {
            var result: [UUID: PersistedConversation] = [:]
            guard !Task.isCancelled else { return result }

            if let legacyPayload = decode(
                PersistedProjectConversations.self,
                primaryURL: legacyURL,
                maxBytes: maxBytes
            ) {
                for conversation in legacyPayload.conversations {
                    result[conversation.agentID] = sanitizedConversation(conversation)
                }
            }

            let manager = FileManager.default
            guard !Task.isCancelled else { return result }
            let contents = (try? manager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            var agentIDs: Set<UUID> = []
            for url in contents {
                guard !Task.isCancelled else { return result }
                let name = url.lastPathComponent
                let identifier: String
                if name.hasSuffix(".json.backup") {
                    identifier = String(name.dropLast(".json.backup".count))
                } else if name.hasSuffix(".json") {
                    identifier = String(name.dropLast(".json".count))
                } else {
                    continue
                }
                if let agentID = UUID(uuidString: identifier) {
                    agentIDs.insert(agentID)
                }
            }

            for agentID in agentIDs {
                guard !Task.isCancelled else { return result }
                let primaryURL = directoryURL.appendingPathComponent("\(agentID.uuidString).json")
                guard let conversation = decode(
                    PersistedConversation.self,
                    primaryURL: primaryURL,
                    maxBytes: maxBytes
                ), conversation.agentID == agentID else {
                    continue
                }
                result[agentID] = sanitizedConversation(conversation)
            }

            return result
        }
        let result = await withTaskCancellationHandler {
            await readTask.value
        } onCancel: {
            readTask.cancel()
        }
        return Task.isCancelled ? [:] : result
    }

    static func load(
        agentIDs: Set<UUID>,
        for projectID: UUID
    ) async -> [UUID: PersistedConversation] {
        guard !agentIDs.isEmpty else { return [:] }
        let legacyURL = legacyFileURL(for: projectID)
        let directoryURL = projectDirectoryURL(for: projectID)
        let maxBytes = maxConversationFileBytes
        let readTask = Task.detached(priority: .utility) {
            var result: [UUID: PersistedConversation] = [:]
            guard !Task.isCancelled else { return result }
            if let legacyPayload = decode(
                PersistedProjectConversations.self,
                primaryURL: legacyURL,
                maxBytes: maxBytes
            ) {
                for conversation in legacyPayload.conversations where agentIDs.contains(conversation.agentID) {
                    result[conversation.agentID] = sanitizedConversation(conversation)
                }
            }

            for agentID in agentIDs {
                guard !Task.isCancelled else { return result }
                let primaryURL = directoryURL.appendingPathComponent("\(agentID.uuidString).json")
                guard let conversation = decode(
                    PersistedConversation.self,
                    primaryURL: primaryURL,
                    maxBytes: maxBytes
                ), conversation.agentID == agentID else {
                    continue
                }
                result[agentID] = sanitizedConversation(conversation)
            }
            return result
        }
        let result = await withTaskCancellationHandler {
            await readTask.value
        } onCancel: {
            readTask.cancel()
        }
        return Task.isCancelled ? [:] : result
    }

    static func state(from conversation: PersistedConversation) -> ConversationState {
        let state = ConversationState(agentID: conversation.agentID)
        hydrate(state, from: conversation)
        return state
    }

    static func hydrate(
        _ state: ConversationState,
        from conversation: PersistedConversation
    ) {
        guard state.agentID == conversation.agentID else { return }
        state.sessionID = conversation.sessionID
        state.replaceMessages(conversation.messages)
        state.runtimeActivities = Array(conversation.runtimeActivities.suffix(maximumPersistedConversationActivities))
        state.totalCostUSD = conversation.totalCostUSD
        state.totalInputTokens = conversation.totalInputTokens
        state.totalOutputTokens = conversation.totalOutputTokens
        state.totalCachedInputTokens = conversation.totalCachedInputTokens
        state.totalReasoningOutputTokens = conversation.totalReasoningOutputTokens
        state.totalTokens = conversation.totalTokens
        state.currentContextTokens = conversation.currentContextTokens
        state.reportedContextWindow = conversation.reportedContextWindow
        state.activeGoal = conversation.activeGoal
    }

    nonisolated fileprivate static func sanitizedConversation(
        _ conversation: PersistedConversation
    ) -> PersistedConversation {
        var sanitized = conversation
        let messageLimit = conversation.sessionID == nil
            ? maximumPersistedConversationMessages
            : maximumNativeThreadCacheMessages
        sanitized.messages = Array(conversation.messages.suffix(messageLimit))
        sanitized.runtimeActivities = Array(conversation.runtimeActivities.suffix(maximumPersistedConversationActivities))
        sanitized.nativeImageSidecar = Array(conversation.nativeImageSidecar.prefix(500))
        return sanitized
    }

    nonisolated private static func decode<Value: Decodable>(
        _ type: Value.Type,
        primaryURL: URL,
        maxBytes: Int
    ) -> Value? {
        for url in [primaryURL, primaryURL.appendingPathExtension("backup")] {
            guard !Task.isCancelled else { return nil }
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize,
                  fileSize <= maxBytes,
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                continue
            }
            guard !Task.isCancelled else { return nil }
            guard let decoded = try? JSONDecoder().decode(type, from: data) else {
                continue
            }
            return decoded
        }
        return nil
    }
}
