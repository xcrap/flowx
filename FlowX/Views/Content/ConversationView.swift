import SwiftUI
import FXDesign

struct ConversationView: View {
    @Environment(AppState.self) private var appState
    @Bindable var agent: AgentInfo

    @State private var editingQueuedPromptIndex: Int?
    @State private var editingQueuedPromptText = ""

    private let maxContentWidth: CGFloat = 920

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: FXSpacing.xxxl) {
                        if showsEmptyState {
                            emptyStateCard
                        }

                        if !agent.activities.isEmpty {
                            RuntimeActivityBar(activities: agent.activities, toolCallCount: agent.toolCallCount)
                        }

                        ForEach(agent.messages) { message in
                            MessageBubble(message: message)
                        }

                        if !agent.conversationState.streamingText.isEmpty {
                            MessageBubble(streamingText: agent.conversationState.streamingText)
                        } else if agent.isStreaming {
                            streamingIndicator
                        }

                        if let error = agent.conversationState.error {
                            errorCard(error)
                        }

                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: maxContentWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, FXSpacing.xxl)
                    .padding(.top, FXSpacing.xxl)
                    .padding(.bottom, FXSpacing.md)
                }
                .scrollContentBackground(.hidden)
                .onAppear {
                    scrollToBottom(using: proxy, animated: false)
                }
                .onChange(of: agent.messages.count) { _, _ in
                    scrollToBottom(using: proxy)
                }
                .onChange(of: agent.conversationState.streamingText) { _, _ in
                    scrollToBottom(using: proxy, animated: false)
                }
                .onChange(of: agent.activities.count) { _, _ in
                    scrollToBottom(using: proxy)
                }
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
    }

    private var showsEmptyState: Bool {
        agent.messages.isEmpty
            && agent.activities.isEmpty
            && agent.conversationState.streamingText.isEmpty
            && !agent.isStreaming
            && agent.conversationState.error == nil
    }

    private var showsContextBar: Bool {
        hasUsageData
            || agent.conversationState.queuedPromptCount > 0
            || agent.isStreaming
            || agent.conversationState.sessionID != nil
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
        switch agent.conversationState.runtimePhase {
        case .idle:
            FXColors.fgTertiary
        case .preparing, .responding:
            FXColors.accent
        case .compacting, .cancelling:
            FXColors.warning
        case .compacted:
            FXColors.info
        case .failed:
            FXColors.error
        }
    }

    private var isRecoverableError: Bool {
        guard let error = agent.conversationState.error?.lowercased() else { return false }
        let nonRecoverable = ["not found", "install with", "configure it in settings", "failed to start"]
        return !nonRecoverable.contains(where: { error.contains($0) })
    }

    private var projectName: String {
        URL(fileURLWithPath: agent.projectRootPath).lastPathComponent
    }

    private var providerModelBadgeText: String {
        let provider = simplifiedProviderName(for: agent.providerName)
        let model = simplifiedModelName(for: currentModelName)

        if model.localizedCaseInsensitiveContains(provider) {
            return model
        }

        return "\(provider) \(model)"
    }

    private var currentModelName: String {
        let providers = appState.providerRegistry.allProviders
        let provider = providers.first(where: { $0.id == agent.providerID })
        return provider?.availableModels.first(where: { $0.id == agent.modelID })?.name ?? agent.modelID
    }

    private var modeBadgeText: String {
        agent.agentMode == .plan ? "Plan mode" : "Chat mode"
    }

    private var accessBadgeText: String {
        switch agent.agentAccess {
        case .supervised:
            "Supervised"
        case .acceptEdits:
            "Accept edits"
        case .fullAccess:
            "Full access"
        }
    }

    private var starterPrompts: [String] {
        [
            "Summarize this repository and point out the risky areas.",
            "Inspect the current changes and suggest the next clean commit.",
            "Find one high-impact improvement and implement it."
        ]
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

    private var emptyStateCard: some View {
        VStack(alignment: .leading, spacing: FXSpacing.xl) {
            VStack(alignment: .leading, spacing: FXSpacing.md) {
                HStack(spacing: FXSpacing.md) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(FXColors.accent)

                    VStack(alignment: .leading, spacing: FXSpacing.xxxs) {
                        Text("\(agent.title) is ready")
                            .font(FXTypography.title3)
                            .foregroundStyle(FXColors.fg)

                        Text("Working in \(projectName)")
                            .font(FXTypography.body)
                            .foregroundStyle(FXColors.fgSecondary)
                    }
                }

                Text(agent.projectRootPath)
                    .font(FXTypography.caption)
                    .foregroundStyle(FXColors.fgTertiary)
                    .textSelection(.enabled)
            }

            HStack(spacing: FXSpacing.sm) {
                FXBadge(providerModelBadgeText, tone: .accent)
                FXBadge(modeBadgeText, tone: .info)
                FXBadge(accessBadgeText, tone: .neutral)
            }

            VStack(alignment: .leading, spacing: FXSpacing.sm) {
                Text("Start with")
                    .font(FXTypography.captionMedium)
                    .foregroundStyle(FXColors.fgSecondary)

                ForEach(starterPrompts, id: \.self) { prompt in
                    Button(action: {
                        agent.conversationState.inputText = prompt
                    }) {
                        HStack(spacing: FXSpacing.sm) {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(FXColors.fgTertiary)

                            Text(prompt)
                                .font(FXTypography.body)
                                .foregroundStyle(FXColors.fgSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, FXSpacing.md)
                        .padding(.vertical, FXSpacing.md)
                        .background(FXColors.bgSurface)
                        .clipShape(RoundedRectangle(cornerRadius: FXRadii.md))
                        .overlay(
                            RoundedRectangle(cornerRadius: FXRadii.md)
                                .strokeBorder(FXColors.borderSubtle, lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: FXSpacing.sm) {
                quickActionButton(icon: "terminal", title: "Open terminal") {
                    withAnimation(FXAnimation.panel) {
                        agent.workspace.terminalVisible = true
                    }
                }

                quickActionButton(icon: "sidebar.right", title: "Show files") {
                    withAnimation(FXAnimation.panel) {
                        appState.rightPanelVisible = true
                        appState.rightPanelTab = .files
                    }
                }

                quickActionButton(icon: "globe", title: "Open browser") {
                    withAnimation(FXAnimation.panel) {
                        agent.workspace.splitContent = .browser
                        agent.workspace.splitOpen = true
                    }
                }
            }

            Text("Send with Command-Return")
                .font(FXTypography.caption)
                .foregroundStyle(FXColors.fgTertiary)
        }
        .padding(FXSpacing.xxxl)
        .background(FXColors.bgElevated)
        .clipShape(RoundedRectangle(cornerRadius: FXRadii.xxl))
        .overlay(
            RoundedRectangle(cornerRadius: FXRadii.xxl)
                .strokeBorder(FXColors.border, lineWidth: 0.5)
        )
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity, minHeight: 360, alignment: .center)
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
                                    .font(.system(size: 9, weight: .bold))
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

    private var contextBar: some View {
        VStack(alignment: .leading, spacing: FXSpacing.sm) {
            HStack(spacing: FXSpacing.sm) {
                statusPill

                if let sessionID = agent.conversationState.sessionID, !sessionID.isEmpty {
                    FXBadge(agent.conversationState.error == nil ? "Session ready" : "Resume available", tone: .neutral)
                }

                if agent.conversationState.queuedPromptCount > 0 {
                    let count = agent.conversationState.queuedPromptCount
                    FXBadge(count == 1 ? "1 queued" : "\(count) queued", tone: .warning)
                }

                Spacer()
            }

            if let usageStatusText {
                Text(usageStatusText)
                    .font(FXTypography.monoSmall)
                    .foregroundStyle(FXColors.fgTertiary)
            } else if hasUsageData {
                Text(usageSummaryText)
                    .font(FXTypography.monoSmall)
                    .foregroundStyle(FXColors.fgTertiary)
            } else if agent.isStreaming {
                Text("Waiting for provider usage…")
                    .font(FXTypography.monoSmall)
                    .foregroundStyle(FXColors.fgTertiary)
            }
        }
        .padding(.top, agent.conversationState.queuedPromptCount > 0 ? 0 : FXSpacing.md)
        .padding(.bottom, FXSpacing.sm)
        .frame(maxWidth: maxContentWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, FXSpacing.xxl)
    }

    private var statusPill: some View {
        HStack(spacing: FXSpacing.xs) {
            Circle()
                .fill(runtimeStatusColor)
                .frame(width: 6, height: 6)

            Text(agent.conversationState.statusLabel)
                .font(FXTypography.monoSmall)
                .foregroundStyle(agent.isStreaming ? runtimeStatusColor : FXColors.fgSecondary)
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
                    .font(.system(size: 12))
                    .foregroundStyle(FXColors.error)
                    .frame(width: 20, height: 20)

                Text(error)
                    .font(FXTypography.body)
                    .foregroundStyle(FXColors.error)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: FXSpacing.sm) {
                if isRecoverableError, let sessionID = agent.conversationState.sessionID, !sessionID.isEmpty {
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

    private func quickActionButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: FXSpacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                Text(title)
                    .font(FXTypography.captionMedium)
            }
            .foregroundStyle(FXColors.fgSecondary)
            .padding(.horizontal, FXSpacing.md)
            .padding(.vertical, FXSpacing.sm)
            .frame(maxWidth: .infinity)
            .background(FXColors.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: FXRadii.md))
        }
        .buttonStyle(.plain)
    }

    private func actionPill(title: String, icon: String?, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: FXSpacing.xs) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .medium))
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

    private func scrollToBottom(using proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(FXAnimation.quick) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
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
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    private func simplifiedProviderName(for displayName: String) -> String {
        displayName
            .replacingOccurrences(of: " (via Claude Code)", with: "")
            .replacingOccurrences(of: " (OpenAI)", with: "")
    }

    private func simplifiedModelName(for modelName: String) -> String {
        modelName
            .replacingOccurrences(of: " (latest)", with: "")
    }
}
