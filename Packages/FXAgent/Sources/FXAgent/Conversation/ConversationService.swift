import Foundation
import FXCore

@MainActor
public final class ConversationService {
    private struct PendingRequest {
        var prompt: String
        let attachments: [Attachment]
        let providerID: String
        let model: String
        let effort: String?
        let systemPrompt: String?
        let agentMode: AgentMode?
        let agentAccess: AgentAccess?
        let workingDirectory: URL?
        let resumeSessionID: String?
        let onComplete: (() -> Void)?
        let queued: Bool
    }

    private struct ActiveRequest {
        let task: Task<Void, Never>
        let cancel: @Sendable () async -> Void
        let respondToApproval: @Sendable (UUID, Bool) async -> Void
    }

    private let registry: ProviderRegistry
    private var activeRequests: [UUID: ActiveRequest] = [:]
    private var activeStates: [UUID: ConversationState] = [:]
    private var pendingRequests: [UUID: [PendingRequest]] = [:]

    public init(registry: ProviderRegistry) {
        self.registry = registry
    }

    public func send(
        prompt: String,
        attachments: [Attachment] = [],
        to conversationState: ConversationState,
        providerID: String,
        model: String,
        effort: String? = nil,
        systemPrompt: String? = nil,
        agentMode: AgentMode? = nil,
        agentAccess: AgentAccess? = nil,
        workingDirectory: URL? = nil,
        resumeSessionID: String? = nil,
        onComplete: (() -> Void)? = nil
    ) {
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
            onComplete: onComplete,
            queued: isQueued
        )

        if isQueued {
            conversationState.enqueuePrompt(prompt)
            let queuedCount = (pendingRequests[conversationState.agentID]?.count ?? 0) + 1
            conversationState.recordRuntimeActivity(
                kind: .queue,
                tone: .info,
                summary: "Prompt queued",
                detail: queuedCount == 1 ? "Next up" : "\(queuedCount) prompts waiting",
                state: "queued",
                turnID: conversationState.activeTurnID
            )
            pendingRequests[conversationState.agentID, default: []].append(request)
            return
        }

        conversationState.appendUserMessage(prompt, attachments: attachments)
        start(request, for: conversationState)
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
    }

    public func respondToToolApproval(_ approvalID: UUID, approved: Bool, for agentID: UUID) async {
        guard let activeRequest = activeRequests[agentID] else { return }
        await activeRequest.respondToApproval(approvalID, approved)
    }

    private func start(_ request: PendingRequest, for conversationState: ConversationState) {
        if request.queued {
            conversationState.beginQueuedPrompt()
            conversationState.appendUserMessage(request.prompt, attachments: request.attachments)
        }

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

            do {
                for try await event in handle.stream {
                    guard !Task.isCancelled else { break }

                    switch event {
                    case .initialized(let sessionID, let model):
                        let previousSessionID = conversationState.sessionID
                        let previousModelID = conversationState.activeModelID
                        conversationState.registerSession(sessionID, modelID: model)
                        if previousSessionID != sessionID || previousModelID != model {
                            let sessionDetail = [provider.displayName, model].filter { !$0.isEmpty }.joined(separator: " • ")
                            conversationState.recordRuntimeActivity(
                                kind: .session,
                                tone: .success,
                                summary: "Session ready",
                                detail: sessionDetail.isEmpty ? nil : sessionDetail,
                                state: "configured",
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
                        conversationState.appendStreamDelta(delta)

                    case .text(let text):
                        conversationState.appendStreamDelta(text)

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

                    case .toolUse(let id, let name, let input):
                        conversationState.recordRuntimeActivity(
                            kind: .tool,
                            tone: .working,
                            summary: name,
                            detail: Self.toolInputSummary(name: name, input: input),
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
                        conversationState.messages.append(
                            ConversationMessage(
                                role: .assistant,
                                content: [.toolUse(id: id, name: name, input: input)]
                            )
                        )

                    case .toolResult(let id, let content, let isError):
                        conversationState.recordRuntimeActivity(
                            kind: .tool,
                            tone: isError ? .error : .success,
                            summary: isError ? "Tool failed" : "Tool completed",
                            detail: Self.summarizedRuntimeText(content),
                            state: isError ? "failed" : "completed",
                            turnID: conversationState.activeTurnID
                        )
                        conversationState.messages.append(
                            ConversationMessage(
                                role: .tool,
                                content: [.toolResult(id: id, content: content, isError: isError)]
                            )
                        )

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

                    case .done(let stopReason):
                        didReceiveCompletion = true
                        conversationState.clearToolApprovalRequests()
                        conversationState.finishStreaming(stopReason: stopReason)

                    case .error(let message):
                        didReceiveError = true
                        conversationState.clearToolApprovalRequests()
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
                    conversationState.clearToolApprovalRequests()
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
                conversationState.clearToolApprovalRequests()
                conversationState.finishStreaming(stopReason: "cancelled")
            } else if !didReceiveCompletion && !didReceiveError {
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
            respondToApproval: handle.respondToApproval
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
}
