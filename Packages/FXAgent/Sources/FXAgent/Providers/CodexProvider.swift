import Foundation
import CoreFoundation
import os
import FXCore

private final class CodexStderrCapture: @unchecked Sendable {
    private static let maximumBytes = 256 * 1_024
    private let storage = OSAllocatedUnfairLock(initialState: Data())

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        storage.withLock { value in
            value.append(data)
            if value.count > Self.maximumBytes {
                value.removeFirst(value.count - Self.maximumBytes)
            }
        }
    }

    var text: String {
        storage.withLock { String(decoding: $0, as: UTF8.self) }
    }
}

/// Incremental newline framing for app-server JSON-RPC. `scanOffset` remembers
/// bytes already checked when a large JSON object arrives across many chunks,
/// keeping framing linear instead of rescanning the entire partial line.
struct ProviderJSONLineBuffer: Sendable {
    private var storage = Data()
    private var scanOffset = 0
    let maximumBytes: Int

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    mutating func append(_ data: Data) -> (lines: [String], overflow: Bool) {
        storage.append(data)
        guard storage.count <= maximumBytes else {
            reset(keepingCapacity: false)
            return ([], true)
        }

        var lines: [String] = []
        var lineStart = storage.startIndex
        var index = storage.index(storage.startIndex, offsetBy: min(scanOffset, storage.count))
        var consumedThrough = storage.startIndex

        while index < storage.endIndex {
            if storage[index] == 0x0A {
                var lineEnd = index
                if lineEnd > lineStart, storage[storage.index(before: lineEnd)] == 0x0D {
                    lineEnd = storage.index(before: lineEnd)
                }
                if lineEnd > lineStart {
                    lines.append(String(decoding: storage[lineStart..<lineEnd], as: UTF8.self))
                }
                consumedThrough = storage.index(after: index)
                lineStart = consumedThrough
            }
            index = storage.index(after: index)
        }

        if consumedThrough > storage.startIndex {
            storage.removeSubrange(storage.startIndex..<consumedThrough)
        }
        scanOffset = storage.count
        return (lines, false)
    }

    mutating func flush() -> String? {
        guard !storage.isEmpty else {
            reset(keepingCapacity: true)
            return nil
        }
        let line = String(decoding: storage, as: UTF8.self)
        reset(keepingCapacity: false)
        return line
    }

    mutating func reset(keepingCapacity: Bool) {
        storage.removeAll(keepingCapacity: keepingCapacity)
        scanOffset = 0
    }
}

struct CodexNativeTurnPageAccumulator {
    private(set) var newestFirstTurns: [[String: Any]] = []
    private var seenCursors: Set<String> = []
    let maximumTurns: Int

    init(maximumTurns: Int) {
        self.maximumTurns = max(1, maximumTurns)
    }

    mutating func append(page: [[String: Any]], nextCursor: String?) -> String? {
        guard !page.isEmpty, newestFirstTurns.count < maximumTurns else { return nil }
        newestFirstTurns.append(contentsOf: page.prefix(maximumTurns - newestFirstTurns.count))
        guard newestFirstTurns.count < maximumTurns,
              let nextCursor,
              !nextCursor.isEmpty,
              seenCursors.insert(nextCursor).inserted else {
            return nil
        }
        return nextCursor
    }

    var chronologicalTurns: [[String: Any]] {
        Array(newestFirstTurns.reversed())
    }
}

private actor CodexSessionStore {
    private struct Entry {
        let session: CodexSession
        var lastAccess: UInt64
    }

    private static let maximumRetainedSessions = 6
    private var sessions: [String: Entry] = [:]
    private var accessCounter: UInt64 = 0
    private var cleanupTask: Task<Void, Never>?

    func session(
        for threadID: String?,
        workingDirectory: URL?,
        systemPrompt: String?,
        agentMode: AgentMode?,
        agentAccess: AgentAccess?,
        discovery: RuntimeDiscovery
    ) -> CodexSession {
        if let threadID, var existing = sessions[threadID] {
            existing.lastAccess = nextAccess()
            sessions[threadID] = existing
            return existing.session
        }

        let session = CodexSession(
            resumeThreadID: threadID,
            workingDirectory: workingDirectory,
            systemPrompt: systemPrompt,
            agentMode: agentMode,
            agentAccess: agentAccess,
            discovery: discovery
        )

        if let threadID {
            sessions[threadID] = Entry(session: session, lastAccess: nextAccess())
        }

        return session
    }

    func register(_ session: CodexSession, for threadID: String) async {
        sessions[threadID] = Entry(session: session, lastAccess: nextAccess())
        await evictIdleSessionsIfNeeded(excluding: threadID)
        scheduleCleanupIfNeeded()
    }

    func release(_ threadID: String) async {
        guard let entry = sessions.removeValue(forKey: threadID) else { return }
        await entry.session.shutdown()
    }

    func releaseAll() async {
        cleanupTask?.cancel()
        cleanupTask = nil
        let retained = sessions.values.map(\.session)
        sessions.removeAll(keepingCapacity: false)
        for session in retained {
            await session.shutdown()
        }
    }

    private func nextAccess() -> UInt64 {
        accessCounter &+= 1
        return accessCounter
    }

    private func evictIdleSessionsIfNeeded(excluding protectedThreadID: String) async {
        guard sessions.count > Self.maximumRetainedSessions else { return }
        let candidates = sessions
            .filter { $0.key != protectedThreadID }
            .sorted { $0.value.lastAccess < $1.value.lastAccess }

        for candidate in candidates where sessions.count > Self.maximumRetainedSessions {
            if await candidate.value.session.isIdle {
                if let current = sessions[candidate.key], current.session === candidate.value.session {
                    sessions.removeValue(forKey: candidate.key)
                    await candidate.value.session.shutdown()
                }
            }
        }
    }

    private func scheduleCleanupIfNeeded() {
        guard sessions.count > Self.maximumRetainedSessions, cleanupTask == nil else { return }
        cleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                if await self.cleanupIdleOverflow() { return }
            }
        }
    }

    private func cleanupIdleOverflow() async -> Bool {
        await evictIdleSessionsIfNeeded(excluding: "")
        if sessions.count <= Self.maximumRetainedSessions {
            cleanupTask = nil
            return true
        }
        return false
    }
}

actor CodexUnregisteredSessionLease {
    private var requiresCleanup: Bool
    private let cleanup: @Sendable () async -> Void

    init(isAlreadyTracked: Bool, cleanup: @escaping @Sendable () async -> Void) {
        requiresCleanup = !isAlreadyTracked
        self.cleanup = cleanup
    }

    func markRegistered() {
        requiresCleanup = false
    }

    func cleanupIfNeeded() async {
        guard requiresCleanup else { return }
        requiresCleanup = false
        await cleanup()
    }
}

