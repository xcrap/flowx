import Foundation
import FXCore

@MainActor
public final class ConversationService {
    // Text remains visibly fluid while avoiding a full transcript relayout for
    // every tiny provider delta. Twenty UI publications per second is faster
    // than users can read and leaves substantially more main-thread headroom.
    nonisolated private static let streamFlushInterval: TimeInterval = 1.0 / 20.0
    nonisolated private static let streamFlushCharacterThreshold = 1_024
    nonisolated private static let maxQueuedRequestsPerConversation = 20
    nonisolated private static let maxQueuedAttachmentBytesPerConversation = 64 * 1_024 * 1_024
    nonisolated private static let toolInputExecutor = BoundedTaskExecutor(maxConcurrentTasks: 2)

    private struct PendingRequest {
        var prompt: String
        let attachments: [Attachment]
        let providerID: String
        let model: String?
        let effort: String?
        let systemPrompt: String?
        let agentMode: AgentMode?
        let agentAccess: AgentAccess?
        let workingDirectory: URL?
        let resumeSessionID: String?
        let onStart: (() -> Void)?
        let onSessionReady: (() -> Void)?
        let onComplete: (() -> Void)?
        let queued: Bool
    }

    private struct ActiveRequest {
        let task: Task<Void, Never>
        let cancel: @Sendable () async -> Void
        let steer: @Sendable (String, [Attachment]) async throws -> Void
        let respondToApproval: @Sendable (UUID, Bool) async -> Void
        let respondToUserInput: @Sendable (UUID, ProviderUserInputAnswers) async -> Void
        let cancelUserInput: @Sendable (UUID) async -> Void
    }

    private let registry: ProviderRegistry
    private var activeRequests: [UUID: ActiveRequest] = [:]
    private var activeStates: [UUID: ConversationState] = [:]
    private var pendingRequests: [UUID: [PendingRequest]] = [:]

    public init(registry: ProviderRegistry) {
        self.registry = registry
    }

    @discardableResult
    public func send(
        prompt: String,
        attachments: [Attachment] = [],
        to conversationState: ConversationState,
        providerID: String,
        model: String?,
        effort: String? = nil,
        systemPrompt: String? = nil,
        agentMode: AgentMode? = nil,
        agentAccess: AgentAccess? = nil,
        workingDirectory: URL? = nil,
        resumeSessionID: String? = nil,
        onStart: (() -> Void)? = nil,
        onSessionReady: (() -> Void)? = nil,
        onComplete: (() -> Void)? = nil
    ) -> Bool {
        let isQueued = activeRequests[conversationState.agentID] != nil

        let request = PendingRequest(
            prompt: prompt,
            attachments: attachments,
            providerID: providerID,
            model: model,
            effort: effort,
            systemPrompt: systemPrompt,
            agentMode: agentMode,
            agentAccess: agentAccess,
            workingDirectory: workingDirectory,
            resumeSessionID: resumeSessionID,
            onStart: onStart,
            onSessionReady: onSessionReady,
            onComplete: onComplete,
            queued: isQueued
        )

        if isQueued {
            let existingQueue = pendingRequests[conversationState.agentID] ?? []
            let queuedAttachmentBytes = existingQueue.reduce(into: 0) { total, queuedRequest in
                total += Self.attachmentByteCount(queuedRequest.attachments)
            }
            let requestedAttachmentBytes = Self.attachmentByteCount(attachments)

            let rejection: String?
            if existingQueue.count >= Self.maxQueuedRequestsPerConversation {
                rejection = "The queue is full (maximum \(Self.maxQueuedRequestsPerConversation) prompts)."
            } else if queuedAttachmentBytes > Self.maxQueuedAttachmentBytesPerConversation - requestedAttachmentBytes {
                rejection = "Queued attachments would exceed the 64 MB per-conversation limit."
            } else {
                rejection = nil
            }

            if let rejection {
                conversationState.reportNonfatalError(rejection)
                conversationState.recordRuntimeActivity(
                    kind: .queue,
                    tone: .error,
                    summary: "Prompt not queued",
                    detail: rejection,
                    state: "rejected",
                    turnID: conversationState.activeTurnID
                )
                onComplete?()
                return false
            }

            conversationState.enqueuePrompt(prompt)
            let queuedCount = existingQueue.count + 1
            conversationState.recordRuntimeActivity(
                kind: .queue,
                tone: .info,
                summary: "Prompt queued",
                detail: queuedCount == 1 ? "Next up" : "\(queuedCount) prompts waiting",
                state: "queued",
                turnID: conversationState.activeTurnID
            )
            pendingRequests[conversationState.agentID, default: []].append(request)
            return true
        }

        conversationState.appendUserMessage(prompt, attachments: attachments)
        request.onStart?()
        start(request, for: conversationState)
        return true
    }

