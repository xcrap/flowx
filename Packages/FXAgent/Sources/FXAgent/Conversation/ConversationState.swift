import Foundation
import FXCore

@Observable
@MainActor
public final class ConversationState {
    public static let maxRetainedMessages = 250
    private static let maxRuntimeActivities = 200
    private static let maxVisibleQueuedPromptPreviews = 3

    public let agentID: UUID
    public var messages: [ConversationMessage] = []
    public var runtimeActivities: [ConversationRuntimeActivity] = []
    public var runtimePhase: ProviderSessionPhase = .idle
    public var streamingText: String = ""
    public var inputText: String = ""
    public var error: String?
    public var sessionID: String?
    public var activeProviderID: String?
    public var activeModelID: String?
    public var activeTurnID: String?
    public var lastStopReason: String?
    public var lastRuntimeEventAt: Date?
    public var totalCostUSD: Double = 0
    public var totalInputTokens: Int = 0
    public var totalOutputTokens: Int = 0
    public var totalCachedInputTokens: Int = 0
    public var totalReasoningOutputTokens: Int = 0
    public var totalTokens: Int = 0
    public var reportedContextWindow: Int?
    public var configuredContextWindow: Int?
    public var currentContextTokens: Int?
    public var queuedPromptCount: Int = 0
    public var queuedPromptPreviews: [String] = []
    public var pendingToolApprovals: [ToolApprovalRequest] = []
    public var pendingAttachments: [Attachment] = []

    public init(agentID: UUID) {
        self.agentID = agentID
    }

    public var isStreaming: Bool {
        runtimePhase.isWorking
    }

    public var statusLabel: String {
        runtimePhase.statusLabel
    }

    public func appendUserMessage(_ text: String, attachments: [Attachment] = []) {
        var content: [MessageContent] = []
        for attachment in attachments where attachment.isImage {
            content.append(.image(data: Data(), mimeType: attachment.mimeType))
        }
        content.append(.text(text))
        appendMessage(ConversationMessage(role: .user, content: content))
    }

    public func appendMessage(_ message: ConversationMessage) {
        messages.append(message)
        trimRetainedMessages()
    }

    public func replaceMessages(_ retainedMessages: [ConversationMessage]) {
        messages = Array(retainedMessages.suffix(Self.maxRetainedMessages))
    }

    public func addAttachment(_ attachment: Attachment) {
        pendingAttachments.append(attachment)
    }

