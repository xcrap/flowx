import AppKit
import SwiftUI
import FXAgent
import FXDesign
import FXCore

private struct MessageRenderKey: Hashable {
    let agentID: UUID
    let revision: Int
}

struct ConversationView: View {
    @Environment(AppState.self) private var appState
    @Bindable var agent: AgentInfo

    @State private var editingQueuedPromptIndex: Int?
    @State private var editingQueuedPromptText = ""
    @State private var initialScrollRestorePending = true
    @State private var renderedItems: [ConversationDisplayItem] = []

    private let maxContentWidth: CGFloat = FXLayout.readableContentWidth
    private static let exactTokenFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(renderedItems) { item in
                        displayItemView(for: item)
                            .id(item.scrollID)
                            .padding(.bottom, displayItemSpacing(for: item))
                    }

                    if !agent.conversationState.streamingText.isEmpty {
                        MessageBubble(streamingText: agent.conversationState.streamingText)
                            .id("streaming-message")
                            .padding(.bottom, FXSpacing.xl)
                    } else if agent.isStreaming {
                        streamingIndicator
                            .id("streaming-indicator")
                            .padding(.bottom, FXSpacing.xl)
                    }

                    if let error = agent.conversationState.error {
                        errorCard(error)
                            .id("conversation-error")
                            .padding(.bottom, FXSpacing.xl)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomScrollID)
                }
                .scrollTargetLayout()
                .frame(maxWidth: maxContentWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, FXSpacing.xxl)
                .padding(.top, FXSpacing.xxl)
                .padding(.bottom, FXSpacing.md)
                .background(
                    ConversationScrollBridge(
                        restoreKey: agent.id,
                        desiredOffset: agent.workspace.conversationScrollOffset,
                        stickToBottom: agent.workspace.conversationPinnedToBottom,
                        contentVersion: contentVersion
                    ) { offset, maxOffset in
                        updateScrollState(offset: offset, maxOffset: maxOffset)
                    } onInitialRestoreCompleted: {
                        initialScrollRestorePending = false
                    }
                )
            }
            .scrollContentBackground(.hidden)
            .opacity(initialScrollRestorePending ? 0 : 1)
            .allowsHitTesting(!initialScrollRestorePending)

            if !agent.conversationState.pendingUserInputRequests.isEmpty {
                ProviderUserInputTray(
                    requests: agent.conversationState.pendingUserInputRequests,
                    onSubmit: { request, answers in
                        appState.respondToUserInput(request.id, answers: answers, for: agent)
                    },
                    onCancel: { request in
                        if request.cancellationBehavior == .respondToProvider {
                            appState.cancelUserInput(request.id, for: agent)
                        } else {
                            appState.cancelPrompt(for: agent)
                        }
                    }
                )
            }

            if agent.conversationState.pendingToolApprovalCount > 0 {
                approvalTray
            }

            if agent.conversationState.queuedPromptCount > 0 {
                queueTray
            }

            if showsContextBar {
                contextBar
            }

            ChatInputBar(agent: agent)
        }
        .background(FXColors.contentBg)
        .task(id: MessageRenderKey(agentID: agent.id, revision: agent.conversationState.messageRevision)) {
            renderedItems = Self.makeDisplayItems(from: agent.messages)
        }
        .onDisappear {
            if appState.isBootstrapped {
                appState.scheduleSave()
            }
        }
    }

    private var bottomScrollID: String { "conversation-bottom" }

    private var contentVersion: Int {
        var version = agent.conversationState.messageRevision
        version = version &* 31 &+ agent.conversationState.streamingRevision
        version += agent.isStreaming ? 1 : 0
        version += agent.conversationState.error == nil ? 0 : 1
        if let activeGoal = agent.conversationState.activeGoal {
            version = version &* 31 &+ activeGoal.updatedAt
            version = version &* 31 &+ activeGoal.status.rawValue.hashValue
        }
        return version
    }

    private static func makeDisplayItems(from messages: [ConversationMessage]) -> [ConversationDisplayItem] {
        var items: [ConversationDisplayItem] = []
        var toolGroup: [ConversationMessage] = []

        func flushToolGroup() {
            guard let first = toolGroup.first else { return }
            items.append(.toolGroup(id: first.id, messages: toolGroup))
            toolGroup.removeAll()
        }

        for message in messages {
            if Self.isGroupedToolEventMessage(message) {
                toolGroup.append(message)
            } else {
                flushToolGroup()
                items.append(.message(message))
            }
        }

        flushToolGroup()
        return items
    }

    @ViewBuilder
    private func displayItemView(for item: ConversationDisplayItem) -> some View {
        switch item {
        case .message(let message):
            MessageBubble(message: message)
        case .toolGroup(_, let messages):
            ToolActivityGroup(messages: messages)
        }
    }

    private func displayItemSpacing(for item: ConversationDisplayItem) -> CGFloat {
        switch item {
        case .message(let message):
            return messageSpacing(for: message)
        case .toolGroup:
            return FXSpacing.sm
        }
    }

    private func messageSpacing(for message: ConversationMessage) -> CGFloat {
        isToolEventMessage(message) ? FXSpacing.sm : FXSpacing.xl
    }

    private func isToolEventMessage(_ message: ConversationMessage) -> Bool {
        !message.content.isEmpty && message.content.allSatisfy { item in
            switch item {
            case .toolUse(_, let name, _):
                name != "AskUserQuestion"
            case .toolResult:
                true
            default:
                false
            }
        }
    }

    private static func isGroupedToolEventMessage(_ message: ConversationMessage) -> Bool {
        !message.content.isEmpty && message.content.allSatisfy { item in
            switch item {
            case .toolUse(_, let name, _):
                // Questions are conversation content, not background tool
                // noise. Keep them as full transcript cards so the exact
                // thread always shows what Claude asked.
                name != "AskUserQuestion"
            case .toolResult(_, _, let isError):
                !isError
            default:
                false
            }
        }
    }

    private var showsContextBar: Bool {
        agent.conversationState.queuedPromptCount > 0
            || agent.conversationState.pendingToolApprovalCount > 0
            || !agent.conversationState.pendingUserInputRequests.isEmpty
            || agent.conversationState.activeGoal != nil
            || agent.shouldShowStatusIndicator
            || (usagePercent ?? 0) >= 70
    }

    private var hasUsageData: Bool {
        (agent.conversationState.currentContextTokens ?? 0) > 0
            || agent.conversationState.totalTokens > 0
            || agent.conversationState.totalReasoningOutputTokens > 0
            || agent.conversationState.totalCachedInputTokens > 0
    }

    private var contextLimitForDisplay: Int? {
        if let configured = agent.conversationState.configuredContextWindow, configured > 0 {
            return configured
        }
        if let reported = agent.conversationState.reportedContextWindow, reported > 0 {
            return reported
        }
        return nil
    }

    private var usagePercent: Double? {
        guard let contextLimit = contextLimitForDisplay,
              contextLimit > 0,
              let currentContextTokens = agent.conversationState.currentContextTokens,
              currentContextTokens > 0 else {
            return nil
        }

        return min(100, Double(currentContextTokens) / Double(contextLimit) * 100)
    }

    private var usagePercentLabel: String? {
        guard let usagePercent else { return nil }

        switch usagePercent {
        case ..<1:
            return "<1%"
        case ..<10:
            let formatted = String(format: "%.1f", usagePercent)
                .replacingOccurrences(of: ".0", with: "")
            return "\(formatted)%"
        default:
            return "\(Int(usagePercent.rounded()))%"
        }
    }

    private var usageStatusText: String? {
        guard let contextLimit = contextLimitForDisplay,
              contextLimit > 0,
              let currentContextTokens = agent.conversationState.currentContextTokens,
              currentContextTokens > 0,
              let usagePercentLabel else {
            return nil
        }

        return "Current turn \(formatExactTokenCount(currentContextTokens)) of \(formatExactTokenCount(contextLimit)) tokens (\(usagePercentLabel))"
    }

    private var usageSummaryText: String {
        var pieces: [String] = []

        if let currentContextTokens = agent.conversationState.currentContextTokens, currentContextTokens > 0 {
            pieces.append("\(formatTokenCount(currentContextTokens)) last turn")
        }
        if agent.conversationState.totalTokens > 0 {
            pieces.append("\(formatTokenCount(agent.conversationState.totalTokens)) total")
        }
        if agent.conversationState.totalReasoningOutputTokens > 0 {
            pieces.append("\(formatTokenCount(agent.conversationState.totalReasoningOutputTokens)) reasoning")
        }
        if agent.conversationState.totalCachedInputTokens > 0 {
            pieces.append("\(formatTokenCount(agent.conversationState.totalCachedInputTokens)) cached")
        }

        return pieces.joined(separator: " • ")
    }

    private var runtimeStatusColor: Color {
        switch agent.status {
        case .waitingForInput, .waitingForApproval:
            return FXColors.warning
        case .completed:
            return FXColors.success
        case .error:
            return FXColors.error
        case .idle:
            return FXColors.fgTertiary
        case .running:
            return switch agent.conversationState.runtimePhase {
            case .compacting, .cancelling:
                FXColors.warning
            case .compacted:
                FXColors.info
            case .failed:
                FXColors.error
            case .idle, .preparing, .responding:
                FXColors.accent
            }
        }
    }

    private var runtimeStatusLabel: String {
        switch agent.status {
        case .waitingForInput: "Waiting for input"
        case .waitingForApproval: "Approval needed"
        case .completed: "Done"
        case .error: "Error"
        case .idle: "Idle"
        case .running:
            agent.conversationState.isStreaming
                ? agent.conversationState.statusLabel
                : "Running"
        }
    }

    private var isRecoverableError: Bool {
        guard let error = agent.conversationState.error?.lowercased() else { return false }
        let nonRecoverable = ["not found", "install with", "configure it in settings", "failed to start"]
        return !nonRecoverable.contains(where: { error.contains($0) })
    }

    private var isStaleSessionError: Bool {
        guard let error = agent.conversationState.error?.lowercased() else { return false }

        let sessionTerms = ["session", "resume", "thread", "conversation"]
        let staleTerms = ["not found", "not ready", "invalid", "expired", "no such", "does not exist", "unknown"]

        return sessionTerms.contains(where: { error.contains($0) })
            && staleTerms.contains(where: { error.contains($0) })
    }

    private var streamingIndicator: some View {
        HStack {
            HStack(spacing: FXSpacing.sm) {
                TypingIndicator()
            }
            .padding(.horizontal, FXSpacing.lg)
            .padding(.vertical, FXSpacing.md)
            .background(FXColors.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: FXRadii.xl))
            .overlay(
                RoundedRectangle(cornerRadius: FXRadii.xl)
                    .strokeBorder(FXColors.border, lineWidth: 0.5)
            )

            Spacer(minLength: 80)
        }
    }

    private var queueTray: some View {
        VStack(alignment: .leading, spacing: FXSpacing.md) {
            HStack(spacing: FXSpacing.sm) {
                Label(
                    agent.conversationState.queuedPromptCount == 1
                        ? "1 prompt waiting"
                        : "\(agent.conversationState.queuedPromptCount) prompts waiting",
                    systemImage: "hourglass.bottomhalf.filled"
                )
                .font(FXTypography.captionMedium)
                .foregroundStyle(FXColors.fgSecondary)

                Spacer()

                Text("Queued")
                    .font(FXTypography.monoSmall)
                    .foregroundStyle(FXColors.fgTertiary)
            }

            VStack(alignment: .leading, spacing: FXSpacing.sm) {
                ForEach(Array(agent.conversationState.visibleQueuedPromptPreviews.enumerated()), id: \.offset) { index, preview in
                    VStack(alignment: .leading, spacing: FXSpacing.sm) {
                        HStack(alignment: .top, spacing: FXSpacing.sm) {
                            Circle()
                                .fill((index == 0 ? FXColors.info : FXColors.fgQuaternary).opacity(index == 0 ? 0.9 : 0.6))
                                .frame(width: 6, height: 6)
                                .padding(.top, 6)

                            Text(preview)
                                .font(FXTypography.caption)
                                .foregroundStyle(FXColors.fgSecondary)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            if index == 0 {
                                Text("next")
                                    .font(FXTypography.monoSmall)
                                    .foregroundStyle(FXColors.fgTertiary)
                            }

                            Button(action: {
                                beginEditingQueuedPrompt(at: index)
                            }) {
                                Text("Edit")
                                    .font(FXTypography.captionMedium)
                                    .foregroundStyle(FXColors.fgTertiary)
                            }
                            .buttonStyle(.plain)
                            .help("Edit queued prompt")

                            Button(action: {
                                if editingQueuedPromptIndex == index {
                                    cancelEditingQueuedPrompt()
                                }
                                appState.removeQueuedPrompt(at: index, for: agent)
                            }) {
                                Image(systemName: "xmark")
                                    .font(FXTypography.icon(.micro))
                                    .foregroundStyle(FXColors.fgTertiary)
                                    .frame(width: 16, height: 16)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Remove from queue")
                        }

                        if editingQueuedPromptIndex == index {
                            VStack(alignment: .leading, spacing: FXSpacing.sm) {
                                TextField("Edit queued prompt", text: $editingQueuedPromptText, axis: .vertical)
                                    .textFieldStyle(.plain)
                                    .font(FXTypography.body)
                                    .foregroundStyle(FXColors.fg)
                                    .lineLimit(2...6)
                                    .padding(.horizontal, FXSpacing.md)
                                    .padding(.vertical, FXSpacing.sm)
                                    .background(FXColors.bgSurface)
                                    .clipShape(RoundedRectangle(cornerRadius: FXRadii.md))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: FXRadii.md)
                                            .strokeBorder(FXColors.borderSubtle, lineWidth: 0.5)
                                    )

                                HStack(spacing: FXSpacing.sm) {
                                    Button(action: cancelEditingQueuedPrompt) {
                                        Text("Cancel")
                                            .font(FXTypography.captionMedium)
                                            .foregroundStyle(FXColors.fgTertiary)
                                    }
                                    .buttonStyle(.plain)

                                    Button(action: saveQueuedPromptEdit) {
                                        Text("Save")
                                            .font(FXTypography.captionMedium)
                                            .foregroundStyle(FXColors.accent)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(editingQueuedPromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                            }
                            .padding(.leading, FXSpacing.lg)
                        }
                    }
                }

                if agent.conversationState.queuedPromptOverflowCount > 0 {
                    Text("+\(agent.conversationState.queuedPromptOverflowCount) more")
                        .font(FXTypography.caption)
                        .foregroundStyle(FXColors.fgTertiary)
                }
            }
        }
        .padding(.top, FXSpacing.md)
        .padding(.bottom, FXSpacing.sm)
        .frame(maxWidth: maxContentWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, FXSpacing.xxl)
    }

    private var approvalTray: some View {
        VStack(alignment: .leading, spacing: FXSpacing.md) {
            HStack(spacing: FXSpacing.sm) {
                Label(
                    agent.conversationState.pendingToolApprovalCount == 1
                        ? "1 approval required"
                        : "\(agent.conversationState.pendingToolApprovalCount) approvals required",
                    systemImage: "hand.raised.fill"
                )
                .font(FXTypography.captionMedium)
                .foregroundStyle(FXColors.fgSecondary)

                Spacer()

                Text("Supervised")
                    .font(FXTypography.monoSmall)
                    .foregroundStyle(FXColors.fgTertiary)
            }

            VStack(alignment: .leading, spacing: FXSpacing.sm) {
                ForEach(agent.conversationState.pendingToolApprovals) { approval in
                    VStack(alignment: .leading, spacing: FXSpacing.sm) {
                        HStack(spacing: FXSpacing.sm) {
                            Text(approval.toolName)
                                .font(FXTypography.bodyMedium)
                                .foregroundStyle(FXColors.fg)

                            riskBadge(for: approval.riskLevel)

                            Spacer(minLength: 0)
                        }

                        Text(approval.description)
                            .font(FXTypography.caption)
                            .foregroundStyle(FXColors.fgSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if !approval.parameters.isEmpty {
                            VStack(alignment: .leading, spacing: FXSpacing.xxs) {
                                ForEach(approval.parameters.keys.sorted(), id: \.self) { key in
                                    if let value = approval.parameters[key] {
                                        HStack(alignment: .top, spacing: FXSpacing.sm) {
                                            Text(key.uppercased())
                                                .font(FXTypography.monoSmall)
                                                .foregroundStyle(FXColors.fgTertiary)
                                                .frame(width: 58, alignment: .leading)

                                            Text(value)
                                                .font(FXTypography.monoSmall)
                                                .foregroundStyle(FXColors.fgSecondary)
                                                .textSelection(.enabled)
                                                .lineLimit(4)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, FXSpacing.md)
                            .padding(.vertical, FXSpacing.sm)
                            .background(FXColors.bgSurface)
                            .clipShape(RoundedRectangle(cornerRadius: FXRadii.md))
                            .overlay(
                                RoundedRectangle(cornerRadius: FXRadii.md)
                                    .strokeBorder(FXColors.borderSubtle, lineWidth: 0.5)
                            )
                        }

                        HStack(spacing: FXSpacing.sm) {
                            actionPill(title: "Approve", icon: "checkmark", tint: FXColors.success) {
                                appState.respondToToolApproval(approval.id, approved: true, for: agent)
                            }

                            actionPill(title: "Deny", icon: "xmark", tint: FXColors.error) {
                                appState.respondToToolApproval(approval.id, approved: false, for: agent)
                            }

                            Spacer(minLength: 0)
                        }
                    }
                    .padding(FXSpacing.lg)
                    .background(FXColors.warning.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: FXRadii.xl))
                    .overlay(
                        RoundedRectangle(cornerRadius: FXRadii.xl)
                            .strokeBorder(FXColors.warning.opacity(0.18), lineWidth: 0.5)
                    )
                }
            }
        }
        .padding(.top, FXSpacing.md)
        .padding(.bottom, FXSpacing.sm)
        .frame(maxWidth: maxContentWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, FXSpacing.xxl)
    }

    private var contextBar: some View {
        VStack(alignment: .leading, spacing: FXSpacing.sm) {
            if let activeGoal = agent.conversationState.activeGoal {
                goalRow(activeGoal)
            }

            HStack(spacing: FXSpacing.sm) {
                if agent.shouldShowStatusIndicator {
                    statusPill
                }

                if agent.conversationState.queuedPromptCount > 0 {
                    let count = agent.conversationState.queuedPromptCount
                    FXBadge(count == 1 ? "1 queued" : "\(count) queued", tone: .warning)
                }

                if agent.conversationState.pendingToolApprovalCount > 1 {
                    let count = agent.conversationState.pendingToolApprovalCount
                    FXBadge("\(count) approvals needed", tone: .warning)
                }

                if agent.conversationState.pendingUserInputRequests.count > 1 {
                    let count = agent.conversationState.pendingUserInputRequests.count
                    FXBadge("\(count) inputs needed", tone: .warning)
                }

                if let usagePercentLabel, (usagePercent ?? 0) >= 70 {
                    FXBadge("\(usagePercentLabel) context", tone: .warning)
                }

                Spacer()
            }

            if agent.isStreaming, let usageStatusText {
                Text(usageStatusText)
                    .font(FXTypography.monoSmall)
                    .foregroundStyle(FXColors.fgTertiary)
            } else if agent.isStreaming, hasUsageData {
                Text(usageSummaryText)
                    .font(FXTypography.monoSmall)
                    .foregroundStyle(FXColors.fgTertiary)
            } else if agent.isStreaming {
                Text("Waiting for provider usage…")
                    .font(FXTypography.monoSmall)
                    .foregroundStyle(FXColors.fgTertiary)
            }
        }
        .padding(
            .top,
            (agent.conversationState.queuedPromptCount > 0
                || agent.conversationState.pendingToolApprovalCount > 0
                || !agent.conversationState.pendingUserInputRequests.isEmpty
                || agent.conversationState.activeGoal != nil)
                ? 0
                : FXSpacing.md
        )
        .padding(.bottom, FXSpacing.sm)
        .frame(maxWidth: maxContentWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, FXSpacing.xxl)
    }

    private func goalRow(_ goal: ConversationGoal) -> some View {
        HStack(spacing: FXSpacing.sm) {
            Image(systemName: "target")
                .font(FXTypography.icon(.regular))
                .foregroundStyle(FXColors.accent)
                .frame(width: 18, height: 18)

            Text("Goal")
                .font(FXTypography.captionMedium)
                .foregroundStyle(FXColors.fgSecondary)

            Text(goal.objective)
                .font(FXTypography.caption)
                .foregroundStyle(FXColors.fg)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: FXSpacing.sm)

            if let goalMetaText = goalMetaText(for: goal) {
                Text(goalMetaText)
                    .font(FXTypography.monoSmall)
                    .foregroundStyle(FXColors.fgTertiary)
                    .lineLimit(1)
            }

            FXBadge(goal.status.label, tone: goalBadgeTone(for: goal.status))
        }
        .padding(.horizontal, FXSpacing.sm)
        .padding(.vertical, FXSpacing.xs)
        .background(FXColors.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: FXRadii.sm, style: .continuous))
    }

    private func goalMetaText(for goal: ConversationGoal) -> String? {
        if let tokenBudget = goal.tokenBudget, tokenBudget > 0 {
            return "\(formatTokenCount(goal.tokensUsed))/\(formatTokenCount(tokenBudget))"
        }

        if goal.tokensUsed > 0 {
            return "\(formatTokenCount(goal.tokensUsed)) tokens"
        }

        return nil
    }

    private func goalBadgeTone(for status: ConversationGoalStatus) -> FXBadgeTone {
        switch status {
        case .active:
            .success
        case .paused:
            .warning
        case .blocked, .usageLimited, .budgetLimited:
            .error
        case .complete:
            .info
        }
    }

    private var statusPill: some View {
        HStack(spacing: FXSpacing.xs) {
            Circle()
                .fill(runtimeStatusColor)
                .frame(width: 6, height: 6)

            Text(runtimeStatusLabel)
                .font(FXTypography.monoSmall)
                .foregroundStyle(runtimeStatusColor)
        }
        .padding(.horizontal, FXSpacing.sm)
        .padding(.vertical, FXSpacing.xxs)
        .background(FXColors.bgSurface)
        .clipShape(Capsule())
    }

    private func errorCard(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: FXSpacing.md) {
            HStack(alignment: .top, spacing: FXSpacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(FXTypography.icon(.regular))
                    .foregroundStyle(FXColors.error)
                    .frame(width: 20, height: 20)

                Text(error)
                    .font(FXTypography.body)
                    .foregroundStyle(FXColors.error)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: FXSpacing.sm) {
                if isStaleSessionError, agent.conversationState.sessionID != nil {
                    actionPill(title: "Restart session", icon: "arrow.clockwise.circle", tint: FXColors.error) {
                        appState.restartConversationSession(for: agent)
                    }
                } else if isRecoverableError, let sessionID = agent.conversationState.sessionID, !sessionID.isEmpty {
                    actionPill(title: "Resume session", icon: "arrow.clockwise", tint: FXColors.error) {
                        appState.resumeConversation(for: agent)
                    }
                } else if isRecoverableError, let prompt = agent.conversationState.latestUserPrompt, !prompt.isEmpty {
                    actionPill(title: "Retry", icon: "arrow.counterclockwise", tint: FXColors.error) {
                        appState.retryLastPrompt(for: agent)
                    }
                }

                actionPill(title: "Dismiss", icon: nil, tint: FXColors.fgSecondary) {
                    appState.dismissConversationError(for: agent)
                }

                Spacer(minLength: 0)
            }
        }
        .padding(FXSpacing.lg)
        .background(FXColors.error.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: FXRadii.xl))
        .overlay(
            RoundedRectangle(cornerRadius: FXRadii.xl)
                .strokeBorder(FXColors.error.opacity(0.18), lineWidth: 0.5)
        )
    }

    private func riskBadge(for riskLevel: ToolRiskLevel) -> some View {
        let tint: Color
        switch riskLevel {
        case .safe:
            tint = FXColors.info
        case .moderate:
            tint = FXColors.warning
        case .dangerous:
            tint = FXColors.error
        }

        return Text(riskLevel.rawValue.capitalized)
            .font(FXTypography.monoSmall)
            .foregroundStyle(tint)
            .padding(.horizontal, FXSpacing.xs)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
    }

    private func actionPill(title: String, icon: String?, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: FXSpacing.xs) {
                if let icon {
                    Image(systemName: icon)
                        .font(FXTypography.icon(.micro))
                }

                Text(title)
                    .font(FXTypography.captionMedium)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, FXSpacing.sm)
            .padding(.vertical, FXSpacing.xxs)
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func beginEditingQueuedPrompt(at index: Int) {
        editingQueuedPromptIndex = index
        editingQueuedPromptText = appState.queuedPromptText(at: index, for: agent)
            ?? agent.conversationState.visibleQueuedPromptPreviews[index]
    }

    private func cancelEditingQueuedPrompt() {
        editingQueuedPromptIndex = nil
        editingQueuedPromptText = ""
    }

    private func saveQueuedPromptEdit() {
        guard let index = editingQueuedPromptIndex else { return }
        appState.updateQueuedPrompt(at: index, with: editingQueuedPromptText, for: agent)
        cancelEditingQueuedPrompt()
    }

    private func messageScrollID(for message: ConversationMessage) -> String {
        "message-\(message.id.uuidString)"
    }

    private func updateScrollState(offset: CGFloat, maxOffset: CGFloat) {
        let normalizedOffset = max(0, min(offset, maxOffset))
        let pinnedToBottom = maxOffset <= 1 || normalizedOffset >= maxOffset - 24

        if abs(agent.workspace.conversationScrollOffset - normalizedOffset) > 12 {
            agent.workspace.conversationScrollOffset = normalizedOffset
        }

        if agent.workspace.conversationPinnedToBottom != pinnedToBottom {
            agent.workspace.conversationPinnedToBottom = pinnedToBottom
        }
    }

    private func formatTokenCount(_ count: Int) -> String {
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

    private func formatExactTokenCount(_ count: Int) -> String {
        Self.exactTokenFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }
}

private struct ConversationScrollBridge: NSViewRepresentable {
    var restoreKey: UUID
    var desiredOffset: CGFloat
    var stickToBottom: Bool
    var contentVersion: Int
    var onScrollChange: (CGFloat, CGFloat) -> Void
    var onInitialRestoreCompleted: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScrollChange: onScrollChange)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.attachIfNeeded(to: view)
            context.coordinator.prepareForRestore(restoreKey)
            context.coordinator.scheduleInitialRestore(
                for: restoreKey,
                desiredOffset: desiredOffset,
                stickToBottom: stickToBottom,
                onInitialRestoreCompleted: onInitialRestoreCompleted
            )
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onScrollChange = onScrollChange
        context.coordinator.attachIfNeeded(to: nsView)
        context.coordinator.prepareForRestore(restoreKey)
        if context.coordinator.hasCompletedInitialRestore {
            context.coordinator.updateScrollIntent(
                desiredOffset: desiredOffset,
                stickToBottom: stickToBottom,
                contentVersion: contentVersion
            )
        } else {
            context.coordinator.scheduleInitialRestore(
                for: restoreKey,
                desiredOffset: desiredOffset,
                stickToBottom: stickToBottom,
                onInitialRestoreCompleted: onInitialRestoreCompleted
            )
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        var onScrollChange: (CGFloat, CGFloat) -> Void

        private weak var scrollView: NSScrollView?
        private weak var clipView: NSClipView?
        private weak var documentView: NSView?
        private var observingScrollBounds = false
        private var observingDocumentFrame = false
        private var isApplyingProgrammaticScroll = false
        private var activeRestoreKey: UUID?
        private var pendingInitialRestore = false
        private var pendingLayoutScroll = false
        private var desiredOffset: CGFloat = 0
        private var stickToBottom = true
        private var lastContentVersion: Int?
        private var lastClipHeight: CGFloat?
        fileprivate var hasCompletedInitialRestore = false

        init(onScrollChange: @escaping (CGFloat, CGFloat) -> Void) {
            self.onScrollChange = onScrollChange
        }

        func prepareForRestore(_ restoreKey: UUID) {
            guard activeRestoreKey != restoreKey else { return }
            activeRestoreKey = restoreKey
            pendingInitialRestore = false
            hasCompletedInitialRestore = false
        }

        func attachIfNeeded(to view: NSView) {
            guard scrollView == nil else { return }
            guard let scrollView = enclosingScrollView(from: view) else { return }

            self.scrollView = scrollView
            clipView = scrollView.contentView
            lastClipHeight = scrollView.contentView.bounds.height
            scrollView.contentView.postsBoundsChangedNotifications = true
            attachDocumentObserverIfNeeded()

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleScrollBoundsDidChange),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
            observingScrollBounds = true
        }

        func detach() {
            if observingScrollBounds {
                NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: clipView)
            }
            if observingDocumentFrame {
                NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: documentView)
            }
            observingScrollBounds = false
            observingDocumentFrame = false
            scrollView = nil
            clipView = nil
            documentView = nil
            lastClipHeight = nil
        }

        func updateScrollIntent(desiredOffset: CGFloat, stickToBottom: Bool, contentVersion: Int) {
            self.desiredOffset = desiredOffset
            let becamePinned = stickToBottom && !self.stickToBottom
            self.stickToBottom = stickToBottom
            attachDocumentObserverIfNeeded()

            let didChangeContent = lastContentVersion != contentVersion
            lastContentVersion = contentVersion

            if stickToBottom, becamePinned || didChangeContent {
                scheduleLayoutScroll()
            }
        }

        func scheduleInitialRestore(
            for restoreKey: UUID,
            desiredOffset: CGFloat,
            stickToBottom: Bool,
            onInitialRestoreCompleted: @escaping () -> Void
        ) {
            guard activeRestoreKey == restoreKey, !pendingInitialRestore, !hasCompletedInitialRestore else { return }
            pendingInitialRestore = true
            self.desiredOffset = desiredOffset
            self.stickToBottom = stickToBottom

            DispatchQueue.main.async { [weak self] in
                guard let self, self.activeRestoreKey == restoreKey else { return }
                guard self.scrollView != nil, self.clipView != nil else {
                    self.pendingInitialRestore = false
                    return
                }
                self.applyScrollPosition(desiredOffset: desiredOffset, stickToBottom: stickToBottom)

                DispatchQueue.main.async { [weak self] in
                    guard let self, self.activeRestoreKey == restoreKey else { return }
                    guard self.scrollView != nil, self.clipView != nil else {
                        self.pendingInitialRestore = false
                        return
                    }
                    self.applyScrollPosition(desiredOffset: desiredOffset, stickToBottom: stickToBottom)
                    self.pendingInitialRestore = false
                    self.hasCompletedInitialRestore = true
                    self.attachDocumentObserverIfNeeded()
                    onInitialRestoreCompleted()
                }
            }
        }

        func applyScrollPosition(desiredOffset: CGFloat, stickToBottom: Bool) {
            guard let scrollView, let clipView else { return }
            let maxOffset = maximumOffset(for: scrollView)
            let targetOffset = stickToBottom ? maxOffset : max(0, min(desiredOffset, maxOffset))

            guard abs(clipView.bounds.origin.y - targetOffset) > 1 else {
                reportScrollPosition()
                return
            }

            isApplyingProgrammaticScroll = true
            clipView.setBoundsOrigin(NSPoint(x: 0, y: targetOffset))
            scrollView.reflectScrolledClipView(clipView)
            isApplyingProgrammaticScroll = false
            reportScrollPosition()
        }

        @objc
        private func handleScrollBoundsDidChange() {
            guard !isApplyingProgrammaticScroll else { return }

            let currentClipHeight = clipView?.bounds.height ?? 0
            let didResizeViewport = lastClipHeight.map { abs($0 - currentClipHeight) > 0.5 } ?? false
            lastClipHeight = currentClipHeight

            if stickToBottom, didResizeViewport {
                scheduleLayoutScroll()
                return
            }

            reportScrollPosition()
        }

        @objc
        private func handleDocumentFrameDidChange() {
            attachDocumentObserverIfNeeded()
            if stickToBottom {
                scheduleLayoutScroll()
            } else {
                reportScrollPosition()
            }
        }

        private func scheduleLayoutScroll() {
            guard !pendingLayoutScroll else { return }
            pendingLayoutScroll = true

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.applyScrollPosition(desiredOffset: self.desiredOffset, stickToBottom: self.stickToBottom)

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.pendingLayoutScroll = false
                    self.applyScrollPosition(desiredOffset: self.desiredOffset, stickToBottom: self.stickToBottom)
                }
            }
        }

        private func reportScrollPosition() {
            guard let scrollView, let clipView else { return }
            let maxOffset = maximumOffset(for: scrollView)
            let offset = max(0, min(clipView.bounds.origin.y, maxOffset))
            lastClipHeight = clipView.bounds.height
            onScrollChange(offset, maxOffset)
        }

        private func maximumOffset(for scrollView: NSScrollView) -> CGFloat {
            guard let documentView = scrollView.documentView else { return 0 }
            return max(0, documentView.frame.height - scrollView.contentView.bounds.height)
        }

        private func attachDocumentObserverIfNeeded() {
            guard let scrollView else { return }
            let currentDocumentView = scrollView.documentView
            guard documentView !== currentDocumentView else { return }

            if observingDocumentFrame {
                NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: documentView)
                observingDocumentFrame = false
            }

            documentView = currentDocumentView

            guard let currentDocumentView else { return }
            currentDocumentView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleDocumentFrameDidChange),
                name: NSView.frameDidChangeNotification,
                object: currentDocumentView
            )
            observingDocumentFrame = true
        }

        private func enclosingScrollView(from view: NSView) -> NSScrollView? {
            var current: NSView? = view
            while let candidate = current {
                if let scrollView = candidate.enclosingScrollView {
                    return scrollView
                }
                current = candidate.superview
            }
            return nil
        }
    }
}