    nonisolated private static func attachmentByteCount(_ attachments: [Attachment]) -> Int {
        attachments.reduce(into: 0) { total, attachment in
            let (sum, overflow) = total.addingReportingOverflow(attachment.data.count)
            total = overflow ? Int.max : sum
        }
    }

    public func removeQueuedPrompt(at index: Int, for agentID: UUID, conversationState: ConversationState) {
        guard var queue = pendingRequests[agentID], index >= 0, index < queue.count else { return }
        queue.remove(at: index)
        pendingRequests[agentID] = queue.isEmpty ? nil : queue
        conversationState.removeQueuedPrompt(at: index)
    }

    public func queuedPrompt(at index: Int, for agentID: UUID) -> String? {
        guard let queue = pendingRequests[agentID], index >= 0, index < queue.count else { return nil }
        return queue[index].prompt
    }

    public func updateQueuedPrompt(
        at index: Int,
        with prompt: String,
        for agentID: UUID,
        conversationState: ConversationState
    ) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty,
              var queue = pendingRequests[agentID],
              index >= 0,
              index < queue.count else { return }

        queue[index].prompt = trimmedPrompt
        pendingRequests[agentID] = queue
        conversationState.updateQueuedPrompt(at: index, prompt: trimmedPrompt)
    }

    public func clearPendingRequests(for agentID: UUID) {
        pendingRequests[agentID] = nil
    }

    /// Sends guidance into the provider's currently active turn.
    ///
    /// The caller should clear its composer only when this returns `true`.
    /// Rejected guidance is neither queued nor appended to the transcript.
    @discardableResult
    public func steer(
        prompt: String,
        attachments: [Attachment] = [],
        conversationState: ConversationState,
        onAccepted: (() -> Void)? = nil
    ) async -> Bool {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty || !attachments.isEmpty else {
            let message = "Enter guidance or attach an image before steering the active turn."
            conversationState.reportNonfatalError(message)
            conversationState.recordRuntimeActivity(
                kind: .note,
                tone: .error,
                summary: "Guidance not sent",
                detail: message,
                state: "rejected",
                turnID: conversationState.activeTurnID
            )
            return false
        }

        guard let activeRequest = activeRequests[conversationState.agentID] else {
            let message = "There is no active turn to steer. Send this as a new prompt or queue it instead."
            conversationState.reportNonfatalError(message)
            conversationState.recordRuntimeActivity(
                kind: .note,
                tone: .error,
                summary: "Guidance not sent",
                detail: message,
                state: "rejected",
                turnID: conversationState.activeTurnID
            )
            return false
        }

        do {
            try await activeRequest.steer(prompt, attachments)
            conversationState.appendUserMessage(prompt, attachments: attachments)
            conversationState.dismissError()
            conversationState.recordRuntimeActivity(
                kind: .note,
                tone: .success,
                summary: "Guidance sent",
                detail: Self.summarizedRuntimeText(prompt)
                    ?? (attachments.count == 1 ? "1 image" : "\(attachments.count) images"),
                state: "steered",
                turnID: conversationState.activeTurnID
            )
            onAccepted?()
            return true
        } catch {
            let detail = error.localizedDescription
            let message = "Could not steer the active turn: \(detail) Your message was not sent; retry or queue it."
            conversationState.reportNonfatalError(message)
            conversationState.recordRuntimeActivity(
                kind: .note,
                tone: .error,
                summary: "Guidance not sent",
                detail: detail,
                state: "rejected",
                turnID: conversationState.activeTurnID
            )
            return false
        }
    }

    public func releaseProviderSession(_ sessionID: String, providerID: String) async {
        guard let provider = registry.provider(for: providerID) as? any AIProviderSessionManaging else { return }
        await provider.releaseSession(sessionID)
    }

    public func releaseAllProviderSessions() async {
        for provider in registry.allProviders {
            if let manager = provider as? any AIProviderSessionManaging {
                await manager.releaseAllSessions()
            }
        }
    }

    public func cancelStreaming(for agentID: UUID) {
        guard let activeRequest = activeRequests[agentID] else { return }
        activeStates[agentID]?.markCancellationRequested()
        activeRequest.task.cancel()
        Task {
            await activeRequest.cancel()
        }
        pendingRequests[agentID] = nil
        activeStates[agentID]?.clearQueuedPrompts()
        activeStates[agentID]?.clearToolApprovalRequests()
        activeStates[agentID]?.clearUserInputRequests()
    }

    public func respondToToolApproval(_ approvalID: UUID, approved: Bool, for agentID: UUID) async {
        guard let activeRequest = activeRequests[agentID] else { return }
        await activeRequest.respondToApproval(approvalID, approved)
    }

    public func respondToUserInput(
        _ requestID: UUID,
        answers: ProviderUserInputAnswers,
        for agentID: UUID
    ) async {
        guard let activeRequest = activeRequests[agentID] else { return }
        await activeRequest.respondToUserInput(requestID, answers)
        activeStates[agentID]?.removeUserInputRequest(requestID)
    }

    public func cancelUserInput(_ requestID: UUID, for agentID: UUID) async {
        guard let activeRequest = activeRequests[agentID] else { return }
        await activeRequest.cancelUserInput(requestID)
        activeStates[agentID]?.removeUserInputRequest(requestID)
    }

    @discardableResult
    public func setGoal(
        objective: String?,
        status: ConversationGoalStatus?,
        tokenBudget: Int? = nil,
        for conversationState: ConversationState,
        providerID: String,
        systemPrompt: String? = nil,
        agentMode: AgentMode? = nil,
        agentAccess: AgentAccess? = nil,
        workingDirectory: URL? = nil,
        resumeSessionID: String? = nil
    ) async throws -> ConversationGoal {
        let controls = try threadControls(for: providerID)
        let goal = try await controls.setThreadGoal(
            objective: objective,
            status: status,
            tokenBudget: tokenBudget,
            systemPrompt: systemPrompt,
            agentMode: agentMode,
            agentAccess: agentAccess,
            workingDirectory: workingDirectory,
            resumeSessionID: resumeSessionID ?? conversationState.sessionID
        )

        conversationState.registerSession(goal.threadID, modelID: conversationState.activeModelID)
        conversationState.updateGoal(goal)
        conversationState.recordRuntimeActivity(
            kind: .note,
            tone: goal.status == .active ? .success : .info,
            summary: Self.goalActivitySummary(for: goal),
            detail: Self.summarizedRuntimeText(goal.objective),
            state: goal.status.rawValue,
            turnID: conversationState.activeTurnID
        )
        return goal
    }

    @discardableResult
    public func refreshGoal(
        for conversationState: ConversationState,
        providerID: String,
        systemPrompt: String? = nil,
        agentMode: AgentMode? = nil,
        agentAccess: AgentAccess? = nil,
        workingDirectory: URL? = nil,
        resumeSessionID: String? = nil
    ) async throws -> ConversationGoal? {
        let controls = try threadControls(for: providerID)
        let result = try await controls.getThreadGoal(
            systemPrompt: systemPrompt,
            agentMode: agentMode,
            agentAccess: agentAccess,
            workingDirectory: workingDirectory,
            resumeSessionID: resumeSessionID ?? conversationState.sessionID
        )

        conversationState.registerSession(result.threadID, modelID: conversationState.activeModelID)
        if let goal = result.goal {
            conversationState.updateGoal(goal)
            conversationState.recordRuntimeActivity(
                kind: .note,
                tone: .info,
                summary: "Goal status",
                detail: "\(goal.status.label) • \(Self.summarizedRuntimeText(goal.objective) ?? goal.objective)",
                state: goal.status.rawValue,
                turnID: conversationState.activeTurnID
            )
        } else {
            conversationState.clearGoal()
            conversationState.recordRuntimeActivity(
                kind: .note,
                tone: .info,
                summary: "No active goal",
                state: "empty",
                turnID: conversationState.activeTurnID
            )
        }
        return result.goal
    }

    public func clearGoal(
        for conversationState: ConversationState,
        providerID: String,
        systemPrompt: String? = nil,
        agentMode: AgentMode? = nil,
        agentAccess: AgentAccess? = nil,
        workingDirectory: URL? = nil,
        resumeSessionID: String? = nil
    ) async throws {
        let controls = try threadControls(for: providerID)
        let threadID = try await controls.clearThreadGoal(
            systemPrompt: systemPrompt,
            agentMode: agentMode,
            agentAccess: agentAccess,
            workingDirectory: workingDirectory,
            resumeSessionID: resumeSessionID ?? conversationState.sessionID
        )

        conversationState.registerSession(threadID, modelID: conversationState.activeModelID)
        conversationState.clearGoal()
        conversationState.recordRuntimeActivity(
            kind: .note,
            tone: .info,
            summary: "Goal cleared",
            state: "cleared",
            turnID: conversationState.activeTurnID
        )
    }

    public func compactThread(
        for conversationState: ConversationState,
        providerID: String,
        systemPrompt: String? = nil,
        agentMode: AgentMode? = nil,
        agentAccess: AgentAccess? = nil,
        workingDirectory: URL? = nil,
        resumeSessionID: String? = nil
    ) async throws {
        guard activeRequests[conversationState.agentID] == nil else {
            throw Self.makeError("Wait for the current turn to finish before compacting context.")
        }

        let controls = try threadControls(for: providerID)
        conversationState.applyLifecyclePhase(.compacting)
        conversationState.recordRuntimeActivity(
            kind: .contextCompaction,
            tone: .working,
            summary: "Context compacting",
            detail: Self.usageDetail(for: conversationState),
            state: "compacting",
            turnID: conversationState.activeTurnID
        )

        do {
            let threadID = try await controls.compactThread(
                systemPrompt: systemPrompt,
                agentMode: agentMode,
                agentAccess: agentAccess,
                workingDirectory: workingDirectory,
                resumeSessionID: resumeSessionID ?? conversationState.sessionID
            )
            conversationState.registerSession(threadID, modelID: conversationState.activeModelID)
            conversationState.applyLifecyclePhase(.idle)
            conversationState.recordRuntimeActivity(
                kind: .contextCompaction,
                tone: .success,
                summary: "Context compact requested",
                detail: Self.usageDetail(for: conversationState),
                state: "requested",
                turnID: conversationState.activeTurnID
            )
        } catch {
            conversationState.applyLifecyclePhase(.idle)
            throw error
        }
    }

    private func start(_ request: PendingRequest, for conversationState: ConversationState) {
        if request.queued {
            conversationState.beginQueuedPrompt()
            conversationState.appendUserMessage(request.prompt, attachments: request.attachments)
            request.onStart?()
        }

        conversationState.beginToolTracking()
        conversationState.startStreaming(providerID: request.providerID, modelID: request.model)

        guard let provider = registry.provider(for: request.providerID) else {
            let message = "Provider '\(request.providerID)' not found. Configure it in Settings."
            conversationState.setError(message)
            conversationState.recordRuntimeActivity(
                kind: .error,
                tone: .error,
                summary: "Provider unavailable",
                detail: message,
                state: "failed",
                turnID: conversationState.activeTurnID
            )
            request.onComplete?()
            startNextRequestIfNeeded(for: conversationState)
            return
        }

        if let configured = conversationState.configuredContextWindow {
            conversationState.reportedContextWindow = configured
        } else if conversationState.reportedContextWindow == nil,
                  let contextWindow = provider.availableModels.first(where: { $0.id == request.model })?.contextWindow,
                  contextWindow > 0 {
            conversationState.reportedContextWindow = contextWindow
        }

        let handle = provider.sendMessage(
            prompt: request.prompt,
            attachments: request.attachments,
            messages: conversationState.messages,
            model: request.model,
            effort: request.effort,
            systemPrompt: request.systemPrompt,
            agentMode: request.agentMode,
            agentAccess: request.agentAccess,
            workingDirectory: request.workingDirectory,
            resumeSessionID: request.resumeSessionID ?? conversationState.sessionID
        )

        let agentID = conversationState.agentID
        activeStates[agentID] = conversationState
        let task = Task { [weak self] in
            var didReceiveCompletion = false
            var didReceiveError = false
            var pendingStreamDelta = ""
            var lastStreamFlushAt = Date.distantPast

            @MainActor
            func flushPendingStreamDelta() {
                guard !pendingStreamDelta.isEmpty else { return }
                conversationState.appendStreamDelta(pendingStreamDelta)
                pendingStreamDelta = ""
                lastStreamFlushAt = Date()
            }

            @MainActor
            func enqueueStreamDelta(_ delta: String) {
                pendingStreamDelta += delta
                let now = Date()
                if pendingStreamDelta.count >= Self.streamFlushCharacterThreshold
                    || now.timeIntervalSince(lastStreamFlushAt) >= Self.streamFlushInterval {
                    flushPendingStreamDelta()
                }
            }

            do {
                for try await event in handle.stream {
                    guard !Task.isCancelled else { break }

                    switch event {
                    case .initialized(let sessionID, let model):
                        let previousSessionID = conversationState.sessionID
                        let previousModelID = conversationState.activeModelID
                        conversationState.registerSession(sessionID, modelID: model)
                        request.onSessionReady?()
                        if previousSessionID != sessionID || previousModelID != model {
                            let sessionDetail = [provider.displayName, model]
                                .compactMap { $0 }
                                .filter { !$0.isEmpty }
                                .joined(separator: " • ")
                            conversationState.recordRuntimeActivity(
                                kind: .session,
                                tone: .success,
                                summary: "Session ready",
                                detail: sessionDetail.isEmpty ? nil : sessionDetail,
                                state: "configured",
                                turnID: conversationState.activeTurnID
                            )
                        }

                    case .modelChanged(let model, let reason):
                        let previousModel = conversationState.activeModelID
                        conversationState.updateActiveModel(model)
                        if previousModel != model {
                            conversationState.recordRuntimeActivity(
                                kind: .session,
                                tone: .info,
                                summary: "Model changed",
                                detail: [model, reason].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " • "),
                                state: "rerouted",
                                turnID: conversationState.activeTurnID
                            )
                        }

                    case .lifecycle(let lifecycleEvent):
                        switch lifecycleEvent {
                        case .turnStarted(let turnID):
                            conversationState.markTurnStarted(turnID: turnID)
                        case .phaseChanged(let phase):
                            conversationState.applyLifecyclePhase(phase)
                            if phase == .compacting || phase == .compacted {
                                conversationState.recordRuntimeActivity(
                                    kind: .contextCompaction,
                                    tone: phase == .compacting ? .working : .success,
                                    summary: phase == .compacting ? "Context compacting" : "Context compacted",
                                    detail: Self.usageDetail(for: conversationState),
                                    state: phase.rawValue,
                                    turnID: conversationState.activeTurnID
                                )
                            }
                        }

                    case .textDelta(let delta):
                        enqueueStreamDelta(delta)

                    case .text(let text):
                        enqueueStreamDelta(text)

                    case .approvalRequest(let request):
                        let approval = ToolApprovalRequest(
                            id: request.id,
                            toolName: request.toolName,
                            description: request.description,
                            parameters: request.parameters,
                            riskLevel: request.riskLevel,
                            agentID: conversationState.agentID
                        )
                        conversationState.addToolApprovalRequest(approval)
                        conversationState.recordRuntimeActivity(
                            kind: .note,
                            tone: .warning,
                            summary: "Approval required",
                            detail: request.toolName,
                            state: "pending",
                            turnID: conversationState.activeTurnID
                        )

                    case .userInputRequest(let request):
                        conversationState.addUserInputRequest(request)
                        conversationState.recordRuntimeActivity(
                            kind: .note,
                            tone: .warning,
                            summary: "Input required",
                            detail: request.questions.first?.question,
                            state: "pending",
                            turnID: conversationState.activeTurnID
                        )

                    case .toolUse(let id, let name, let input):
                        flushPendingStreamDelta()
                        let retainedInput: String
                        do {
                            retainedInput = try await Self.toolInputExecutor.run(priority: .utility) {
                                try Self.cancellableRetainedToolInput(input, limit: 32_768)
                            }
                        } catch {
                            break
                        }
                        conversationState.recordRuntimeActivity(
                            kind: .tool,
                            tone: .working,
                            summary: name,
                            detail: Self.toolInputSummary(name: name, input: retainedInput),
                            state: "started",
                            turnID: conversationState.activeTurnID
                        )
                        if !conversationState.streamingText.isEmpty {
                            let activeTurnID = conversationState.activeTurnID
                            conversationState.finishStreaming()
                            conversationState.startStreaming(
                                providerID: conversationState.activeProviderID,
                                modelID: conversationState.activeModelID
                            )
                            conversationState.markTurnStarted(turnID: activeTurnID)
                        }
                        conversationState.appendMessage(
                            ConversationMessage(
                                role: .assistant,
                                content: [.toolUse(
                                    id: id,
                                    name: name,
                                    input: retainedInput
                                )]
                            )
                        )

                    case .toolResult(let id, let content, let isError):
                        conversationState.markToolCompleted(id)
                        conversationState.recordRuntimeActivity(
                            kind: .tool,
                            tone: isError ? .error : .success,
                            summary: isError ? "Tool failed" : "Tool completed",
                            detail: Self.summarizedRuntimeText(content),
                            state: isError ? "failed" : "completed",
                            turnID: conversationState.activeTurnID
                        )
                        let retainedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
                        if isError || (!retainedContent.isEmpty && retainedContent != "Completed") {
                            conversationState.appendMessage(
                                ConversationMessage(
                                    role: .tool,
                                    content: [.toolResult(
                                        id: id,
                                        content: Self.truncatedPayload(retainedContent, limit: 65_536),
                                        isError: isError
                                    )]
                                )
                            )
                        }

                    case .usage(let inputTokens, let outputTokens, let costUSD):
                        conversationState.updateUsage(
                            inputTokens: inputTokens,
                            outputTokens: outputTokens,
                            costUSD: costUSD
                        )
                        if conversationState.currentContextTokens == nil,
                           conversationState.reportedContextWindow != nil {
                            conversationState.setCurrentContextUsage(
                                inputTokens: inputTokens,
                                outputTokens: outputTokens,
                                cachedInputTokens: 0,
                                reasoningOutputTokens: 0,
                                totalTokens: inputTokens + outputTokens,
                                contextWindow: conversationState.reportedContextWindow
                            )
                        }

                    case .contextUsage(
                        let inputTokens,
                        let outputTokens,
                        let cachedInputTokens,
                        let reasoningOutputTokens,
                        let totalTokens,
                        let contextWindow
                    ):
                        conversationState.setCurrentContextUsage(
                            inputTokens: inputTokens,
                            outputTokens: outputTokens,
                            cachedInputTokens: cachedInputTokens,
                            reasoningOutputTokens: reasoningOutputTokens,
                            totalTokens: totalTokens,
                            contextWindow: contextWindow
                        )

                    case .usageTotal(
                        let inputTokens,
                        let outputTokens,
                        let cachedInputTokens,
                        let reasoningOutputTokens,
                        let totalTokens,
                        let contextWindow
                    ):
                        conversationState.setUsageTotals(
                            inputTokens: inputTokens,
                            outputTokens: outputTokens,
                            cachedInputTokens: cachedInputTokens,
                            reasoningOutputTokens: reasoningOutputTokens,
                            totalTokens: totalTokens,
                            contextWindow: contextWindow
                        )

                    case .goalUpdated(let goal):
                        if let goal {
                            conversationState.updateGoal(goal)
                            conversationState.recordRuntimeActivity(
                                kind: .note,
                                tone: goal.status == .active ? .success : .info,
                                summary: Self.goalActivitySummary(for: goal),
                                detail: Self.summarizedRuntimeText(goal.objective),
                                state: goal.status.rawValue,
                                turnID: conversationState.activeTurnID
                            )
                        } else {
                            conversationState.clearGoal()
                            conversationState.recordRuntimeActivity(
                                kind: .note,
                                tone: .info,
                                summary: "Goal cleared",
                                state: "cleared",
                                turnID: conversationState.activeTurnID
                            )
                        }

                    case .done(let stopReason):
                        didReceiveCompletion = true
                        flushPendingStreamDelta()
                        conversationState.clearToolApprovalRequests()
                        conversationState.clearUserInputRequests()
                        conversationState.finishStreaming(stopReason: stopReason)

                    case .error(let message):
                        didReceiveError = true
                        pendingStreamDelta = ""
                        conversationState.clearToolApprovalRequests()
                        conversationState.clearUserInputRequests()
                        conversationState.setError(message)
                        conversationState.recordRuntimeActivity(
                            kind: .error,
                            tone: .error,
                            summary: "Runtime error",
                            detail: message,
                            state: "failed",
                            turnID: conversationState.activeTurnID
                        )
                    }
                }
            } catch {
                if !Task.isCancelled {
                    didReceiveError = true
                    pendingStreamDelta = ""
                    conversationState.clearToolApprovalRequests()
                    conversationState.clearUserInputRequests()
                    conversationState.setError(error.localizedDescription)
                    conversationState.recordRuntimeActivity(
                        kind: .error,
                        tone: .error,
                        summary: "Runtime error",
                        detail: error.localizedDescription,
                        state: "failed",
                        turnID: conversationState.activeTurnID
                    )
                }
            }

            if Task.isCancelled {
                flushPendingStreamDelta()
                conversationState.clearToolApprovalRequests()
                conversationState.clearUserInputRequests()
                conversationState.finishStreaming(stopReason: "cancelled")
            } else if !didReceiveCompletion && !didReceiveError {
                flushPendingStreamDelta()
                conversationState.finishStreaming()
            }

            guard let self else {
                request.onComplete?()
                return
            }

            self.activeRequests[agentID] = nil
            self.activeStates[agentID] = nil
            request.onComplete?()
            self.startNextRequestIfNeeded(for: conversationState)
        }

        activeRequests[agentID] = ActiveRequest(
            task: task,
            cancel: handle.cancel,
            steer: handle.steer,
            respondToApproval: handle.respondToApproval,
            respondToUserInput: handle.respondToUserInput,
            cancelUserInput: handle.cancelUserInput
        )
    }

    private func startNextRequestIfNeeded(for conversationState: ConversationState) {
        let agentID = conversationState.agentID
        guard activeRequests[agentID] == nil else { return }
        guard var queue = pendingRequests[agentID], !queue.isEmpty else {
            pendingRequests[agentID] = nil
            return
        }

        let next = queue.removeFirst()
        pendingRequests[agentID] = queue.isEmpty ? nil : queue
        conversationState.recordRuntimeActivity(
            kind: .queue,
            tone: .working,
            summary: "Queued prompt started",
            detail: Self.summarizedRuntimeText(next.prompt),
            state: "started",
            turnID: conversationState.activeTurnID
        )
        start(next, for: conversationState)
    }

    private static func toolInputSummary(name: String, input: String?) -> String? {
        guard let input, !input.isEmpty, input != "{}" else { return nil }
        guard let data = input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return summarizedRuntimeText(input)
        }

        let summary: String? = switch name {
        case "Read", "Edit", "Write":
            (json["file_path"] as? String).map { path in
                let short = path.components(separatedBy: "/").suffix(2).joined(separator: "/")
                var result = short
                if let offset = json["offset"] as? Int { result += ":\(offset)" }
                if let limit = json["limit"] as? Int { result += " (\(limit) lines)" }
                return result
            }
        case "Grep":
            {
                var parts: [String] = []
                if let pattern = json["pattern"] as? String { parts.append("\"\(pattern)\"") }
                if let type = json["type"] as? String { parts.append("in *.\(type)") }
                else if let glob = json["glob"] as? String { parts.append("in \(glob)") }
                return parts.isEmpty ? nil : parts.joined(separator: " ")
            }()
        case "Glob":
            json["pattern"] as? String
        case "Bash":
            (json["command"] as? String).map {
                String(($0.components(separatedBy: .newlines).first ?? $0).prefix(100))
            }
        case "Agent":
            (json["description"] as? String) ?? (json["prompt"] as? String).map { String($0.prefix(80)) }
        default:
            (json["file_path"] as? String).map {
                $0.components(separatedBy: "/").suffix(2).joined(separator: "/")
            } ?? (json["pattern"] as? String) ?? (json["command"] as? String).map { String($0.prefix(80)) }
        }

        return summary ?? summarizedRuntimeText(input)
    }

    private static func summarizedRuntimeText(_ text: String?, limit: Int = 140) -> String? {
        guard let text else { return nil }

        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else { return nil }
        guard normalized.count > limit else { return normalized }

        let endIndex = normalized.index(normalized.startIndex, offsetBy: limit)
        return String(normalized[..<endIndex]) + "…"
    }

    /// Keeps live tool input parseable after retention bounding. Cutting an
    /// encoded JSON string at an arbitrary byte produced malformed Edit/Write
    /// payloads, which meant the transcript could no longer render their code.
    nonisolated static func retainedToolInput(_ text: String, limit: Int) -> String {
        (try? cancellableRetainedToolInput(text, limit: limit))
            ?? truncatedPayload(text, limit: limit)
    }

    nonisolated private static func cancellableRetainedToolInput(
        _ text: String,
        limit: Int
    ) throws -> String {
        try Task.checkCancellation()
        guard text.utf8.count > limit else { return text }
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(value) else {
            return truncatedPayload(text, limit: limit)
        }
        try Task.checkCancellation()

        var fieldLimit = limit
        while fieldLimit > 0 {
            try Task.checkCancellation()
            let boundedValue = try boundingJSONStrings(in: value, maximum: fieldLimit)
            if let candidate = serializedJSONString(boundedValue),
               candidate.utf8.count <= limit {
                return candidate
            }
            fieldLimit /= 2
        }

        try Task.checkCancellation()
        let minimalValue = try boundingJSONStrings(in: value, maximum: 0)
        return serializedJSONString(minimalValue)
            .flatMap { $0.utf8.count <= limit ? $0 : nil }
            ?? #"{"_flowxPayloadTruncated":true}"#
    }

    nonisolated private static func serializedJSONString(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated private static func boundingJSONStrings(in value: Any, maximum: Int) throws -> Any {
        try Task.checkCancellation()
        if let string = value as? String {
            return try boundedJSONField(string, maximum: maximum)
        }
        if let dictionary = value as? [String: Any] {
            var bounded: [String: Any] = [:]
            bounded.reserveCapacity(dictionary.count)
            for (key, nestedValue) in dictionary {
                bounded[key] = try boundingJSONStrings(in: nestedValue, maximum: maximum)
            }
            return bounded
        }
        if let array = value as? [Any] {
            var bounded: [Any] = []
            bounded.reserveCapacity(array.count)
            for nestedValue in array {
                bounded.append(try boundingJSONStrings(in: nestedValue, maximum: maximum))
            }
            return bounded
        }
        return value
    }

    nonisolated private static func boundedJSONField(_ value: String, maximum: Int) throws -> String {
        guard value.utf8.count > maximum else { return value }
        guard maximum > 0 else { return "" }

        let marker = "… [FlowX retained field truncated]"
        let markerBytes = marker.utf8.count
        guard maximum > markerBytes else { return "" }

        let prefixMaximum = maximum - markerBytes
        var byteCount = 0
        var end = value.startIndex
        var characterCount = 0
        while end < value.endIndex {
            if characterCount.isMultiple(of: 1_024) {
                try Task.checkCancellation()
            }
            let next = value.index(after: end)
            let characterBytes = value[end..<next].utf8.count
            guard byteCount + characterBytes <= prefixMaximum else { break }
            byteCount += characterBytes
            end = next
            characterCount += 1
        }
        return String(value[..<end]) + marker
    }

    nonisolated private static func truncatedPayload(_ text: String, limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var byteCount = 0
        var end = text.startIndex
        while end < text.endIndex, byteCount < limit {
            let next = text.index(after: end)
            let characterBytes = text[end..<next].utf8.count
            guard byteCount + characterBytes <= limit else { break }
            byteCount += characterBytes
            end = next
        }
        return String(text[..<end]) + "\n… [FlowX truncated this retained tool payload]"
    }

    private static func usageDetail(for conversationState: ConversationState) -> String? {
        guard let currentContextTokens = conversationState.currentContextTokens,
              let contextLimit = conversationState.reportedContextWindow,
              currentContextTokens > 0,
              contextLimit > 0 else {
            return nil
        }

        return "\(formatTokenCount(currentContextTokens)) of \(formatTokenCount(contextLimit))"
    }

    private static func formatTokenCount(_ count: Int) -> String {
        switch count {
        case 1_000_000...:
            return String(format: "%.1fM", Double(count) / 1_000_000).replacingOccurrences(of: ".0", with: "")
        case 10_000...:
            return String(format: "%.1fK", Double(count) / 1_000).replacingOccurrences(of: ".0", with: "")
        case 1_000...:
            return "\(count / 1_000)K"
        default:
            return "\(count)"
        }
    }

    private func threadControls(for providerID: String) throws -> any AIProviderThreadControls {
        guard let provider = registry.provider(for: providerID) else {
            throw Self.makeError("Provider '\(providerID)' not found. Configure it in Settings.")
        }

        guard let controls = provider as? any AIProviderThreadControls else {
            throw Self.makeError("\(provider.displayName) does not support Codex thread controls.")
        }

        return controls
    }

    private static func goalActivitySummary(for goal: ConversationGoal) -> String {
        switch goal.status {
        case .active:
            "Goal active"
        case .paused:
            "Goal paused"
        case .blocked:
            "Goal blocked"
        case .usageLimited:
            "Goal usage limited"
        case .budgetLimited:
            "Goal budget limited"
        case .complete:
            "Goal complete"
        }
    }

    private static func makeError(_ message: String) -> NSError {
        NSError(domain: "ConversationService", code: 1, userInfo: [
            NSLocalizedDescriptionKey: message,
        ])
    }
}