private actor CodexSession {
    private struct JSONPayload: @unchecked Sendable {
        let value: [String: Any]
    }

    private enum ApprovalResponseID: Sendable {
        case int(Int)
        case string(String)
    }

    private enum ApprovalResponseKind {
        case modern
        case legacy
        case permissions(requested: [String: Any])
    }

    private struct PendingApproval {
        let responseID: ApprovalResponseID
        let kind: ApprovalResponseKind
    }

    private enum PendingUserInputKind {
        case structuredQuestions(questionIDs: [String])
        case mcpForm(fields: [ProviderUserInputQuestion])
        case mcpURL
        case mcpDecision
    }

    private struct PendingUserInput {
        let responseID: ApprovalResponseID
        let kind: PendingUserInputKind
    }

    private let initialResumeThreadID: String?
    private let initialAgentAccess: AgentAccess?
    private let opensConversationThread: Bool
    private var workingDirectory: URL?
    private var developerInstructions: String?
    private let discovery: RuntimeDiscovery
    private var process: Process?
    private var writer: FileHandle?
    private var stderrPipe: Pipe?
    private var stderrCapture: CodexStderrCapture?
    private var stdoutReaderTask: Task<Void, Never>?
    private var serverExecutableURL: URL?
    private var threadID: String?
    private var threadReady = false
    private var serverInitialized = false
    private var nextID: Int = 10
    private var lineBuffer = ProviderJSONLineBuffer(maximumBytes: 64 * 1_024 * 1_024)
    private var startupError: String?

    private var activeContinuation: AsyncThrowingStream<StreamEvent, Error>.Continuation?
    private var activeTurnID: String?
    private var pendingInterrupt = false
    private var lastTurnStartRequestID: Int?
    private var didEmitTurnStarted = false
    private var streamedAgentMessageItemIDs: Set<String> = []
    private var pendingApprovals: [UUID: PendingApproval] = [:]
    private var pendingUserInputs: [UUID: PendingUserInput] = [:]
    private var pendingGoalResponses: [Int: CheckedContinuation<ConversationGoal?, Error>] = [:]
    private var pendingEmptyResponses: [Int: CheckedContinuation<Void, Error>] = [:]
    private var pendingControlTimeoutTasks: [Int: Task<Void, Never>] = [:]
    private var pendingJSONResponses: [Int: CheckedContinuation<JSONPayload, Error>] = [:]
    private var pendingJSONTimeoutTasks: [Int: Task<Void, Never>] = [:]
    private var supportsThreadTurnsList: Bool?
    private var activeAttachments: PreparedProviderAttachments = .empty
    private var activeFollowUpAttachments: [PreparedProviderAttachments] = []
    private var rolloutMetadataStore = CodexRolloutMetadataStore()

    fileprivate static let controlRequestTimeoutSeconds: UInt64 = 30

    init(
        resumeThreadID: String?,
        workingDirectory: URL?,
        systemPrompt: String?,
        agentMode: AgentMode?,
        agentAccess: AgentAccess?,
        discovery: RuntimeDiscovery,
        opensConversationThread: Bool = true
    ) {
        initialResumeThreadID = resumeThreadID
        threadID = resumeThreadID
        initialAgentAccess = agentAccess
        self.workingDirectory = workingDirectory
        self.discovery = discovery
        self.opensConversationThread = opensConversationThread
        developerInstructions = Self.developerInstructions(
            systemPrompt: systemPrompt,
            agentMode: agentMode ?? .auto
        )
    }

    func listNativeThreads(
        workingDirectory: URL,
        limit: Int,
        discoveryMode: ProviderNativeThreadDiscoveryMode = .indexed,
        archived: Bool = false
    ) async throws -> [ProviderNativeThreadSummary] {
        let configuredDirectory = try Self.validatedWorkingDirectory(workingDirectory).standardizedFileURL
        let canonicalDirectory = configuredDirectory.resolvingSymlinksInPath().standardizedFileURL
        let cwdFilters = Array(Set([configuredDirectory.path, canonicalDirectory.path]))
        try await ensureServerInitialized(workingDirectory: canonicalDirectory)

        let boundedLimit = min(max(limit, 1), 500)
        var cursor: String?
        var seenCursors: Set<String> = []
        var results: [ProviderNativeThreadSummary] = []

        repeat {
            let params = Self.nativeThreadListParameters(
                cwdFilters: cwdFilters,
                limit: min(100, boundedLimit - results.count),
                cursor: cursor,
                discoveryMode: discoveryMode,
                archived: archived
            )
            let payload = try await requestJSON(method: "thread/list", params: params)
            let result = payload["result"] as? [String: Any] ?? [:]
            let page = result["data"] as? [[String: Any]] ?? []
            for thread in page {
                if let summary = Self.nativeSummary(
                    from: thread,
                    expectedCanonicalDirectory: canonicalDirectory.path
                ) {
                    results.append(summary)
                    if results.count >= boundedLimit { break }
                }
            }
            let nextCursor = result["nextCursor"] as? String
            guard let nextCursor, !nextCursor.isEmpty, seenCursors.insert(nextCursor).inserted else {
                cursor = nil
                break
            }
            cursor = nextCursor
            if page.isEmpty { break }
        } while cursor != nil && results.count < boundedLimit

        return rolloutMetadataStore.enrich(results)
    }

    fileprivate static func nativeThreadListParameters(
        cwdFilters: [String],
        limit: Int,
        cursor: String?,
        discoveryMode: ProviderNativeThreadDiscoveryMode,
        archived: Bool = false
    ) -> [String: Any] {
        var params: [String: Any] = [
            "cwd": cwdFilters.count == 1 ? (cwdFilters[0] as Any) : cwdFilters,
            "limit": min(max(limit, 1), 100),
            "sortKey": "recency_at",
            "sortDirection": "desc",
            "useStateDbOnly": discoveryMode == .indexed,
        ]
        if archived {
            params["archived"] = true
        }
        if let cursor, !cursor.isEmpty { params["cursor"] = cursor }
        return params
    }

    func archiveNativeThread(id: String, workingDirectory: URL) async throws {
        let canonicalDirectory = try await validatedNativeThreadWorkspace(
            id: id,
            workingDirectory: workingDirectory,
            requireInactive: true
        )
        try await ensureServerInitialized(workingDirectory: canonicalDirectory)
        _ = try await requestJSON(
            method: "thread/archive",
            params: ["threadId": id]
        )
    }

    func unarchiveNativeThread(id: String, workingDirectory: URL) async throws {
        let canonicalDirectory = try await validatedNativeThreadWorkspace(
            id: id,
            workingDirectory: workingDirectory
        )
        try await ensureServerInitialized(workingDirectory: canonicalDirectory)
        _ = try await requestJSON(
            method: "thread/unarchive",
            params: ["threadId": id]
        )
    }

    func renameNativeThread(
        id: String,
        name: String,
        workingDirectory: URL
    ) async throws {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw Self.makeError("A task name is required.")
        }
        let canonicalDirectory = try await validatedNativeThreadWorkspace(
            id: id,
            workingDirectory: workingDirectory
        )
        try await ensureServerInitialized(workingDirectory: canonicalDirectory)
        let request = Self.nativeThreadRenameRequest(
            threadID: id.trimmingCharacters(in: .whitespacesAndNewlines),
            name: normalizedName
        )
        _ = try await requestJSON(method: request.method, params: request.params)
    }

    fileprivate static func nativeThreadRenameRequest(
        threadID: String,
        name: String
    ) -> (method: String, params: [String: Any]) {
        (
            method: "thread/name/set",
            params: [
                "threadId": threadID,
                "name": name,
            ]
        )
    }

    func deleteNativeThread(id: String, workingDirectory: URL) async throws {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonicalDirectory = try await validatedNativeThreadWorkspace(
            id: trimmedID,
            workingDirectory: workingDirectory,
            requireInactive: true
        )
        try await ensureServerInitialized(workingDirectory: canonicalDirectory)
        let request = Self.nativeThreadDeleteRequest(threadID: trimmedID)
        _ = try await requestJSON(method: request.method, params: request.params)
    }

    fileprivate static func nativeThreadDeleteRequest(
        threadID: String
    ) -> (method: String, params: [String: Any]) {
        (
            method: "thread/delete",
            params: ["threadId": threadID]
        )
    }

    private func validatedNativeThreadWorkspace(
        id: String,
        workingDirectory: URL,
        requireInactive: Bool = false
    ) async throws -> URL {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw Self.makeError("A provider thread id is required.")
        }
        let configuredDirectory = try Self.validatedWorkingDirectory(workingDirectory).standardizedFileURL
        let canonicalDirectory = configuredDirectory.resolvingSymlinksInPath().standardizedFileURL
        try await ensureServerInitialized(workingDirectory: canonicalDirectory)
        let payload = try await requestJSON(
            method: "thread/read",
            params: ["threadId": trimmedID, "includeTurns": false]
        )
        let result = payload["result"] as? [String: Any] ?? [:]
        guard let thread = result["thread"] as? [String: Any],
              let summary = Self.nativeSummary(
                from: thread,
                expectedCanonicalDirectory: canonicalDirectory.path
              ) else {
            throw Self.makeError("Codex thread '\(trimmedID)' does not belong to this workspace.")
        }
        if requireInactive, Self.isNativeThreadActive(summary.status) {
            throw Self.makeError("Codex thread '\(trimmedID)' is currently running. Stop it before managing it.")
        }
        return canonicalDirectory
    }

    fileprivate static func isNativeThreadActive(_ status: String?) -> Bool {
        status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "active"
    }

    func readNativeThread(
        id: String,
        workingDirectory: URL?
    ) async throws -> ProviderNativeThread {
        let canonicalDirectory = try workingDirectory.map {
            try Self.validatedWorkingDirectory($0).resolvingSymlinksInPath().standardizedFileURL
        }
        try await ensureServerInitialized(workingDirectory: canonicalDirectory)
        if supportsThreadTurnsList == false {
            return try await readLegacyNativeThread(
                id: id,
                expectedCanonicalDirectory: canonicalDirectory?.path
            )
        }

        let summaryPayload = try await requestJSON(
            method: "thread/read",
            params: ["threadId": id, "includeTurns": false]
        )
        let summaryResult = summaryPayload["result"] as? [String: Any] ?? [:]
        guard let thread = summaryResult["thread"] as? [String: Any],
              let nativeSummary = Self.nativeSummary(
                from: thread,
                expectedCanonicalDirectory: canonicalDirectory?.path
              ) else {
            throw Self.makeError("Codex did not return thread '\(id)' for this workspace.")
        }
        var summary = rolloutMetadataStore.enrich([nativeSummary]).first ?? nativeSummary
        summary = rolloutMetadataStore.enrichUsage(summary)

        let messages: [ConversationMessage]
        do {
            messages = try await readPaginatedNativeTurns(id: id, thread: thread)
            supportsThreadTurnsList = true
        } catch {
            guard Self.isUnavailableMethodError(error) else { throw error }
            // Compatibility only for app-server versions that predate bounded
            // turn pagination. Other failures are surfaced instead of silently
            // loading the complete history.
            supportsThreadTurnsList = false
            return try await readLegacyNativeThread(
                id: id,
                expectedCanonicalDirectory: canonicalDirectory?.path
            )
        }
        return ProviderNativeThread(
            summary: summary,
            messages: messages
        )
    }

    private func readPaginatedNativeTurns(
        id: String,
        thread: [String: Any]
    ) async throws -> [ConversationMessage] {
        let maximumTurns = 128
        let pageSize = 16
        var pages = CodexNativeTurnPageAccumulator(maximumTurns: maximumTurns)
        var cursor: String?
        var messages: [ConversationMessage] = []

        repeat {
            var params: [String: Any] = [
                "threadId": id,
                "limit": min(pageSize, maximumTurns - pages.newestFirstTurns.count),
                "sortDirection": "desc",
                "itemsView": "full",
            ]
            if let cursor { params["cursor"] = cursor }
            let payload = try await requestJSON(method: "thread/turns/list", params: params)
            let result = payload["result"] as? [String: Any] ?? [:]
            let page = result["data"] as? [[String: Any]] ?? []
            cursor = pages.append(page: page, nextCursor: result["nextCursor"] as? String)

            var boundedThread = thread
            boundedThread["turns"] = pages.chronologicalTurns
            messages = Self.nativeMessages(from: boundedThread)
        } while cursor != nil && messages.count < 250

        return messages
    }

    private func readLegacyNativeThread(
        id: String,
        expectedCanonicalDirectory: String?
    ) async throws -> ProviderNativeThread {
        let payload = try await requestJSON(
            method: "thread/read",
            params: ["threadId": id, "includeTurns": true]
        )
        let result = payload["result"] as? [String: Any] ?? [:]
        guard let thread = result["thread"] as? [String: Any],
              let nativeSummary = Self.nativeSummary(
                from: thread,
                expectedCanonicalDirectory: expectedCanonicalDirectory
              ) else {
            throw Self.makeError("Codex did not return thread '\(id)' for this workspace.")
        }
        var summary = rolloutMetadataStore.enrich([nativeSummary]).first ?? nativeSummary
        summary = rolloutMetadataStore.enrichUsage(summary)
        return ProviderNativeThread(summary: summary, messages: Self.nativeMessages(from: thread))
    }

    func startTurn(
        prompt: String,
        attachments: [Attachment] = [],
        model: String?,
        effort: String?,
        workingDirectory: URL?,
        systemPrompt: String?,
        agentMode: AgentMode?,
        agentAccess: AgentAccess?,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws -> String {
        try Task.checkCancellation()
        guard activeContinuation == nil else {
            throw Self.makeError("This Codex session is already running a turn.")
        }
        let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = trimmedModel?.isEmpty == false ? trimmedModel : nil

        let resolvedMode = agentMode ?? .auto
        let resolvedThreadID = try await ensureReady(
            workingDirectory: workingDirectory,
            systemPrompt: systemPrompt,
            agentMode: resolvedMode
        )
        try Task.checkCancellation()
        let preparedAttachments = try ProviderAttachmentStore.prepare(attachments)
        do {
            try Task.checkCancellation()
        } catch {
            preparedAttachments.remove()
            throw error
        }

        activeContinuation = continuation
        activeTurnID = nil
        pendingInterrupt = false
        didEmitTurnStarted = false
        streamedAgentMessageItemIDs.removeAll(keepingCapacity: true)
        continuation.yield(.initialized(sessionID: resolvedThreadID, model: resolvedModel))

        let requestID = nextRequestID()
        lastTurnStartRequestID = requestID

        clearActiveAttachments()
        activeAttachments = preparedAttachments

        var input: [[String: Any]] = []
        for path in preparedAttachments.files {
            input.append([
                "type": "localImage",
                "path": path.path,
            ])
        }
        input.append(["type": "text", "text": prompt])

        var params: [String: Any] = [
            "threadId": resolvedThreadID,
            "input": input,
        ]
        if let agentAccess {
            params["approvalPolicy"] = CodexProvider.codexParams(for: agentAccess).approvalPolicy
            params["sandboxPolicy"] = Self.sandboxPolicy(for: agentAccess, workingDirectory: self.workingDirectory)
        }
        if let resolvedModel {
            params["model"] = resolvedModel
        }

        let normalizedEffort = Self.normalizedEffort(effort)
        if let normalizedEffort {
            params["effort"] = normalizedEffort
        }

        if resolvedMode == .plan {
            params["additionalContext"] = [
                "flowx-plan-mode": [
                    "kind": "application",
                    "value": "Plan the requested work and present the plan for review before making changes or running mutating commands.",
                ],
            ]
        }
        if resolvedMode == .plan, let resolvedModel {
            var collaborationSettings: [String: Any] = [
                "model": resolvedModel,
                "developer_instructions": Self.nonEmpty(systemPrompt) ?? NSNull(),
            ]
            if let normalizedEffort {
                collaborationSettings["reasoning_effort"] = normalizedEffort
            }
            params["collaborationMode"] = [
                "mode": "plan",
                "settings": collaborationSettings,
            ]
        }

        if let workingDirectory = self.workingDirectory?.path, !workingDirectory.isEmpty {
            params["cwd"] = workingDirectory
        }

        do {
            try Task.checkCancellation()
        } catch {
            activeContinuation = nil
            activeTurnID = nil
            pendingInterrupt = false
            lastTurnStartRequestID = nil
            didEmitTurnStarted = false
            clearActiveAttachments()
            throw error
        }
        writeJSON("turn/start", id: requestID, params: params)
        return resolvedThreadID
    }

    func steer(prompt: String, attachments: [Attachment]) async throws {
        try Task.checkCancellation()
        guard activeContinuation != nil,
              let resolvedThreadID = threadID,
              let expectedTurnID = activeTurnID else {
            throw ProviderSteeringError.unavailable(
                "Codex has not started a steerable turn yet, or the active turn has already ended."
            )
        }

        let preparedAttachments = try ProviderAttachmentStore.prepare(attachments)
        var retainedAttachments = false
        defer {
            if !retainedAttachments {
                preparedAttachments.remove()
            }
        }

        let params = Self.turnSteerParameters(
            threadID: resolvedThreadID,
            expectedTurnID: expectedTurnID,
            prompt: prompt,
            imagePaths: preparedAttachments.files
        )
        let payload = try await requestJSON(method: "turn/steer", params: params)
        let result = payload["result"] as? [String: Any]
        guard result?["turnId"] as? String == expectedTurnID else {
            throw ProviderSteeringError.unavailable(
                "Codex did not confirm guidance for the expected active turn."
            )
        }
        guard activeContinuation != nil, activeTurnID == expectedTurnID else {
            throw ProviderSteeringError.unavailable(
                "The Codex turn ended before the guidance could be accepted."
            )
        }

        activeFollowUpAttachments.append(preparedAttachments)
        retainedAttachments = true
    }

    fileprivate static func turnSteerParameters(
        threadID: String,
        expectedTurnID: String,
        prompt: String,
        imagePaths: [URL]
    ) -> [String: Any] {
        var input = imagePaths.map { path in
            [
                "type": "localImage",
                "path": path.path,
            ]
        }
        if !prompt.isEmpty {
            input.append(["type": "text", "text": prompt])
        }
        return [
            "threadId": threadID,
            "expectedTurnId": expectedTurnID,
            "input": input,
        ]
    }

    func setGoal(
        objective: String?,
        status: ConversationGoalStatus?,
        tokenBudget: Int?,
        workingDirectory: URL?,
        systemPrompt: String?
    ) async throws -> ConversationGoal {
        let threadID = try await ensureReady(workingDirectory: workingDirectory, systemPrompt: systemPrompt)
        var params: [String: Any] = ["threadId": threadID]
        if let objective {
            params["objective"] = objective
        }
        if let status {
            params["status"] = status.rawValue
        }
        if let tokenBudget {
            params["tokenBudget"] = tokenBudget
        }

        let goal = try await requestGoal(method: "thread/goal/set", params: params)

        guard let goal else {
            throw Self.makeError("Codex did not return a goal.")
        }
        return goal
    }

    func getGoal(
        workingDirectory: URL?,
        systemPrompt: String?
    ) async throws -> (threadID: String, goal: ConversationGoal?) {
        let threadID = try await ensureReady(workingDirectory: workingDirectory, systemPrompt: systemPrompt)
        let goal = try await requestGoal(
            method: "thread/goal/get",
            params: ["threadId": threadID]
        )

        return (threadID: threadID, goal: goal)
    }

    func clearGoal(
        workingDirectory: URL?,
        systemPrompt: String?
    ) async throws -> String {
        let threadID = try await ensureReady(workingDirectory: workingDirectory, systemPrompt: systemPrompt)
        try await requestEmpty(
            method: "thread/goal/clear",
            params: ["threadId": threadID]
        )

        return threadID
    }

    func compactThread(
        workingDirectory: URL?,
        systemPrompt: String?
    ) async throws -> String {
        let threadID = try await ensureReady(workingDirectory: workingDirectory, systemPrompt: systemPrompt)
        try await requestEmpty(
            method: "thread/compact/start",
            params: ["threadId": threadID]
        )

        return threadID
    }

    func interruptCurrentTurn() {
        guard activeContinuation != nil else { return }
        cancelPendingUserInputs(message: "The FlowX turn was cancelled.")

        if let threadID, let activeTurnID {
            writeJSON("turn/interrupt", id: nextRequestID(), params: [
                "threadId": threadID,
                "turnId": activeTurnID,
            ])
        } else {
            pendingInterrupt = true
        }
    }

    private func ensureServerStarted() async throws {
        if process?.isRunning == true, writer != nil {
            return
        }

        guard let codexURL = await discovery.resolvedPath(for: "codex") else {
            let hint = await discovery.spec(for: "codex")?.installHint ?? "npm install -g @openai/codex"
            throw NSError(domain: "CodexProvider", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Codex CLI not found. Install with: \(hint)",
            ])
        }

        startServer(executableURL: codexURL)

        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            if let startupError {
                throw Self.makeError(startupError)
            }
            if process?.isRunning == true, writer != nil {
                return
            }
        }

        throw NSError(domain: "CodexProvider", code: 1, userInfo: [
            NSLocalizedDescriptionKey: startupError ?? "Codex app-server failed to start.",
        ])
    }

    private func ensureServerInitialized(workingDirectory: URL?) async throws {
        if let workingDirectory {
            self.workingDirectory = workingDirectory
        }
        try await ensureServerStarted()
        for _ in 0..<200 {
            if serverInitialized { return }
            if let startupError {
                let failure = currentStartupFailureMessage(summary: startupError)
                await shutdown()
                throw Self.makeError(failure)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let failure = currentStartupFailureMessage(
            summary: "Codex app-server did not complete initialization."
        )
        await shutdown()
        throw Self.makeError(failure)
    }

    private func requestGoal(method: String, params: [String: Any]) async throws -> ConversationGoal? {
        let requestID = nextRequestID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<ConversationGoal?, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingGoalResponses[requestID] = continuation
                scheduleControlTimeout(id: requestID, method: method)
                writeJSON(method, id: requestID, params: params)
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelControlResponse(id: requestID)
            }
        }
    }

    private func requestEmpty(method: String, params: [String: Any]) async throws {
        let requestID = nextRequestID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingEmptyResponses[requestID] = continuation
                scheduleControlTimeout(id: requestID, method: method)
                writeJSON(method, id: requestID, params: params)
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelControlResponse(id: requestID)
            }
        }
    }

    private func scheduleControlTimeout(id: Int, method: String) {
        pendingControlTimeoutTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.controlRequestTimeoutSeconds))
            guard !Task.isCancelled else { return }
            await self?.timeoutControlResponse(id: id, method: method)
        }
    }

    private func cancelControlResponse(id: Int) {
        pendingControlTimeoutTasks.removeValue(forKey: id)?.cancel()
        if let continuation = pendingGoalResponses.removeValue(forKey: id) {
            continuation.resume(throwing: CancellationError())
        } else if let continuation = pendingEmptyResponses.removeValue(forKey: id) {
            continuation.resume(throwing: CancellationError())
        }
    }

    private func timeoutControlResponse(id: Int, method: String) async {
        pendingControlTimeoutTasks.removeValue(forKey: id)?.cancel()
        let error = Self.makeError("Codex app-server timed out while handling \(method).")
        let didTimeout: Bool
        if let continuation = pendingGoalResponses.removeValue(forKey: id) {
            continuation.resume(throwing: error)
            didTimeout = true
        } else if let continuation = pendingEmptyResponses.removeValue(forKey: id) {
            continuation.resume(throwing: error)
            didTimeout = true
        } else {
            didTimeout = false
        }
        guard didTimeout else { return }
        // A late reply must not collide with a future request using this
        // long-lived app-server session, so reset it after a control timeout.
        await shutdown()
    }

    private func requestJSON(method: String, params: [String: Any]) async throws -> [String: Any] {
        let requestID = nextRequestID()
        let payload = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<JSONPayload, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingJSONResponses[requestID] = continuation
                pendingJSONTimeoutTasks[requestID] = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else { return }
                    await self?.timeoutJSONResponse(id: requestID, method: method)
                }
                writeJSON(method, id: requestID, params: params)
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelJSONResponse(id: requestID)
            }
        }
        return payload.value
    }

    private func cancelJSONResponse(id: Int) {
        pendingJSONTimeoutTasks.removeValue(forKey: id)?.cancel()
        pendingJSONResponses.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func timeoutJSONResponse(id: Int, method: String) async {
        pendingJSONTimeoutTasks.removeValue(forKey: id)?.cancel()
        guard let continuation = pendingJSONResponses.removeValue(forKey: id) else { return }
        continuation.resume(throwing: Self.makeError("Codex app-server timed out while handling \(method)."))
        // A timed-out server may still emit a late response. Restarting gives
        // the native-reader and control paths a clean request namespace.
        await shutdown()
    }

    private func ensureReady(
        workingDirectory: URL?,
        systemPrompt: String?,
        agentMode: AgentMode = .auto
    ) async throws -> String {
        if let workingDirectory {
            self.workingDirectory = try Self.validatedWorkingDirectory(workingDirectory)
        }
        developerInstructions = Self.developerInstructions(systemPrompt: systemPrompt, agentMode: agentMode)

        try await ensureServerStarted()
        return try await ensureThreadReady()
    }

    private func ensureThreadReady() async throws -> String {
        if threadReady, let threadID {
            return threadID
        }

        for _ in 0..<200 {
            try await Task.sleep(for: .milliseconds(50))
            if threadReady, let threadID {
                return threadID
            }
            if let startupError {
                let failure = currentStartupFailureMessage(summary: startupError)
                await shutdown()
                throw Self.makeError(failure)
            }
        }

        let failure = currentStartupFailureMessage(
            summary: "Codex app-server did not make the thread ready."
        )
        await shutdown()
        throw Self.makeError(failure)
    }

    private func nextRequestID() -> Int {
        nextID += 1
        return nextID
    }

    private func startServer(executableURL: URL) {
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stderrCapture = CodexStderrCapture()

        process.executableURL = executableURL
        process.arguments = ["app-server"]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(NSHomeDirectory())/.local/bin",
            environment["PATH"] ?? "",
        ]
        .joined(separator: ":")
        process.environment = environment

        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        lineBuffer.reset(keepingCapacity: true)
        startupError = nil
        threadReady = false
        serverInitialized = false
        writer = stdinPipe.fileHandleForWriting
        self.stderrPipe = stderrPipe
        self.stderrCapture = stderrCapture
        serverExecutableURL = executableURL
        self.process = process

        let outputStream = AsyncStream<Data> { streamContinuation in
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    streamContinuation.finish()
                } else {
                    streamContinuation.yield(data)
                }
            }
            streamContinuation.onTermination = { @Sendable _ in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
            }
        }
        stdoutReaderTask?.cancel()
        stdoutReaderTask = Task { [weak self] in
            guard let self else { return }
            for await data in outputStream {
                guard !Task.isCancelled else { return }
                await self.consume(data: data)
            }
            if !Task.isCancelled {
                await self.handleEOF()
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderrCapture.append(data)
            }
        }

        do {
            try process.run()
        } catch {
            startupError = "Failed to start codex app-server: \(error.localizedDescription)"
            stdoutReaderTask?.cancel()
            stdoutReaderTask = nil
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            self.process = nil
            writer = nil
            self.stderrPipe = nil
            return
        }

        writeJSON("initialize", id: 0, params: [
            "clientInfo": ["name": "FlowX", "version": Self.applicationVersion],
            "capabilities": ["experimentalApi": true],
        ])
    }

    private static var applicationVersion: String {
        let bundle = Bundle.main
        return (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            ?? "development"
    }

    private static func normalizedEffort(_ effort: String?) -> String? {
        guard let effort else { return nil }
        let normalized = effort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func sandboxPolicy(for access: AgentAccess, workingDirectory: URL?) -> [String: Any] {
        switch access {
        case .supervised, .acceptEdits:
            var policy: [String: Any] = [
                "type": "workspaceWrite",
                "networkAccess": false,
                "writableRoots": [],
            ]
            if let workingDirectory {
                policy["writableRoots"] = [workingDirectory.path]
            }
            return policy
        case .fullAccess:
            return ["type": "dangerFullAccess"]
        }
    }

    private static func validatedWorkingDirectory(_ url: URL) throws -> URL {
        let resolved = url.standardizedFileURL
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw makeError("The workspace path does not exist or is not a directory: \(resolved.path)")
        }
        return resolved
    }

    private func consume(data: Data) {
        let output = lineBuffer.append(data)
        guard !output.overflow else {
            let message = "Codex emitted a JSON-RPC message larger than FlowX's 64 MB safety limit. Compact the thread and retry."
            activeContinuation?.yield(.error(message))
            startupError = message
            process?.terminate()
            return
        }
        for line in output.lines { processLine(line) }
    }

    private func handleEOF() {
        if let line = lineBuffer.flush() { processLine(line) }

        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        if let stderrPipe {
            stderrCapture?.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
        }
        let stderrText = stderrCapture?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !serverInitialized, startupError == nil {
            startupError = Self.initializationFailureMessage(
                summary: "Codex app-server exited before initialization completed.",
                executableURL: serverExecutableURL,
                stderr: stderrText,
                terminationStatus: Self.terminationStatus(for: process),
                terminatedBySignal: Self.terminatedBySignal(process),
                isQuarantined: serverExecutableURL.map(Self.isQuarantinedExecutable) ?? false
            )
        }

        if let activeContinuation {
            if let stderrText, !stderrText.isEmpty {
                activeContinuation.yield(.error("Codex app-server exited: \(stderrText)"))
            }
            activeContinuation.finish()
        }

        activeContinuation = nil
        activeTurnID = nil
        lastTurnStartRequestID = nil
        didEmitTurnStarted = false
        streamedAgentMessageItemIDs.removeAll(keepingCapacity: true)
        pendingApprovals.removeAll()
        pendingUserInputs.removeAll()
        failPendingResponses(message: "Codex app-server exited.")
        clearActiveAttachments()
        threadReady = false
        serverInitialized = false
        writer = nil
        stderrPipe = nil
        stderrCapture = nil
        process = nil
        stdoutReaderTask = nil
    }

    private static func terminationStatus(for process: Process?) -> Int32? {
        guard let process, !process.isRunning else { return nil }
        return process.terminationStatus
    }

    private static func terminatedBySignal(_ process: Process?) -> Bool {
        guard let process, !process.isRunning else { return false }
        return process.terminationReason == .uncaughtSignal
    }

    private static func isQuarantinedExecutable(_ url: URL) -> Bool {
        let executableURL = url.resolvingSymlinksInPath()
        let values = try? executableURL.resourceValues(forKeys: [.quarantinePropertiesKey])
        return values?.quarantineProperties != nil
    }

    private func currentStartupFailureMessage(summary: String) -> String {
        Self.initializationFailureMessage(
            summary: summary,
            executableURL: serverExecutableURL,
            stderr: stderrCapture?.text,
            terminationStatus: Self.terminationStatus(for: process),
            terminatedBySignal: Self.terminatedBySignal(process),
            isQuarantined: serverExecutableURL.map(Self.isQuarantinedExecutable) ?? false
        )
    }

    fileprivate static func initializationFailureMessage(
        summary: String,
        executableURL: URL?,
        stderr: String?,
        terminationStatus: Int32?,
        terminatedBySignal: Bool,
        isQuarantined: Bool
    ) -> String {
        let path = executableURL?.path
        var details: [String] = [summary]

        if isQuarantined, let path {
            details.append(
                "macOS may have blocked the quarantined Codex executable at '\(path)'. "
                    + "Resolve the macOS security warning or reinstall Codex, then retry; "
                    + "FlowX does not bypass Gatekeeper or remove quarantine attributes."
            )
        } else if let path {
            details.append("Executable: \(path).")
        }

        if let terminationStatus {
            if terminatedBySignal {
                details.append("The process was terminated by signal \(terminationStatus).")
            } else {
                details.append("The process exited with status \(terminationStatus).")
            }
        }

        let stderr = stderr?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let stderr, !stderr.isEmpty {
            let maximumScalars = 4_096
            let bounded = stderr.unicodeScalars.count > maximumScalars
                ? String(stderr.unicodeScalars.suffix(maximumScalars))
                : stderr
            details.append("Codex reported: \(bounded)")
        }

        return details.joined(separator: " ")
    }

    private func processLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let method = json["method"] as? String {
            let params = json["params"] as? [String: Any] ?? [:]
            if let responseID = Self.approvalResponseID(from: json["id"]),
               handleServerRequest(method: method, params: params, responseID: responseID) {
                return
            }

            handleNotification(method: method, params: params)
            return
        }

        if let responseID = json["id"] as? Int {
            handleResponse(id: responseID, payload: json)
        }
    }

    private func handleResponse(id: Int, payload: [String: Any]) {
        if let error = payload["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Unknown Codex error"
            let rpcError = NSError(
                domain: "CodexProvider.JSONRPC",
                code: Self.intValue(for: error["code"]) ?? 10,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
            if failPendingResponse(id: id, error: rpcError) {
                return
            }
            if id == 0 || id == 1 {
                startupError = message
            } else {
                activeContinuation?.yield(.error(message))
                if id == lastTurnStartRequestID {
                    activeContinuation?.finish()
                    activeContinuation = nil
                    activeTurnID = nil
                    pendingInterrupt = false
                    lastTurnStartRequestID = nil
                    clearActiveAttachments()
                }
            }
            return
        }

        if completePendingGoalResponse(id: id, payload: payload) {
            return
        }

        if completePendingEmptyResponse(id: id) {
            return
        }

        if let continuation = pendingJSONResponses.removeValue(forKey: id) {
            pendingJSONTimeoutTasks.removeValue(forKey: id)?.cancel()
            continuation.resume(returning: JSONPayload(value: payload))
            return
        }

        if id == 0 {
            writeNotification("initialized", params: [:])
            serverInitialized = true
            if opensConversationThread {
                startOrResumeThread()
            }
            return
        }

        if id == 1,
           let result = payload["result"] as? [String: Any],
           let thread = result["thread"] as? [String: Any],
           let resolvedThreadID = thread["id"] as? String {
            threadID = resolvedThreadID
            startupError = nil
            threadReady = true
            return
        }

        if id == lastTurnStartRequestID,
           let result = payload["result"] as? [String: Any],
           let turn = result["turn"] as? [String: Any],
           let turnID = turn["id"] as? String {
            activeTurnID = turnID
            emitTurnStartedIfNeeded(turnID: turnID)
            if pendingInterrupt {
                interruptCurrentTurn()
            }
        }
    }

    private func handleServerRequest(
        method: String,
        params: [String: Any],
        responseID: ApprovalResponseID
    ) -> Bool {
        let approvalKind: ApprovalResponseKind?
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            approvalKind = .modern
        case "execCommandApproval", "applyPatchApproval":
            approvalKind = .legacy
        case "item/permissions/requestApproval":
            approvalKind = .permissions(requested: params["permissions"] as? [String: Any] ?? [:])
        default:
            approvalKind = nil
        }

        if let approvalKind {
            guard activeContinuation != nil else {
                writeApprovalResponse(responseID, kind: approvalKind, approved: false)
                return true
            }
            guard let approvalRequest = makeApprovalRequest(
                method: method,
                params: params,
                responseID: responseID,
                kind: approvalKind
            ) else {
                writeApprovalResponse(responseID, kind: approvalKind, approved: false)
                return true
            }
            activeContinuation?.yield(.approvalRequest(approvalRequest))
            return true
        }

        switch method {
        case "currentTime/read":
            writeResponse(responseID, result: ["currentTimeAt": Int(Date().timeIntervalSince1970)])
            return true
        case "item/tool/call":
            let tool = params["tool"] as? String ?? "dynamic tool"
            activeContinuation?.yield(.toolResult(
                id: params["callId"] as? String ?? "dynamic-tool",
                content: "FlowX does not provide the requested dynamic tool '\(tool)'.",
                isError: true
            ))
            writeResponse(responseID, result: [
                "success": false,
                "contentItems": [[
                    "type": "inputText",
                    "text": "FlowX does not provide the requested dynamic tool '\(tool)'.",
                ]],
            ])
            return true
        case "item/tool/requestUserInput":
            guard activeContinuation != nil else {
                writeError(responseID, code: -32000, message: "No active FlowX turn can collect user input.")
                return true
            }
            guard let request = Self.userInputRequest(from: params) else {
                writeError(responseID, code: -32602, message: "Codex sent an invalid structured user-input request.")
                return true
            }
            pendingUserInputs[request.id] = PendingUserInput(
                responseID: responseID,
                kind: .structuredQuestions(questionIDs: request.questions.map(\.id))
            )
            activeContinuation?.yield(.userInputRequest(request))
            return true
        case "mcpServer/elicitation/request":
            guard activeContinuation != nil else {
                writeResponse(responseID, result: ["action": "cancel"])
                return true
            }
            let request = Self.mcpUserInputRequest(from: params)
            let pendingKind: PendingUserInputKind
            switch request.presentation {
            case .form:
                pendingKind = .mcpForm(fields: request.questions)
            case .externalURL:
                pendingKind = .mcpURL
            case .decision:
                pendingKind = .mcpDecision
            }
            pendingUserInputs[request.id] = PendingUserInput(
                responseID: responseID,
                kind: pendingKind
            )
            activeContinuation?.yield(.userInputRequest(request))
            return true
        case "account/chatgptAuthTokens/refresh", "attestation/generate":
            writeError(responseID, code: -32601, message: "FlowX cannot service \(method).")
            return true
        default:
            return false
        }
    }

    private func handleNotification(method: String, params: [String: Any]) {
        switch method {
        case "turn/started":
            if let turn = params["turn"] as? [String: Any],
               let turnID = turn["id"] as? String {
                activeTurnID = turnID
                emitTurnStartedIfNeeded(turnID: turnID)
                if pendingInterrupt {
                    interruptCurrentTurn()
                }
            }

        case "item/agentMessage/delta":
            if let delta = params["delta"] as? String {
                if let itemID = params["itemId"] as? String {
                    streamedAgentMessageItemIDs.insert(itemID)
                }
                activeContinuation?.yield(.textDelta(delta))
            }

        case "item/started":
            if let item = params["item"] as? [String: Any] {
                let type = item["type"] as? String ?? ""
                if type == "contextCompaction" {
                    activeContinuation?.yield(.lifecycle(.phaseChanged(.compacting)))
                } else if Self.toolItemTypes.contains(type) {
                    let command = item["command"] as? String
                    let name = Self.toolName(from: item, type: type, command: command)
                    let input = Self.toolInput(from: item, command: command)
                    activeContinuation?.yield(.toolUse(id: item["id"] as? String ?? "", name: name, input: input))
                }
            }

        case "item/completed":
            if let item = params["item"] as? [String: Any] {
                let type = item["type"] as? String ?? ""
                if type == "contextCompaction" {
                    activeContinuation?.yield(.lifecycle(.phaseChanged(.compacted)))
                } else if type == "agentMessage",
                          let itemID = item["id"] as? String,
                          !streamedAgentMessageItemIDs.contains(itemID),
                          let text = item["text"] as? String,
                          !text.isEmpty {
                    activeContinuation?.yield(.text(text))
                } else if Self.toolItemTypes.contains(type) {
                    let status = item["status"] as? String ?? "completed"
                    activeContinuation?.yield(.toolResult(
                        id: item["id"] as? String ?? "",
                        content: Self.toolOutput(from: item),
                        isError: status == "failed"
                    ))
                }
            }

        case "model/rerouted":
            if let model = params["toModel"] as? String {
                activeContinuation?.yield(.modelChanged(model: model, reason: params["reason"] as? String))
            }

        case "error":
            let error = params["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "Unknown Codex error"
            if params["willRetry"] as? Bool == true {
                activeContinuation?.yield(.lifecycle(.phaseChanged(.preparing)))
            } else {
                activeContinuation?.yield(.error(message))
            }

        case "thread/tokenUsage/updated":
            if let usage = params["tokenUsage"] as? [String: Any] {
                let contextWindow = usage["modelContextWindow"] as? Int

                if let last = usage["last"] as? [String: Any] {
                    activeContinuation?.yield(.contextUsage(
                        inputTokens: last["inputTokens"] as? Int ?? 0,
                        outputTokens: last["outputTokens"] as? Int ?? 0,
                        cachedInputTokens: last["cachedInputTokens"] as? Int ?? 0,
                        reasoningOutputTokens: last["reasoningOutputTokens"] as? Int ?? 0,
                        totalTokens: last["totalTokens"] as? Int ?? 0,
                        contextWindow: contextWindow
                    ))
                }

                if let total = usage["total"] as? [String: Any] {
                    activeContinuation?.yield(.usageTotal(
                        inputTokens: total["inputTokens"] as? Int ?? 0,
                        outputTokens: total["outputTokens"] as? Int ?? 0,
                        cachedInputTokens: total["cachedInputTokens"] as? Int ?? 0,
                        reasoningOutputTokens: total["reasoningOutputTokens"] as? Int ?? 0,
                        totalTokens: total["totalTokens"] as? Int ?? 0,
                        contextWindow: contextWindow
                    ))
                }
            }

        case "thread/compacted":
            activeContinuation?.yield(.lifecycle(.phaseChanged(.compacted)))

        case "thread/goal/updated":
            if let goal = Self.goal(from: params["goal"] as? [String: Any]) {
                activeContinuation?.yield(.goalUpdated(goal))
            }

        case "thread/goal/cleared":
            activeContinuation?.yield(.goalUpdated(nil))

        case "thread/status/changed":
            let compactStatus = compactStatus(from: params)
            if compactStatus == "compacting" {
                activeContinuation?.yield(.lifecycle(.phaseChanged(.compacting)))
            } else if compactStatus == "compacted" {
                activeContinuation?.yield(.lifecycle(.phaseChanged(.compacted)))
            }

            if let status = params["status"] as? [String: Any],
               status["type"] as? String == "systemError" {
                activeContinuation?.yield(.error("Codex thread entered a system error state."))
            }

        case "turn/completed":
            let turn = params["turn"] as? [String: Any]
            let stopReason = turn?["status"] as? String ?? "end_turn"
            let failed = stopReason == "failed"
            if failed {
                let error = turn?["error"] as? [String: Any]
                activeContinuation?.yield(.error(
                    error?["message"] as? String ?? "Codex failed to complete the turn."
                ))
            }

            if !failed {
                activeContinuation?.yield(.done(stopReason: stopReason))
            }
            activeContinuation?.finish()
            activeContinuation = nil
            activeTurnID = nil
            pendingInterrupt = false
            lastTurnStartRequestID = nil
            didEmitTurnStarted = false
            pendingApprovals.removeAll()
            cancelPendingUserInputs(message: "The Codex turn ended before user input was submitted.")
            streamedAgentMessageItemIDs.removeAll(keepingCapacity: true)
            clearActiveAttachments()

        default:
            break
        }
    }

    private func completePendingGoalResponse(id: Int, payload: [String: Any]) -> Bool {
        guard let continuation = pendingGoalResponses.removeValue(forKey: id) else { return false }
        pendingControlTimeoutTasks.removeValue(forKey: id)?.cancel()

        let result = payload["result"] as? [String: Any]
        let goal = Self.goal(from: result?["goal"] as? [String: Any])
        continuation.resume(returning: goal)
        return true
    }

    private func completePendingEmptyResponse(id: Int) -> Bool {
        guard let continuation = pendingEmptyResponses.removeValue(forKey: id) else { return false }
        pendingControlTimeoutTasks.removeValue(forKey: id)?.cancel()
        continuation.resume()
        return true
    }

    @discardableResult
    private func failPendingResponse(id: Int, error: Error) -> Bool {
        if let continuation = pendingGoalResponses.removeValue(forKey: id) {
            pendingControlTimeoutTasks.removeValue(forKey: id)?.cancel()
            continuation.resume(throwing: error)
            return true
        }

        if let continuation = pendingEmptyResponses.removeValue(forKey: id) {
            pendingControlTimeoutTasks.removeValue(forKey: id)?.cancel()
            continuation.resume(throwing: error)
            return true
        }

        if let continuation = pendingJSONResponses.removeValue(forKey: id) {
            pendingJSONTimeoutTasks.removeValue(forKey: id)?.cancel()
            continuation.resume(throwing: error)
            return true
        }

        return false
    }

    private func failPendingResponses(message: String) {
        let error = Self.makeError(message)
        for continuation in pendingGoalResponses.values {
            continuation.resume(throwing: error)
        }
        pendingGoalResponses.removeAll()

        for continuation in pendingEmptyResponses.values {
            continuation.resume(throwing: error)
        }
        pendingEmptyResponses.removeAll()
        for task in pendingControlTimeoutTasks.values { task.cancel() }
        pendingControlTimeoutTasks.removeAll()

        for continuation in pendingJSONResponses.values {
            continuation.resume(throwing: error)
        }
        pendingJSONResponses.removeAll()
        for task in pendingJSONTimeoutTasks.values { task.cancel() }
        pendingJSONTimeoutTasks.removeAll()
    }

    private func emitTurnStartedIfNeeded(turnID: String?) {
        guard !didEmitTurnStarted else { return }
        didEmitTurnStarted = true
        activeContinuation?.yield(.lifecycle(.turnStarted(turnID: turnID)))
    }

    private func compactStatus(from params: [String: Any]) -> String? {
        if let status = params["status"] as? String {
            return normalizeCompactStatus(status)
        }

        if let status = params["status"] as? [String: Any] {
            for key in ["type", "state", "status"] {
                if let value = status[key] as? String,
                   let normalized = normalizeCompactStatus(value) {
                    return normalized
                }
            }
        }

        if let thread = params["thread"] as? [String: Any] {
            for key in ["state", "status"] {
                if let value = thread[key] as? String,
                   let normalized = normalizeCompactStatus(value) {
                    return normalized
                }
            }
        }

        for key in ["state", "type"] {
            if let value = params[key] as? String,
               let normalized = normalizeCompactStatus(value) {
                return normalized
            }
        }

        return nil
    }

    private func normalizeCompactStatus(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("compacting") {
            return "compacting"
        }
        if normalized.contains("compacted") || normalized == "compact_boundary" {
            return "compacted"
        }
        return nil
    }

    private static func developerInstructions(systemPrompt: String?, agentMode: AgentMode) -> String {
        systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    fileprivate static func nativeSummary(
        from thread: [String: Any],
        expectedCanonicalDirectory: String?
    ) -> ProviderNativeThreadSummary? {
        guard let id = thread["id"] as? String,
              let cwd = thread["cwd"] as? String,
              let createdAt = intValue(for: thread["createdAt"]),
              let updatedAt = intValue(for: thread["recencyAt"] ?? thread["updatedAt"]) else {
            return nil
        }

        let canonicalCWD = URL(fileURLWithPath: cwd)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        if let expectedCanonicalDirectory, canonicalCWD != expectedCanonicalDirectory {
            return nil
        }

        let preview = (thread["preview"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitName = (thread["name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let titleSource = explicitName?.isEmpty == false ? explicitName! : preview
        let title = titleSource
            .split(whereSeparator: \.isNewline)
            .first
            .map { String($0.prefix(100)) }
            ?? "Codex thread"
        let configuration = CodexNativeConfiguration.parse(thread)

        return ProviderNativeThreadSummary(
            providerID: "codex",
            id: id,
            title: title,
            preview: String(preview.prefix(500)),
            workingDirectory: canonicalCWD,
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(updatedAt)),
            model: configuration.model,
            effort: configuration.effort,
            agentMode: configuration.agentMode,
            agentAccess: configuration.agentAccess,
            status: statusString(thread["status"]),
            source: statusString(thread["source"]) ?? "codex"
        )
    }

    fileprivate static func nativeMessages(from thread: [String: Any]) -> [ConversationMessage] {
        var messages: [ConversationMessage] = []
        var remainingImageBytes = ProviderNativeImageImporter.maximumTranscriptImageBytes
        let threadID = thread["id"] as? String ?? "codex-thread"
        for (turnIndex, turn) in (thread["turns"] as? [[String: Any]] ?? []).enumerated() {
            let turnID = turn["id"] as? String ?? "turn-\(turnIndex)"
            let startedAt = intValue(for: turn["startedAt"])
                .map { Date(timeIntervalSince1970: TimeInterval($0)) }
                ?? Date.distantPast
            let completedAt = intValue(for: turn["completedAt"])
                .map { Date(timeIntervalSince1970: TimeInterval($0)) }
                ?? startedAt

            for (itemIndex, item) in (turn["items"] as? [[String: Any]] ?? []).enumerated() {
                let type = item["type"] as? String ?? "unknown"
                let itemID = item["id"] as? String ?? "item-\(itemIndex)"
                let identityKey = "\(threadID)|\(turnID)|\(itemID)|\(type)|\(itemIndex)"
                let nativeID = UUID(uuidString: itemID) ?? deterministicUUID(identityKey)
                switch type {
                case "userMessage":
                    var contents: [MessageContent] = []
                    for content in item["content"] as? [[String: Any]] ?? [] {
                        switch content["type"] as? String {
                        case "text":
                            if let text = content["text"] as? String, !text.isEmpty {
                                contents.append(.text(
                                    boundedNativePayload(text, maximum: 256 * 1_024)
                                ))
                            }
                        case "image":
                            guard let url = content["url"] as? String,
                                  let image = ProviderNativeImageImporter.dataURL(
                                      url,
                                      remainingBytes: &remainingImageBytes
                                  ) else {
                                continue
                            }
                            contents.append(image)
                        case "localImage":
                            guard let path = content["path"] as? String,
                                  let image = ProviderNativeImageImporter.localFile(
                                      atPath: path,
                                      remainingBytes: &remainingImageBytes
                                  ) else {
                                continue
                            }
                            contents.append(image)
                        default:
                            continue
                        }
                    }
                    if !contents.isEmpty {
                        messages.append(ConversationMessage(
                            id: nativeID,
                            role: .user,
                            content: contents,
                            timestamp: startedAt
                        ))
                    }
                case "agentMessage":
                    if let text = item["text"] as? String, !text.isEmpty {
                        messages.append(ConversationMessage(
                            id: nativeID,
                            role: .assistant,
                            content: [.text(boundedNativePayload(text, maximum: 256 * 1_024))],
                            timestamp: completedAt
                        ))
                    }
                case "reasoning", "plan", "contextCompaction", "hookPrompt",
                     "subAgentActivity", "enteredReviewMode", "exitedReviewMode":
                    continue
                default:
                    guard toolItemTypes.contains(type) || looksLikeToolItem(item) else {
                        continue
                    }
                    let command = item["command"] as? String
                    let name = toolName(from: item, type: type, command: command)
                    let input = boundedNativePayload(toolInput(from: item, command: command), maximum: 32_768)
                    messages.append(ConversationMessage(
                        id: nativeID,
                        role: .assistant,
                        content: [.toolUse(id: item["id"] as? String ?? nativeID.uuidString, name: name, input: input)],
                        timestamp: startedAt
                    ))
                    let output = toolOutput(from: item)
                    if output != "Completed" {
                        messages.append(ConversationMessage(
                            id: deterministicUUID(identityKey + "|result"),
                            role: .tool,
                            content: [.toolResult(
                                id: item["id"] as? String ?? nativeID.uuidString,
                                content: boundedNativePayload(output, maximum: 65_536),
                                isError: statusString(item["status"]) == "failed"
                            )],
                            timestamp: completedAt
                        ))
                    }
                }
            }
        }
        return Array(messages.suffix(250))
    }

    private static func statusString(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let dictionary = value as? [String: Any] {
            return firstNonEmptyString(from: dictionary, keys: ["type", "status", "state"])
                ?? stringValue(for: dictionary)
        }
        return stringValue(for: value)
    }

    private static func boundedNativePayload(_ value: String, maximum: Int) -> String {
        guard value.utf8.count > maximum else { return value }
        var bytes = 0
        var end = value.startIndex
        while end < value.endIndex {
            let next = value.index(after: end)
            let characterBytes = value[end..<next].utf8.count
            guard bytes + characterBytes <= maximum else { break }
            bytes += characterBytes
            end = next
        }
        return String(value[..<end]) + "\n… [historic provider payload truncated]"
    }

    private static func deterministicUUID(_ key: String) -> UUID {
        var first: UInt64 = 0xcbf29ce484222325
        var second: UInt64 = 0x9e3779b97f4a7c15
        for byte in key.utf8 {
            first ^= UInt64(byte)
            first &*= 0x100000001b3
            second ^= UInt64(byte) &+ 0x9d
            second = (second << 7) | (second >> 57)
            second &*= 0x100000001b3
        }
        let raw = String(format: "%016llx%016llx", first, second)
        let p1 = raw.prefix(8)
        let p2 = raw.dropFirst(8).prefix(4)
        let p3 = "5" + raw.dropFirst(13).prefix(3)
        let p4 = "8" + raw.dropFirst(17).prefix(3)
        let p5 = raw.dropFirst(20).prefix(12)
        return UUID(uuidString: "\(p1)-\(p2)-\(p3)-\(p4)-\(p5)")!
    }

    private static func goal(from payload: [String: Any]?) -> ConversationGoal? {
        guard let payload,
              let threadID = payload["threadId"] as? String,
              let objective = payload["objective"] as? String,
              let statusRaw = payload["status"] as? String else {
            return nil
        }

        return ConversationGoal(
            threadID: threadID,
            objective: objective,
            status: ConversationGoalStatus(rawValue: statusRaw) ?? .active,
            tokensUsed: intValue(for: payload["tokensUsed"]) ?? 0,
            tokenBudget: intValue(for: payload["tokenBudget"]),
            timeUsedSeconds: intValue(for: payload["timeUsedSeconds"]) ?? 0,
            createdAt: intValue(for: payload["createdAt"]) ?? 0,
            updatedAt: intValue(for: payload["updatedAt"]) ?? 0
        )
    }

    private static func intValue(for rawValue: Any?) -> Int? {
        switch rawValue {
        case let value as Int:
            value
        case let value as NSNumber:
            value.intValue
        default:
            nil
        }
    }

    private static func makeError(_ message: String) -> NSError {
        NSError(domain: "CodexProvider", code: 10, userInfo: [
            NSLocalizedDescriptionKey: message,
        ])
    }

    private static func isUnavailableMethodError(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == "CodexProvider.JSONRPC", error.code == -32601 {
            return true
        }
        let message = error.localizedDescription.lowercased()
        return message.contains("method not found")
            || message.contains("unsupported method")
            || message.contains("unknown method")
            || message.contains("not implemented")
    }

    private static func toolInput(from item: [String: Any], command: String?) -> String {
        if let input = item["input"] ?? item["arguments"],
           let inputString = stringValue(for: input) {
            return inputString
        }

        guard let command, !command.isEmpty else { return "" }
        let payload = ["command": command]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let input = String(data: data, encoding: .utf8) else {
            return command
        }
        return input
    }

    private static let toolItemTypes: Set<String> = [
        "toolCall",
        "commandExecution",
        "fileChange",
        "mcpToolCall",
        "dynamicToolCall",
        "collabAgentToolCall",
        "webSearch",
        "imageView",
        "imageGeneration",
        "sleep",
    ]

    private static func looksLikeToolItem(_ item: [String: Any]) -> Bool {
        ["name", "tool", "command", "input", "arguments", "output", "result", "error", "changes"]
            .contains { item[$0] != nil }
    }

    private static func toolName(from item: [String: Any], type: String, command: String?) -> String {
        if let name = firstNonEmptyString(from: item, keys: ["name", "tool", "server", "query"]) {
            return name
        }
        if command != nil { return "Command" }
        return switch type {
        case "fileChange": "File change"
        case "mcpToolCall": "MCP tool"
        case "dynamicToolCall": "Dynamic tool"
        case "collabAgentToolCall": "Agent"
        case "webSearch": "Web search"
        case "imageView": "View image"
        case "imageGeneration": "Image generation"
        case "sleep": "Wait"
        default: type
        }
    }

    private static func toolOutput(from item: [String: Any]) -> String {
        for key in ["aggregatedOutput", "output", "result", "error", "changes"] {
            if let output = stringValue(for: item[key]) {
                return output
            }
        }
        return "Completed"
    }

    private func startOrResumeThread() {
        let threadToResume = threadID ?? initialResumeThreadID

        if let threadToResume {
            var params: [String: Any] = [
                "threadId": threadToResume,
            ]

            if let initialAgentAccess {
                let access = CodexProvider.codexParams(for: initialAgentAccess)
                params["approvalPolicy"] = access.approvalPolicy
                params["sandbox"] = access.sandbox
            }

            if let developerInstructions, !developerInstructions.isEmpty {
                params["developerInstructions"] = developerInstructions
            }

            if let workingDirectory = workingDirectory?.path, !workingDirectory.isEmpty {
                params["cwd"] = workingDirectory
            }

            writeJSON("thread/resume", id: 1, params: params)
            return
        }

        var params: [String: Any] = [:]

        if let initialAgentAccess {
            let access = CodexProvider.codexParams(for: initialAgentAccess)
            params["approvalPolicy"] = access.approvalPolicy
            params["sandbox"] = access.sandbox
        }

        if let developerInstructions, !developerInstructions.isEmpty {
            params["developerInstructions"] = developerInstructions
        }

        if let workingDirectory = workingDirectory?.path, !workingDirectory.isEmpty {
            params["cwd"] = workingDirectory
        }

        writeJSON("thread/start", id: 1, params: params)
    }

    func respondToApproval(_ approvalID: UUID, approved: Bool) {
        guard let pending = pendingApprovals.removeValue(forKey: approvalID) else { return }
        writeApprovalResponse(pending.responseID, kind: pending.kind, approved: approved)
    }

    func respondToUserInput(_ requestID: UUID, answers: ProviderUserInputAnswers) {
        guard let pending = pendingUserInputs[requestID] else { return }

        switch pending.kind {
        case .structuredQuestions(let questionIDs):
            pendingUserInputs.removeValue(forKey: requestID)
            writeResponse(
                pending.responseID,
                result: Self.userInputResponse(questionIDs: questionIDs, answers: answers)
            )

        case .mcpForm(let fields):
            guard let content = Self.mcpFormContent(fields: fields, answers: answers) else {
                pendingUserInputs.removeValue(forKey: requestID)
                activeContinuation?.yield(.error("The MCP form response is incomplete or contains an invalid value."))
                writeResponse(pending.responseID, result: ["action": "cancel"])
                return
            }
            pendingUserInputs.removeValue(forKey: requestID)
            writeResponse(pending.responseID, result: [
                "action": "accept",
                "content": content,
            ])

        case .mcpURL:
            pendingUserInputs.removeValue(forKey: requestID)
            writeResponse(pending.responseID, result: ["action": "accept"])

        case .mcpDecision:
            pendingUserInputs.removeValue(forKey: requestID)
            writeResponse(pending.responseID, result: ["action": "decline"])
        }
    }

    func cancelUserInput(_ requestID: UUID) {
        guard let pending = pendingUserInputs.removeValue(forKey: requestID) else { return }
        switch pending.kind {
        case .structuredQuestions:
            writeError(pending.responseID, code: -32800, message: "The user cancelled the input request.")
        case .mcpForm, .mcpURL, .mcpDecision:
            writeResponse(pending.responseID, result: ["action": "cancel"])
        }
    }

    fileprivate static func userInputRequest(from params: [String: Any]) -> ProviderUserInputRequest? {
        let rawQuestions = params["questions"] as? [[String: Any]] ?? []
        var seenIDs: Set<String> = []
        let questions = rawQuestions.prefix(3).compactMap { question -> ProviderUserInputQuestion? in
            guard let id = nonEmpty(question["id"] as? String), id.utf8.count <= 1_024,
                  seenIDs.insert(id).inserted,
                  let prompt = nonEmpty(question["question"] as? String),
                  let header = nonEmpty(question["header"] as? String) else {
                return nil
            }
            let options = (question["options"] as? [[String: Any]] ?? [])
                .prefix(10)
                .compactMap { option -> ProviderUserInputOption? in
                    guard let label = nonEmpty(option["label"] as? String) else { return nil }
                    return ProviderUserInputOption(
                        label: boundedNativePayload(label, maximum: 256),
                        description: boundedNativePayload(option["description"] as? String ?? "", maximum: 2_048)
                    )
                }
            return ProviderUserInputQuestion(
                id: id,
                header: boundedNativePayload(header, maximum: 256),
                question: boundedNativePayload(prompt, maximum: 8_192),
                options: options,
                allowsOther: question["isOther"] as? Bool ?? false,
                isSecret: question["isSecret"] as? Bool ?? false
            )
        }
        guard !questions.isEmpty else { return nil }
        let automaticMilliseconds = intValue(for: params["autoResolutionMs"])
            .flatMap { $0 >= 0 ? UInt64($0) : nil }
        return ProviderUserInputRequest(
            questions: questions,
            autoResolutionMilliseconds: automaticMilliseconds
        )
    }

    fileprivate static func userInputResponse(
        questionIDs: [String],
        answers: ProviderUserInputAnswers
    ) -> [String: Any] {
        var responseAnswers: [String: Any] = [:]
        for questionID in questionIDs {
            let values = Array((answers[questionID] ?? [])
                .prefix(10)
                .map { boundedNativePayload($0, maximum: 65_536) })
            responseAnswers[questionID] = ["answers": values]
        }
        return ["answers": responseAnswers]
    }

    fileprivate static func mcpFormRequest(from params: [String: Any]) -> ProviderUserInputRequest? {
        guard params["mode"] as? String == "form",
              let schema = params["requestedSchema"] as? [String: Any],
              schema["type"] as? String == "object",
              let properties = schema["properties"] as? [String: Any],
              properties.count <= 64 else {
            return nil
        }

        if let rawRequired = schema["required"],
           !(rawRequired is NSNull),
           !(rawRequired is [String]) {
            return nil
        }
        let requiredValues = schema["required"] as? [String] ?? []
        guard requiredValues.count <= properties.count else { return nil }
        let required = Set(requiredValues)
        guard required.count == requiredValues.count,
              required.allSatisfy({ properties[$0] != nil }) else {
            return nil
        }

        var fields: [ProviderUserInputQuestion] = []
        fields.reserveCapacity(properties.count)
        for propertyName in properties.keys.sorted() {
            guard propertyName.utf8.count <= 1_024,
                  let property = properties[propertyName] as? [String: Any],
                  let field = mcpFormField(
                    name: propertyName,
                    schema: property,
                    required: required.contains(propertyName)
                  ) else {
                return nil
            }
            fields.append(field)
        }

        let server = boundedNativePayload(
            nonEmpty(params["serverName"] as? String) ?? "MCP server",
            maximum: 256
        )
        let message = boundedNativePayload(
            nonEmpty(params["message"] as? String) ?? "This MCP server requested additional input.",
            maximum: 8_192
        )
        return ProviderUserInputRequest(
            questions: fields,
            title: "\(server) needs input",
            message: message,
            presentation: .form,
            cancellationBehavior: .respondToProvider
        )
    }

    fileprivate static func mcpURLRequest(from params: [String: Any]) -> ProviderUserInputRequest? {
        guard params["mode"] as? String == "url",
              nonEmpty(params["elicitationId"] as? String) != nil,
              let rawURL = nonEmpty(params["url"] as? String),
              rawURL.utf8.count <= 8_192,
              let components = URLComponents(string: rawURL),
              components.scheme?.lowercased() == "https",
              nonEmpty(components.host) != nil,
              components.user == nil,
              components.password == nil,
              let safeURL = components.url?.absoluteString else {
            return nil
        }

        let server = boundedNativePayload(
            nonEmpty(params["serverName"] as? String) ?? "MCP server",
            maximum: 256
        )
        let message = boundedNativePayload(
            nonEmpty(params["message"] as? String) ?? "Complete the requested step in your browser, then return to FlowX.",
            maximum: 8_192
        )
        return ProviderUserInputRequest(
            questions: [],
            title: "\(server) needs confirmation",
            message: message,
            presentation: .externalURL(safeURL),
            cancellationBehavior: .respondToProvider
        )
    }

    fileprivate static func mcpDecisionRequest(
        from params: [String: Any],
        detail: String
    ) -> ProviderUserInputRequest {
        let server = boundedNativePayload(
            nonEmpty(params["serverName"] as? String) ?? "MCP server",
            maximum: 256
        )
        let providerMessage = nonEmpty(params["message"] as? String).map {
            boundedNativePayload($0, maximum: 8_192)
        }
        let boundedDetail = boundedNativePayload(detail, maximum: 8_192)
        let message = [providerMessage, boundedDetail]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        return ProviderUserInputRequest(
            questions: [],
            title: "\(server) needs a decision",
            message: "\(message)\n\nNo response will be sent until you choose an action.",
            presentation: .decision(actionLabel: "Decline request"),
            cancellationBehavior: .respondToProvider
        )
    }

    fileprivate static func mcpUserInputRequest(from params: [String: Any]) -> ProviderUserInputRequest {
        let mode = params["mode"] as? String ?? "form"
        switch mode {
        case "form":
            return mcpFormRequest(from: params)
                ?? mcpDecisionRequest(
                    from: params,
                    detail: "The requested form uses an invalid or unsupported schema. FlowX supports primitive string, number, integer, boolean, and single- or multi-select enum fields."
                )
        case "url":
            return mcpURLRequest(from: params)
                ?? mcpDecisionRequest(
                    from: params,
                    detail: "The requested URL is unsafe or invalid. FlowX only opens explicit HTTPS links without embedded credentials."
                )
        case "openai/form":
            return mcpDecisionRequest(
                from: params,
                detail: "This OpenAI-host-specific form is opaque to third-party clients, so FlowX cannot safely display or complete its fields."
            )
        default:
            let safeMode = boundedNativePayload(mode, maximum: 256)
            return mcpDecisionRequest(
                from: params,
                detail: "FlowX does not support the requested MCP elicitation mode '\(safeMode)'."
            )
        }
    }

    private static func mcpFormField(
        name: String,
        schema: [String: Any],
        required: Bool
    ) -> ProviderUserInputQuestion? {
        guard let type = schema["type"] as? String else { return nil }
        let title = boundedNativePayload(
            nonEmpty(schema["title"] as? String) ?? (name.isEmpty ? "Field" : name),
            maximum: 256
        )
        let description = boundedNativePayload(
            nonEmpty(schema["description"] as? String) ?? "Provide \(title).",
            maximum: 8_192
        )

        switch type {
        case "string":
            if schema["oneOf"] != nil || schema["enum"] != nil {
                guard let options = mcpSingleSelectOptions(from: schema), !options.isEmpty else { return nil }
                let defaultAnswers = mcpStringDefault(schema["default"], options: options)
                return ProviderUserInputQuestion(
                    id: name,
                    header: title,
                    question: description,
                    options: options,
                    isRequired: required,
                    defaultAnswers: defaultAnswers
                )
            }

            guard let minimumLength = optionalNonnegativeInteger(schema["minLength"]),
                  let maximumLength = optionalNonnegativeInteger(schema["maxLength"]) else {
                return nil
            }
            guard validBounds(minimum: minimumLength, maximum: maximumLength) else { return nil }
            let format = schema["format"] as? String
            if let rawFormat = schema["format"], !(rawFormat is NSNull), format == nil { return nil }
            guard format == nil || ["email", "uri", "date", "date-time"].contains(format!) else { return nil }
            let defaultValue = schema["default"] as? String
            if let rawDefault = schema["default"], !(rawDefault is NSNull), defaultValue == nil { return nil }
            guard defaultValue == nil || defaultValue!.utf8.count <= 65_536 else { return nil }
            return ProviderUserInputQuestion(
                id: name,
                header: title,
                question: description,
                isRequired: required,
                valueFormat: format,
                allowsEmptyValue: (minimumLength ?? 0) == 0,
                preservesWhitespace: true,
                defaultAnswers: defaultValue.map { [$0] } ?? [],
                minimumLength: minimumLength,
                maximumLength: maximumLength
            )

        case "number", "integer":
            guard let minimum = optionalFiniteDouble(schema["minimum"]),
                  let maximum = optionalFiniteDouble(schema["maximum"]) else {
                return nil
            }
            guard validBounds(minimum: minimum, maximum: maximum) else { return nil }
            let defaultNumber = finiteDouble(schema["default"])
            if let rawDefault = schema["default"], !(rawDefault is NSNull), defaultNumber == nil { return nil }
            if type == "integer", let defaultNumber, defaultNumber.rounded() != defaultNumber { return nil }
            if type == "integer", let defaultNumber,
               (defaultNumber < Double(Int64.min) || defaultNumber >= Double(Int64.max)) {
                return nil
            }
            return ProviderUserInputQuestion(
                id: name,
                header: title,
                question: description,
                isRequired: required,
                valueType: type == "integer" ? .integer : .number,
                defaultAnswers: defaultNumber.map { [mcpNumberString($0, integer: type == "integer")] } ?? [],
                minimumValue: minimum,
                maximumValue: maximum
            )

        case "boolean":
            let defaultBoolean = boolValue(schema["default"])
            if let rawDefault = schema["default"], !(rawDefault is NSNull), defaultBoolean == nil { return nil }
            return ProviderUserInputQuestion(
                id: name,
                header: title,
                question: description,
                options: [
                    ProviderUserInputOption(label: "Yes", value: "true"),
                    ProviderUserInputOption(label: "No", value: "false"),
                ],
                isRequired: required,
                valueType: .boolean,
                defaultAnswers: defaultBoolean.map { [$0 ? "true" : "false"] } ?? []
            )

        case "array":
            guard let items = schema["items"] as? [String: Any],
                  let options = mcpMultiSelectOptions(from: items),
                  !options.isEmpty else {
                return nil
            }
            guard let minimumItems = optionalNonnegativeInteger(schema["minItems"]),
                  let maximumItems = optionalNonnegativeInteger(schema["maxItems"]) else {
                return nil
            }
            guard validBounds(minimum: minimumItems, maximum: maximumItems) else { return nil }
            if let rawDefault = schema["default"],
               !(rawDefault is NSNull),
               !(rawDefault is [String]) {
                return nil
            }
            let defaults = schema["default"] as? [String] ?? []
            let allowedValues = Set(options.map(\.value))
            guard defaults.count <= 100,
                  Set(defaults).count == defaults.count,
                  defaults.allSatisfy(allowedValues.contains) else {
                return nil
            }
            return ProviderUserInputQuestion(
                id: name,
                header: title,
                question: description,
                options: options,
                allowsMultiple: true,
                isRequired: required,
                allowsEmptyValue: (minimumItems ?? 0) == 0,
                defaultAnswers: defaults,
                minimumSelectionCount: minimumItems,
                maximumSelectionCount: maximumItems
            )

        default:
            return nil
        }
    }

    private static func mcpSingleSelectOptions(from schema: [String: Any]) -> [ProviderUserInputOption]? {
        if let titled = schema["oneOf"] as? [[String: Any]] {
            return mcpTitledOptions(titled)
        }
        guard let values = schema["enum"] as? [String], !values.isEmpty, values.count <= 100,
              Set(values).count == values.count,
              values.allSatisfy({ $0.utf8.count <= 65_536 }) else {
            return nil
        }
        let names = schema["enumNames"] as? [String]
        if let names, names.count != values.count { return nil }
        return values.enumerated().map { index, value in
            ProviderUserInputOption(
                label: boundedNativePayload(names?[index] ?? value, maximum: 256),
                value: value
            )
        }
    }

    private static func mcpMultiSelectOptions(from items: [String: Any]) -> [ProviderUserInputOption]? {
        if let titled = items["anyOf"] as? [[String: Any]] {
            return mcpTitledOptions(titled)
        }
        guard items["type"] as? String == "string",
              let values = items["enum"] as? [String],
              !values.isEmpty,
              values.count <= 100,
              Set(values).count == values.count,
              values.allSatisfy({ $0.utf8.count <= 65_536 }) else {
            return nil
        }
        return values.map { ProviderUserInputOption(label: boundedNativePayload($0, maximum: 256), value: $0) }
    }

    private static func mcpTitledOptions(_ values: [[String: Any]]) -> [ProviderUserInputOption]? {
        guard !values.isEmpty, values.count <= 100 else { return nil }
        var options: [ProviderUserInputOption] = []
        var seenValues: Set<String> = []
        for value in values {
            guard let nativeValue = value["const"] as? String,
                  nativeValue.utf8.count <= 65_536,
                  seenValues.insert(nativeValue).inserted,
                  let label = nonEmpty(value["title"] as? String) else {
                return nil
            }
            options.append(ProviderUserInputOption(
                label: boundedNativePayload(label, maximum: 256),
                value: nativeValue
            ))
        }
        return options
    }

    private static func mcpStringDefault(
        _ rawValue: Any?,
        options: [ProviderUserInputOption]
    ) -> [String] {
        guard let value = rawValue as? String,
              options.contains(where: { $0.value == value }) else {
            return []
        }
        return [value]
    }

    fileprivate static func mcpFormContent(
        fields: [ProviderUserInputQuestion],
        answers: ProviderUserInputAnswers
    ) -> [String: Any]? {
        var content: [String: Any] = [:]
        for field in fields {
            guard let submittedValues = answers[field.id] else {
                if field.isRequired { return nil }
                continue
            }
            let values = Array(submittedValues.prefix(100))

            if !field.options.isEmpty {
                let allowed = Set(field.options.map(\.value))
                guard values.allSatisfy(allowed.contains),
                      Set(values).count == values.count else {
                    return nil
                }
            }

            if field.allowsMultiple {
                guard selectionCountIsValid(values.count, for: field) else { return nil }
                content[field.id] = values
                continue
            }

            guard values.count == 1 else { return nil }
            let value = values[0]
            switch field.valueType {
            case .string:
                guard stringValueIsValid(value, for: field) else { return nil }
                content[field.id] = value
            case .number:
                guard let number = Double(value), number.isFinite,
                      numberIsValid(number, for: field) else { return nil }
                content[field.id] = number
            case .integer:
                guard let integer = Int64(value),
                      numberIsValid(Double(integer), for: field) else { return nil }
                content[field.id] = integer
            case .boolean:
                guard value == "true" || value == "false" else { return nil }
                content[field.id] = value == "true"
            }
        }
        return content
    }

    private static func selectionCountIsValid(_ count: Int, for field: ProviderUserInputQuestion) -> Bool {
        if let minimum = field.minimumSelectionCount, count < minimum { return false }
        if let maximum = field.maximumSelectionCount, count > maximum { return false }
        return true
    }

    private static func stringValueIsValid(_ value: String, for field: ProviderUserInputQuestion) -> Bool {
        if let minimum = field.minimumLength, value.count < minimum { return false }
        if let maximum = field.maximumLength, value.count > maximum { return false }
        switch field.valueFormat {
        case "email":
            let parts = value.split(separator: "@", omittingEmptySubsequences: false)
            return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
        case "uri":
            return URLComponents(string: value)?.scheme?.isEmpty == false
        case "date":
            guard value.count == 10 else { return false }
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            return formatter.date(from: value) != nil
        case "date-time":
            return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value)) != nil
                || (try? Date.ISO8601FormatStyle().parse(value)) != nil
        case nil:
            return true
        default:
            return false
        }
    }

    private static func numberIsValid(_ value: Double, for field: ProviderUserInputQuestion) -> Bool {
        if let minimum = field.minimumValue, value < minimum { return false }
        if let maximum = field.maximumValue, value > maximum { return false }
        return true
    }

    private static func nonnegativeInteger(_ rawValue: Any) -> Int? {
        guard let number = rawValue as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let value = number.doubleValue
        guard value.isFinite,
              value >= 0,
              value < Double(Int.max),
              value.rounded() == value else {
            return nil
        }
        return Int(value)
    }

    /// Outer nil means invalid; inner nil means the optional schema keyword was absent.
    private static func optionalNonnegativeInteger(_ rawValue: Any?) -> Int?? {
        guard let rawValue, !(rawValue is NSNull) else { return .some(nil) }
        guard let value = nonnegativeInteger(rawValue) else { return nil }
        return .some(value)
    }

    private static func finiteDouble(_ rawValue: Any?) -> Double? {
        guard let rawValue else { return nil }
        if let number = rawValue as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let value = number.doubleValue
            return value.isFinite ? value : nil
        }
        return nil
    }

    /// Outer nil means invalid; inner nil means the optional schema keyword was absent.
    private static func optionalFiniteDouble(_ rawValue: Any?) -> Double?? {
        guard let rawValue, !(rawValue is NSNull) else { return .some(nil) }
        guard let value = finiteDouble(rawValue) else { return nil }
        return .some(value)
    }

    private static func boolValue(_ rawValue: Any?) -> Bool? {
        guard let number = rawValue as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }

    private static func validBounds<T: Comparable>(minimum: T?, maximum: T?) -> Bool {
        guard let minimum, let maximum else { return true }
        return minimum <= maximum
    }

    private static func mcpNumberString(_ value: Double, integer: Bool) -> String {
        if integer,
           value >= Double(Int64.min),
           value < Double(Int64.max) {
            return String(Int64(value))
        }
        return String(value)
    }

    private func writeApprovalResponse(
        _ requestID: ApprovalResponseID,
        kind: ApprovalResponseKind,
        approved: Bool
    ) {
        let result: [String: Any]
        switch kind {
        case .modern:
            result = CodexProvider.approvalResult(kind: "modern", approved: approved)
        case .legacy:
            result = CodexProvider.approvalResult(kind: "legacy", approved: approved)
        case .permissions(let requested):
            result = CodexProvider.approvalResult(
                kind: "permissions",
                approved: approved,
                requestedPermissions: requested
            )
        }
        writeResponse(requestID, result: result)
    }

    private func makeApprovalRequest(
        method: String,
        params: [String: Any],
        responseID: ApprovalResponseID,
        kind: ApprovalResponseKind
    ) -> ProviderApprovalRequest? {
        let item = (params["item"] as? [String: Any])
            ?? (params["toolCall"] as? [String: Any])
            ?? (params["call"] as? [String: Any])
            ?? params

        let toolName = Self.firstNonEmptyString(
            from: item,
            keys: ["name", "toolName", "command", "title", "type"]
        ) ?? Self.firstNonEmptyString(
            from: params,
            keys: ["name", "toolName", "command", "title", "type"]
        ) ?? "Tool call"

        let description = Self.firstNonEmptyString(
            from: params,
            keys: ["message", "reason", "description", "title"]
        ) ?? Self.firstNonEmptyString(
            from: item,
            keys: ["description", "reason", "summary"]
        ) ?? Self.defaultApprovalDescription(for: toolName, item: item)

        let parameters = Self.approvalParameters(from: params, item: item)
        let approvalID = UUID()
        pendingApprovals[approvalID] = PendingApproval(responseID: responseID, kind: kind)

        return ProviderApprovalRequest(
            id: approvalID,
            toolName: toolName,
            description: description,
            parameters: parameters,
            riskLevel: Self.riskLevel(for: toolName, parameters: parameters)
        )
    }

    private static func approvalResponseID(from rawValue: Any?) -> ApprovalResponseID? {
        switch rawValue {
        case let value as Int:
            .int(value)
        case let value as String:
            .string(value)
        default:
            nil
        }
    }

    private static func firstNonEmptyString(from payload: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = payload[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    private static func defaultApprovalDescription(for toolName: String, item: [String: Any]) -> String {
        if firstNonEmptyString(from: item, keys: ["command"]) != nil {
            return "Codex wants to run a command in your workspace."
        }

        if toolName.lowercased().contains("command") || toolName.lowercased().contains("shell") {
            return "Codex wants to execute a command that requires your approval."
        }

        return "Codex needs approval before continuing this tool action."
    }

    private static func approvalParameters(from params: [String: Any], item: [String: Any]) -> [String: String] {
        var details: [String: String] = [:]

        for (key, value) in [
            ("command", item["command"] ?? params["command"]),
            ("cwd", item["cwd"] ?? params["cwd"]),
            ("tool", item["name"] ?? params["name"]),
            ("reason", params["reason"] ?? item["reason"]),
            ("path", item["path"] ?? params["path"]),
            ("prompt", item["prompt"] ?? params["prompt"]),
            ("sandbox", params["sandbox"]),
        ] {
            if let stringValue = stringValue(for: value) {
                details[key] = stringValue
            }
        }

        if let input = item["input"] ?? item["arguments"] ?? params["input"] ?? params["arguments"],
           let stringValue = stringValue(for: input) {
            details["input"] = stringValue
        }

        if details.isEmpty, let raw = stringValue(for: params) {
            details["details"] = raw
        }

        return details
    }

    private static func stringValue(for rawValue: Any?) -> String? {
        guard let rawValue else { return nil }

        if let value = rawValue as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        if JSONSerialization.isValidJSONObject(rawValue),
           let data = try? JSONSerialization.data(withJSONObject: rawValue, options: [.sortedKeys]),
           let value = String(data: data, encoding: .utf8) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        return String(describing: rawValue)
    }

    private static func riskLevel(for toolName: String, parameters: [String: String]) -> ToolRiskLevel {
        let tool = toolName.lowercased()
        let detail = parameters.values.joined(separator: " ").lowercased()

        let dangerousHints = [
            "rm ",
            "rm -",
            "git push",
            "git reset",
            "git clean",
            "sudo ",
            "chmod ",
            "chown ",
            "mv ",
            "cp ",
            "kill ",
            "pkill",
            "curl ",
            "wget ",
            "scp ",
            "ssh ",
            "kubectl delete",
            "terraform apply",
            "npm publish",
            "cargo publish",
        ]

        if dangerousHints.contains(where: { detail.contains($0) || tool.contains($0.trimmingCharacters(in: .whitespaces)) }) {
            return .dangerous
        }

        let moderateHints = ["command", "shell", "bash", "write", "edit", "patch", "exec"]
        if moderateHints.contains(where: { tool.contains($0) || detail.contains($0) }) {
            return .moderate
        }

        return .safe
    }

    private func writeJSON(_ method: String, id: Int, params: [String: Any]) {
        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ]
        writeMessage(message)
    }

    private func writeNotification(_ method: String, params: [String: Any]) {
        writeMessage([
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        ])
    }

    private func writeResponse(_ id: ApprovalResponseID, result: [String: Any]) {
        writeMessage([
            "jsonrpc": "2.0",
            "id": Self.jsonValue(for: id),
            "result": result,
        ])
    }

    private func writeError(_ id: ApprovalResponseID, code: Int, message: String) {
        writeMessage([
            "jsonrpc": "2.0",
            "id": Self.jsonValue(for: id),
            "error": ["code": code, "message": message],
        ])
    }

    private static func jsonValue(for id: ApprovalResponseID) -> Any {
        switch id {
        case .int(let value): value
        case .string(let value): value
        }
    }

    private func writeMessage(_ message: [String: Any]) {
        guard let writer else { return }

        if let data = try? JSONSerialization.data(withJSONObject: message),
           let string = String(data: data, encoding: .utf8) {
            writer.write(Data((string + "\n").utf8))
        }
    }

    private func clearActiveAttachments() {
        activeAttachments.remove()
        activeAttachments = .empty
        for attachments in activeFollowUpAttachments {
            attachments.remove()
        }
        activeFollowUpAttachments.removeAll(keepingCapacity: false)
    }

    private func cancelPendingUserInputs(message: String) {
        for pending in pendingUserInputs.values {
            switch pending.kind {
            case .structuredQuestions:
                writeError(pending.responseID, code: -32800, message: message)
            case .mcpForm, .mcpURL, .mcpDecision:
                writeResponse(pending.responseID, result: ["action": "cancel"])
            }
        }
        pendingUserInputs.removeAll()
    }

    var isIdle: Bool {
        activeContinuation == nil
    }

    func shutdown() async {
        for pending in pendingApprovals.values {
            writeApprovalResponse(pending.responseID, kind: pending.kind, approved: false)
        }
        pendingApprovals.removeAll()
        cancelPendingUserInputs(message: "The FlowX session was closed before user input was submitted.")

        if activeContinuation != nil {
            interruptCurrentTurn()
            activeContinuation?.yield(.error("The Codex session was closed."))
            activeContinuation?.finish()
        }
        activeContinuation = nil
        activeTurnID = nil
        clearActiveAttachments()
        failPendingResponses(message: "The Codex session was closed.")
        threadReady = false
        serverInitialized = false
        serverExecutableURL = nil

        guard let runningProcess = process else { return }
        (runningProcess.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (runningProcess.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        try? writer?.close()
        writer = nil
        stdoutReaderTask?.cancel()
        stdoutReaderTask = nil
        process = nil
        stderrPipe = nil
        stderrCapture = nil

        guard runningProcess.isRunning else { return }
        runningProcess.interrupt()
        try? await Task.sleep(for: .milliseconds(150))
        if runningProcess.isRunning {
            runningProcess.terminate()
            try? await Task.sleep(for: .milliseconds(500))
        }
        if runningProcess.isRunning {
            kill(runningProcess.processIdentifier, SIGKILL)
        }
    }
}

private actor CodexSessionReference {
    private var session: CodexSession?
    private var task: Task<Void, Never>?
    private var cancellationRequested = false
    private var taskBindingWaiters: [CheckedContinuation<Void, Never>] = []

    func bindTask(_ task: Task<Void, Never>) {
        self.task = task
        if cancellationRequested { task.cancel() }
        let waiters = taskBindingWaiters
        taskBindingWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilTaskIsBound() async {
        if task != nil { return }
        await withCheckedContinuation { continuation in
            taskBindingWaiters.append(continuation)
        }
    }

    func finishTask() {
        task = nil
    }

    func set(_ session: CodexSession) async -> Bool {
        self.session = session
        guard !cancellationRequested else {
            await session.interruptCurrentTurn()
            return false
        }
        return true
    }

    func get() -> CodexSession? {
        session
    }

    func canContinue() -> Bool {
        !cancellationRequested
    }

    func requestCancellation() async {
        cancellationRequested = true
        task?.cancel()
        await session?.interruptCurrentTurn()
    }
}

public final class CodexProvider: AIProviderThreadControls, AIProviderSessionManaging, AIProviderNativeThreads, AIProviderNativeThreadRenaming, AIProviderNativeThreadArchiving, AIProviderNativeThreadDeleting, Sendable {
    public let id = "codex"
    public let displayName = "Codex"
    public var availableModels: [AIModel] { modelCatalog.models }
    public let capabilities = AIProviderCapabilities(
        supportedAttachments: [.image],
        supportsApprovals: true,
        supportsThreadControls: true,
        supportsModelDiscovery: true
    )

    private let store = CodexSessionStore()
    private let discovery: RuntimeDiscovery
    private let modelCatalog: ProviderModelCatalog
    private let nativeReader: CodexSession

    public init(discovery: RuntimeDiscovery) {
        self.discovery = discovery
        modelCatalog = ProviderModelCatalog(Self.fallbackModels)
        nativeReader = CodexSession(
            resumeThreadID: nil,
            workingDirectory: nil,
            systemPrompt: nil,
            agentMode: nil,
            agentAccess: nil,
            discovery: discovery,
            opensConversationThread: false
        )
    }

    @discardableResult
    public func refreshAvailableModels() async -> [AIModel] {
        guard let result = try? await discovery.run(
            binaryID: "codex",
            arguments: ["debug", "models"],
            timeout: 20
        ), result.terminationStatus == 0, !result.timedOut,
        let models = Self.parseModelCatalog(result.standardOutput), !models.isEmpty else {
            return availableModels
        }
        modelCatalog.replace(with: models)
        return models
    }

    public func listNativeThreads(
        workingDirectory: URL,
        limit: Int = 100
    ) async throws -> [ProviderNativeThreadSummary] {
        try await nativeReader.listNativeThreads(
            workingDirectory: workingDirectory,
            limit: limit,
            discoveryMode: .indexed
        )
    }

    public func listNativeThreads(
        workingDirectory: URL,
        limit: Int = 100,
        discoveryMode: ProviderNativeThreadDiscoveryMode
    ) async throws -> [ProviderNativeThreadSummary] {
        try await nativeReader.listNativeThreads(
            workingDirectory: workingDirectory,
            limit: limit,
            discoveryMode: discoveryMode
        )
    }

    public func readNativeThread(
        id: String,
        workingDirectory: URL?
    ) async throws -> ProviderNativeThread {
        try await nativeReader.readNativeThread(id: id, workingDirectory: workingDirectory)
    }

    public func deleteNativeThread(
        id: String,
        workingDirectory: URL
    ) async throws {
        try await nativeReader.deleteNativeThread(id: id, workingDirectory: workingDirectory)
        await store.release(id.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func renameNativeThread(
        id: String,
        name: String,
        workingDirectory: URL
    ) async throws {
        try await nativeReader.renameNativeThread(
            id: id,
            name: name,
            workingDirectory: workingDirectory
        )
    }

    public func listArchivedNativeThreads(
        workingDirectory: URL,
        limit: Int = 100
    ) async throws -> [ProviderNativeThreadSummary] {
        try await nativeReader.listNativeThreads(
            workingDirectory: workingDirectory,
            limit: limit,
            discoveryMode: .indexed,
            archived: true
        )
    }

    public func archiveNativeThread(
        id: String,
        workingDirectory: URL
    ) async throws {
        try await nativeReader.archiveNativeThread(id: id, workingDirectory: workingDirectory)
        await store.release(id.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func unarchiveNativeThread(
        id: String,
        workingDirectory: URL
    ) async throws {
        try await nativeReader.unarchiveNativeThread(id: id, workingDirectory: workingDirectory)
    }

    static let fallbackModels: [AIModel] = [
        AIModel(
            id: "gpt-5.6-sol",
            name: "GPT-5.6 Sol",
            description: "Latest frontier agentic coding model.",
            contextWindow: 272_000,
            maxContextWindow: 272_000,
            availableContextWindows: [272_000],
            defaultReasoningEffort: "low",
            supportedReasoningEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"],
            isDefault: true,
            serviceTiers: [AIModelServiceTier(id: "priority", name: "Fast", description: "1.5x speed, increased usage")]
        ),
        AIModel(
            id: "gpt-5.6-terra",
            name: "GPT-5.6 Terra",
            description: "Balanced agentic coding model for everyday work.",
            contextWindow: 272_000,
            maxContextWindow: 272_000,
            availableContextWindows: [272_000],
            defaultReasoningEffort: "medium",
            supportedReasoningEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"]
        ),
        AIModel(
            id: "gpt-5.6-luna",
            name: "GPT-5.6 Luna",
            description: "Efficient agentic coding model.",
            contextWindow: 272_000,
            maxContextWindow: 272_000,
            availableContextWindows: [272_000],
            defaultReasoningEffort: "medium",
            supportedReasoningEfforts: ["low", "medium", "high", "xhigh", "max"]
        ),
    ]

    static func parseModelCatalog(_ data: Data) -> [AIModel]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawModels = root["models"] as? [[String: Any]] else {
            return nil
        }

        let fallbackByID = Dictionary(uniqueKeysWithValues: fallbackModels.map { ($0.id, $0) })
        var models: [AIModel] = []
        for raw in rawModels {
            guard let id = raw["slug"] as? String, !id.isEmpty else { continue }
            if let visibility = raw["visibility"] as? String, visibility != "list" { continue }

            let fallback = fallbackByID[id]
            let efforts = (raw["supported_reasoning_levels"] as? [[String: Any]] ?? [])
                .compactMap { $0["effort"] as? String }
            let modalities = (raw["input_modalities"] as? [String] ?? ["text"])
                .compactMap(AIInputModality.init(rawValue:))
            let tiers = (raw["service_tiers"] as? [[String: Any]] ?? []).compactMap { tier -> AIModelServiceTier? in
                guard let tierID = tier["id"] as? String,
                      let name = tier["name"] as? String else { return nil }
                return AIModelServiceTier(
                    id: tierID,
                    name: name,
                    description: tier["description"] as? String ?? ""
                )
            }
            let contextWindow = (raw["context_window"] as? Int) ?? fallback?.contextWindow ?? 272_000
            let maxContextWindow = (raw["max_context_window"] as? Int) ?? fallback?.maxContextWindow ?? contextWindow

            models.append(AIModel(
                id: id,
                name: (raw["display_name"] as? String) ?? fallback?.name ?? id,
                description: (raw["description"] as? String) ?? fallback?.description,
                contextWindow: contextWindow,
                maxContextWindow: maxContextWindow,
                availableContextWindows: [contextWindow],
                supportsTools: true,
                supportsVision: modalities.contains(.image),
                inputModalities: modalities.isEmpty ? [.text] : modalities,
                defaultReasoningEffort: (raw["default_reasoning_level"] as? String) ?? fallback?.defaultReasoningEffort,
                supportedReasoningEfforts: efforts.isEmpty ? (fallback?.supportedReasoningEfforts ?? []) : efforts,
                isDefault: models.isEmpty,
                serviceTiers: tiers.isEmpty ? (fallback?.serviceTiers ?? []) : tiers
            ))
        }
        return models
    }

    static func approvalResult(
        kind: String,
        approved: Bool,
        requestedPermissions: [String: Any] = [:]
    ) -> [String: Any] {
        switch kind {
        case "modern":
            ["decision": approved ? "accept" : "decline"]
        case "legacy":
            ["decision": approved ? "approved" : "denied"]
        case "permissions":
            ["permissions": approved ? requestedPermissions : [:], "scope": "turn"]
        default:
            [:]
        }
    }

    static func mapNativeMessagesForTesting(_ thread: [String: Any]) -> [ConversationMessage] {
        CodexSession.nativeMessages(from: thread)
    }

    static func userInputRequestForTesting(_ params: [String: Any]) -> ProviderUserInputRequest? {
        CodexSession.userInputRequest(from: params)
    }

    static func userInputResponseForTesting(
        questionIDs: [String],
        answers: ProviderUserInputAnswers
    ) -> [String: Any] {
        CodexSession.userInputResponse(questionIDs: questionIDs, answers: answers)
    }

    static func mcpUserInputRequestForTesting(_ params: [String: Any]) -> ProviderUserInputRequest? {
        CodexSession.mcpUserInputRequest(from: params)
    }

    static func mcpFormResponseForTesting(
        fields: [ProviderUserInputQuestion],
        answers: ProviderUserInputAnswers
    ) -> [String: Any]? {
        guard let content = CodexSession.mcpFormContent(fields: fields, answers: answers) else {
            return nil
        }
        return ["action": "accept", "content": content]
    }

    static func nativeThreadListParametersForTesting(
        cwdFilters: [String],
        limit: Int,
        cursor: String? = nil,
        discoveryMode: ProviderNativeThreadDiscoveryMode,
        archived: Bool = false
    ) -> [String: Any] {
        CodexSession.nativeThreadListParameters(
            cwdFilters: cwdFilters,
            limit: limit,
            cursor: cursor,
            discoveryMode: discoveryMode,
            archived: archived
        )
    }

    static func nativeThreadDeleteRequestForTesting(
        threadID: String
    ) -> (method: String, params: [String: Any]) {
        CodexSession.nativeThreadDeleteRequest(threadID: threadID)
    }

    static func nativeThreadRenameRequestForTesting(
        threadID: String,
        name: String
    ) -> (method: String, params: [String: Any]) {
        CodexSession.nativeThreadRenameRequest(threadID: threadID, name: name)
    }

    static func nativeThreadIsActiveForTesting(_ status: String?) -> Bool {
        CodexSession.isNativeThreadActive(status)
    }

    static func nativeThreadSummaryForTesting(
        _ thread: [String: Any],
        expectedCanonicalDirectory: String? = nil
    ) -> ProviderNativeThreadSummary? {
        CodexSession.nativeSummary(
            from: thread,
            expectedCanonicalDirectory: expectedCanonicalDirectory
        )
    }

    static func turnSteerParametersForTesting(
        threadID: String,
        expectedTurnID: String,
        prompt: String,
        imagePaths: [URL]
    ) -> [String: Any] {
        CodexSession.turnSteerParameters(
            threadID: threadID,
            expectedTurnID: expectedTurnID,
            prompt: prompt,
            imagePaths: imagePaths
        )
    }

    static var controlRequestTimeoutSecondsForTesting: UInt64 {
        CodexSession.controlRequestTimeoutSeconds
    }

    static func initializationFailureMessageForTesting(
        summary: String = "Codex app-server did not complete initialization.",
        executableURL: URL?,
        stderr: String?,
        terminationStatus: Int32?,
        terminatedBySignal: Bool,
        isQuarantined: Bool
    ) -> String {
        CodexSession.initializationFailureMessage(
            summary: summary,
            executableURL: executableURL,
            stderr: stderr,
            terminationStatus: terminationStatus,
            terminatedBySignal: terminatedBySignal,
            isQuarantined: isQuarantined
        )
    }

    static func preSessionCancellationIsRememberedForTesting() async -> Bool {
        let reference = CodexSessionReference()
        await reference.requestCancellation()
        return !(await reference.canContinue())
    }

    static func codexParams(for access: AgentAccess) -> (approvalPolicy: String, sandbox: String) {
        switch access {
        case .supervised:
            ("untrusted", "workspace-write")
        case .acceptEdits:
            ("on-request", "workspace-write")
        case .fullAccess:
            ("never", "danger-full-access")
        }
    }

    public func sendMessage(
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
    ) -> ProviderStreamHandle {
        let reference = CodexSessionReference()

        let stream = AsyncThrowingStream<StreamEvent, Error> { continuation in
            let task = Task {
                do {
                    await reference.waitUntilTaskIsBound()
                    try Task.checkCancellation()
                    guard await reference.canContinue() else { throw CancellationError() }
                    let session = await store.session(
                        for: resumeSessionID,
                        workingDirectory: workingDirectory,
                        systemPrompt: systemPrompt,
                        agentMode: agentMode,
                        agentAccess: agentAccess,
                        discovery: discovery
                    )
                    let registrationLease = CodexUnregisteredSessionLease(
                        isAlreadyTracked: resumeSessionID != nil,
                        cleanup: {
                            await session.shutdown()
                        }
                    )
                    do {
                        try Task.checkCancellation()
                        guard await reference.set(session) else { throw CancellationError() }
                        try Task.checkCancellation()
                        guard await reference.canContinue() else { throw CancellationError() }
                        let threadID = try await session.startTurn(
                            prompt: prompt,
                            attachments: attachments,
                            model: model,
                            effort: effort,
                            workingDirectory: workingDirectory,
                            systemPrompt: systemPrompt,
                            agentMode: agentMode,
                            agentAccess: agentAccess,
                            continuation: continuation
                        )
                        await store.register(session, for: threadID)
                        await registrationLease.markRegistered()
                    } catch {
                        await registrationLease.cleanupIfNeeded()
                        throw error
                    }
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.yield(.error(error.localizedDescription))
                    continuation.finish(throwing: error)
                }
                await reference.finishTask()
            }
            Task {
                await reference.bindTask(task)
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
                Task {
                    await reference.requestCancellation()
                }
            }
        }

        return ProviderStreamHandle(
            stream: stream,
            cancel: {
                await reference.requestCancellation()
            },
            steer: { prompt, attachments in
                guard let session = await reference.get() else {
                    throw ProviderSteeringError.unavailable(
                        "Codex is still starting this turn. Wait for it to begin, then retry steering."
                    )
                }
                try await session.steer(prompt: prompt, attachments: attachments)
            },
            respondToApproval: { approvalID, approved in
                await reference.get()?.respondToApproval(approvalID, approved: approved)
            },
            respondToUserInput: { requestID, answers in
                await reference.get()?.respondToUserInput(requestID, answers: answers)
            },
            cancelUserInput: { requestID in
                await reference.get()?.cancelUserInput(requestID)
            }
        )
    }

    public func releaseSession(_ sessionID: String) async {
        await store.release(sessionID)
    }

    public func releaseAllSessions() async {
        await store.releaseAll()
        await nativeReader.shutdown()
    }

    public func setThreadGoal(
        objective: String?,
        status: ConversationGoalStatus?,
        tokenBudget: Int?,
        systemPrompt: String?,
        agentMode: AgentMode?,
        agentAccess: AgentAccess?,
        workingDirectory: URL?,
        resumeSessionID: String?
    ) async throws -> ConversationGoal {
        let session = await store.session(
            for: resumeSessionID,
            workingDirectory: workingDirectory,
            systemPrompt: systemPrompt,
            agentMode: agentMode,
            agentAccess: agentAccess,
            discovery: discovery
        )
        let registrationLease = CodexUnregisteredSessionLease(
            isAlreadyTracked: resumeSessionID != nil,
            cleanup: {
                await session.shutdown()
            }
        )
        do {
            let goal = try await session.setGoal(
                objective: objective,
                status: status,
                tokenBudget: tokenBudget,
                workingDirectory: workingDirectory,
                systemPrompt: systemPrompt
            )
            await store.register(session, for: goal.threadID)
            await registrationLease.markRegistered()
            return goal
        } catch {
            await registrationLease.cleanupIfNeeded()
            throw error
        }
    }

    public func getThreadGoal(
        systemPrompt: String?,
        agentMode: AgentMode?,
        agentAccess: AgentAccess?,
        workingDirectory: URL?,
        resumeSessionID: String?
    ) async throws -> (threadID: String, goal: ConversationGoal?) {
        let session = await store.session(
            for: resumeSessionID,
            workingDirectory: workingDirectory,
            systemPrompt: systemPrompt,
            agentMode: agentMode,
            agentAccess: agentAccess,
            discovery: discovery
        )
        let registrationLease = CodexUnregisteredSessionLease(
            isAlreadyTracked: resumeSessionID != nil,
            cleanup: {
                await session.shutdown()
            }
        )
        do {
            let result = try await session.getGoal(
                workingDirectory: workingDirectory,
                systemPrompt: systemPrompt
            )
            await store.register(session, for: result.threadID)
            await registrationLease.markRegistered()
            return result
        } catch {
            await registrationLease.cleanupIfNeeded()
            throw error
        }
    }

    public func clearThreadGoal(
        systemPrompt: String?,
        agentMode: AgentMode?,
        agentAccess: AgentAccess?,
        workingDirectory: URL?,
        resumeSessionID: String?
    ) async throws -> String {
        let session = await store.session(
            for: resumeSessionID,
            workingDirectory: workingDirectory,
            systemPrompt: systemPrompt,
            agentMode: agentMode,
            agentAccess: agentAccess,
            discovery: discovery
        )
        let registrationLease = CodexUnregisteredSessionLease(
            isAlreadyTracked: resumeSessionID != nil,
            cleanup: {
                await session.shutdown()
            }
        )
        do {
            let threadID = try await session.clearGoal(
                workingDirectory: workingDirectory,
                systemPrompt: systemPrompt
            )
            await store.register(session, for: threadID)
            await registrationLease.markRegistered()
            return threadID
        } catch {
            await registrationLease.cleanupIfNeeded()
            throw error
        }
    }

    public func compactThread(
        systemPrompt: String?,
        agentMode: AgentMode?,
        agentAccess: AgentAccess?,
        workingDirectory: URL?,
        resumeSessionID: String?
    ) async throws -> String {
        let session = await store.session(
            for: resumeSessionID,
            workingDirectory: workingDirectory,
            systemPrompt: systemPrompt,
            agentMode: agentMode,
            agentAccess: agentAccess,
            discovery: discovery
        )
        let registrationLease = CodexUnregisteredSessionLease(
            isAlreadyTracked: resumeSessionID != nil,
            cleanup: {
                await session.shutdown()
            }
        )
        do {
            let threadID = try await session.compactThread(
                workingDirectory: workingDirectory,
                systemPrompt: systemPrompt
            )
            await store.register(session, for: threadID)
            await registrationLease.markRegistered()
            return threadID
        } catch {
            await registrationLease.cleanupIfNeeded()
            throw error
        }
    }
}