    public func removeAttachment(_ id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    public func clearAttachments() {
        pendingAttachments.removeAll()
    }

    public func recordRuntimeActivity(
        kind: ConversationRuntimeActivityKind,
        tone: ConversationRuntimeActivityTone,
        summary: String,
        detail: String? = nil,
        state: String? = nil,
        turnID: String? = nil
    ) {
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSummary.isEmpty else { return }

        let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        if let last = runtimeActivities.last,
           last.kind == kind,
           last.tone == tone,
           last.summary == trimmedSummary,
           last.detail == trimmedDetail,
           last.state == state,
           last.turnID == turnID {
            runtimeActivities[runtimeActivities.count - 1].timestamp = Date()
            lastRuntimeEventAt = runtimeActivities.last?.timestamp
            return
        }

        runtimeActivities.append(
            ConversationRuntimeActivity(
                kind: kind,
                tone: tone,
                summary: trimmedSummary,
                detail: trimmedDetail,
                state: state,
                turnID: turnID
            )
        )

        if runtimeActivities.count > Self.maxRuntimeActivities {
            runtimeActivities.removeFirst(runtimeActivities.count - Self.maxRuntimeActivities)
        }

        lastRuntimeEventAt = runtimeActivities.last?.timestamp
    }

    public func startStreaming(providerID: String? = nil, modelID: String? = nil) {
        runtimePhase = .preparing
        streamingText = ""
        error = nil
        currentContextTokens = nil
        activeTurnID = nil
        lastStopReason = nil
        lastRuntimeEventAt = Date()
        if let providerID {
            activeProviderID = providerID
        }
        if let modelID {
            activeModelID = modelID
        }
    }

    public func registerSession(_ sessionID: String, modelID: String? = nil) {
        self.sessionID = sessionID
        if let modelID, !modelID.isEmpty {
            activeModelID = modelID
        }
        lastRuntimeEventAt = Date()
    }

    public func markTurnStarted(turnID: String? = nil) {
        if let turnID, !turnID.isEmpty {
            activeTurnID = turnID
        }
        if runtimePhase != .cancelling {
            runtimePhase = .responding
        }
        lastRuntimeEventAt = Date()
    }

    public func markCancellationRequested() {
        guard isStreaming else { return }
        runtimePhase = .cancelling
        lastRuntimeEventAt = Date()
    }

    public func applyLifecyclePhase(_ phase: ProviderSessionPhase) {
        guard runtimePhase != .cancelling || phase == .idle || phase == .failed else { return }
        runtimePhase = phase
        lastRuntimeEventAt = Date()
    }

    public func appendStreamDelta(_ delta: String) {
        if runtimePhase == .preparing || runtimePhase == .compacting || runtimePhase == .compacted {
            runtimePhase = .responding
        }
        lastRuntimeEventAt = Date()
        streamingText += delta
    }

    public func finishStreaming(stopReason: String? = nil) {
        if !streamingText.isEmpty {
            appendMessage(ConversationMessage(role: .assistant, content: [.text(streamingText)]))
        }
        streamingText = ""

        if stopReason == "tool_use" {
            if runtimePhase != .cancelling {
                runtimePhase = .responding
            }
        } else {
            runtimePhase = .idle
            activeTurnID = nil
        }

        if let stopReason, !stopReason.isEmpty {
            lastStopReason = stopReason
        }
        lastRuntimeEventAt = Date()
    }

    public func setError(_ errorMessage: String) {
        error = errorMessage
        streamingText = ""
        runtimePhase = .failed
        activeTurnID = nil
        lastRuntimeEventAt = Date()
    }

    public func dismissError() {
        error = nil
        if runtimePhase == .failed {
            runtimePhase = .idle
        }
    }

    public func updateUsage(inputTokens: Int, outputTokens: Int, costUSD: Double?) {
        totalInputTokens += inputTokens
        totalOutputTokens += outputTokens
        totalTokens = totalInputTokens + totalOutputTokens + totalCachedInputTokens + totalReasoningOutputTokens
        if let costUSD {
            totalCostUSD += costUSD
        }
    }

    public func setUsageTotals(
        inputTokens: Int,
        outputTokens: Int,
        cachedInputTokens: Int,
        reasoningOutputTokens: Int,
        totalTokens: Int,
        contextWindow: Int?
    ) {
        totalInputTokens = inputTokens
        totalOutputTokens = outputTokens
        totalCachedInputTokens = cachedInputTokens
        totalReasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
        if configuredContextWindow == nil, let contextWindow, contextWindow > 0 {
            reportedContextWindow = contextWindow
        }
    }

    public func setCurrentContextUsage(
        inputTokens: Int,
        outputTokens: Int,
        cachedInputTokens: Int,
        reasoningOutputTokens: Int,
        totalTokens: Int,
        contextWindow: Int?
    ) {
        currentContextTokens = max(
            totalTokens,
            inputTokens + outputTokens + cachedInputTokens + reasoningOutputTokens
        )
        if configuredContextWindow == nil, let contextWindow, contextWindow > 0 {
            reportedContextWindow = contextWindow
        }
    }

    public func enqueuePrompt(_ prompt: String) {
        queuedPromptPreviews.append(Self.queuedPromptPreview(for: prompt))
        queuedPromptCount = queuedPromptPreviews.count
    }

    @discardableResult
    public func beginQueuedPrompt() -> String? {
        guard !queuedPromptPreviews.isEmpty else {
            queuedPromptCount = 0
            return nil
        }

        let prompt = queuedPromptPreviews.removeFirst()
        queuedPromptCount = queuedPromptPreviews.count
        return prompt
    }

    public func updateQueuedPrompt(at index: Int, prompt: String) {
        guard index >= 0, index < queuedPromptPreviews.count else { return }
        queuedPromptPreviews[index] = Self.queuedPromptPreview(for: prompt)
    }

    public func removeQueuedPrompt(at index: Int) {
        guard index >= 0, index < queuedPromptPreviews.count else { return }
        queuedPromptPreviews.remove(at: index)
        queuedPromptCount = queuedPromptPreviews.count
    }

    public func clearQueuedPrompts() {
        queuedPromptPreviews.removeAll()
        queuedPromptCount = 0
    }

    public func addToolApprovalRequest(_ request: ToolApprovalRequest) {
        if let existingIndex = pendingToolApprovals.firstIndex(where: { $0.id == request.id }) {
            pendingToolApprovals[existingIndex] = request
        } else {
            pendingToolApprovals.append(request)
        }
    }

    @discardableResult
    public func removeToolApprovalRequest(_ id: UUID) -> ToolApprovalRequest? {
        guard let index = pendingToolApprovals.firstIndex(where: { $0.id == id }) else { return nil }
        return pendingToolApprovals.remove(at: index)
    }

    public func clearToolApprovalRequests() {
        pendingToolApprovals.removeAll()
    }

    public func resetConversation() {
        messages.removeAll()
        runtimePhase = .idle
        streamingText = ""
        inputText = ""
        error = nil
        sessionID = nil
        activeProviderID = nil
        activeModelID = nil
        activeTurnID = nil
        lastStopReason = nil
        lastRuntimeEventAt = nil
        totalCostUSD = 0
        totalInputTokens = 0
        totalOutputTokens = 0
        totalCachedInputTokens = 0
        totalReasoningOutputTokens = 0
        totalTokens = 0
        reportedContextWindow = nil
        currentContextTokens = nil
        queuedPromptCount = 0
        queuedPromptPreviews.removeAll()
        pendingToolApprovals.removeAll()
        pendingAttachments.removeAll()
        runtimeActivities.removeAll()
    }

    public var lastActivityAt: Date? {
        messages.last?.timestamp
    }

    public var lastVisibleActivityAt: Date? {
        [messages.last?.timestamp, latestRuntimeActivity?.timestamp].compactMap { $0 }.max()
    }

    public var latestUserPrompt: String? {
        messages
            .reversed()
            .first(where: { $0.role == .user })?
            .textContent
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var latestPreviewText: String? {
        if let latestUserPrompt, !latestUserPrompt.isEmpty {
            return latestUserPrompt
        }

        return messages
            .reversed()
            .compactMap { message in
                let text = message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
            .first
            ?? latestRuntimeActivity?.summary
    }

    public var nextQueuedPromptPreview: String? {
        queuedPromptPreviews.first
    }

    public var pendingToolApprovalCount: Int {
        pendingToolApprovals.count
    }

    public var latestRuntimeActivity: ConversationRuntimeActivity? {
        runtimeActivities.last
    }

    public var recentRuntimeActivities: [ConversationRuntimeActivity] {
        var seen = Set<ConversationRuntimeActivityKind>()
        var deduped: [ConversationRuntimeActivity] = []

        for activity in runtimeActivities.suffix(8).reversed() {
            guard activity.kind != .queue else { continue }

            if activity.kind == .session || activity.kind == .contextCompaction {
                guard seen.insert(activity.kind).inserted else { continue }
            }

            deduped.append(activity)
        }

        return Array(deduped.reversed().suffix(4))
    }

    public var visibleQueuedPromptPreviews: [String] {
        Array(queuedPromptPreviews.prefix(Self.maxVisibleQueuedPromptPreviews))
    }

    public var queuedPromptOverflowCount: Int {
        max(0, queuedPromptPreviews.count - Self.maxVisibleQueuedPromptPreviews)
    }

    private static func queuedPromptPreview(for prompt: String) -> String {
        let normalized = prompt
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.count <= 80 {
            return normalized
        }
        let endIndex = normalized.index(normalized.startIndex, offsetBy: 80)
        return String(normalized[..<endIndex]) + "…"
    }

    private func trimRetainedMessages() {
        guard messages.count > Self.maxRetainedMessages else { return }
        messages.removeFirst(messages.count - Self.maxRetainedMessages)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