private enum ConversationDisplayItem: Identifiable {
    case message(ConversationMessage)
    case toolGroup(id: UUID, messages: [ConversationMessage])

    var id: String {
        switch self {
        case .message(let message):
            "message-\(message.id.uuidString)"
        case .toolGroup(let id, _):
            "tool-group-\(id.uuidString)"
        }
    }

    var scrollID: String { id }
}

private struct ToolActivityGroup: View {
    let messages: [ConversationMessage]

    var body: some View {
        HStack(spacing: FXSpacing.sm) {
            Image(systemName: "terminal")
                .font(FXTypography.icon(.small))
                .foregroundStyle(FXColors.fgTertiary)
                .frame(width: 14)

            Text(title)
                .font(FXTypography.captionMedium)
                .foregroundStyle(FXColors.fgTertiary)

            if let detail {
                Text("·")
                    .font(FXTypography.caption)
                    .foregroundStyle(FXColors.fgQuaternary)

                Text(detail)
                    .font(FXTypography.caption)
                    .foregroundStyle(FXColors.fgTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, FXSpacing.xxxs)
        .opacity(0.68)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        let count = toolSummaries.count
        guard count > 0 else { return "Used tools" }
        return count == 1 ? "Used \(toolSummaries[0].name)" : "Used \(count) tools"
    }

    private var detail: String? {
        let parts = toolSummaries
            .compactMap(\.detail)
            .prefix(3)

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: ", ")
    }

    private var toolSummaries: [(name: String, detail: String?)] {
        messages.flatMap { message in
            message.content.compactMap { content -> (name: String, detail: String?)? in
                guard case .toolUse(_, let name, let input) = content else { return nil }
                return (name, summarizedToolInput(name: name, input: input))
            }
        }
    }

    private func summarizedToolInput(name: String, input: String) -> String? {
        guard !input.isEmpty, input != "{}" else { return nil }
        guard let data = input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return summarizedSingleLine(input)
        }

        switch name {
        case "Read", "Edit", "Write":
            return (json["file_path"] as? String).map(shortPathForDisplay)
        case "Grep":
            return json["pattern"] as? String
        case "Glob":
            return json["pattern"] as? String
        case "Bash", "Command", "Shell", "commandExecution":
            return (json["command"] as? String).map { summarizedSingleLine($0, limit: 96) }
        default:
            return summarizedSingleLine(input)
        }
    }

    private func summarizedSingleLine(_ text: String, limit: Int = 96) -> String {
        let flattened = text
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? text

        if flattened.count <= limit {
            return flattened
        }

        return String(flattened.prefix(limit - 1)) + "..."
    }

    private func shortPathForDisplay(_ path: String) -> String {
        let components = path.split(separator: "/")
        let tail = components.suffix(2)
        return tail.isEmpty ? path : tail.joined(separator: "/")
    }
}
