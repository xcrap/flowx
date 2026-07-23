import AppKit
import SwiftUI
import FXCore
import FXDesign

/// A provider-native conversation row. `AgentInfo` remains the internal
/// workspace controller, while the sidebar presents the Codex/Claude thread
/// that it is bound to.
struct ThreadRow: View {
    @Environment(AppState.self) private var appState
    @Bindable var agent: AgentInfo
    @Bindable var project: ProjectState

    @State private var isHovered = false

    private var isSelected: Bool {
        appState.activeAgentID == agent.id
    }

    var body: some View {
        rowContent
        .contentShape(Rectangle())
        .onTapGesture(perform: selectThread)
        .focusable()
        .onKeyPress(.return) {
            selectThread()
            return .handled
        }
        .onKeyPress(.space) {
            selectThread()
            return .handled
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            if let sessionID = agent.conversationState.sessionID, !sessionID.isEmpty {
                Button(action: { copyThreadID(sessionID) }) {
                    Label("Copy Provider Thread ID", systemImage: "doc.on.doc")
                }
                Divider()
            }

            if !lifecycleActions.isEmpty {
                ForEach(lifecycleActions, id: \.self) { action in
                    Button(
                        action.title,
                        role: action.isDestructive ? .destructive : nil
                    ) {
                        appState.requestThreadLifecycleAction(action, for: agent)
                    }
                    .disabled(!lifecycleActionEnabled)
                }
            }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(agent.providerName) thread, \(displayTitle)")
        .accessibilityHint("Open this thread in \(project.project.name)")
        .accessibilityAction {
            selectThread()
        }
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: FXSpacing.xs) {
            HStack(spacing: FXSpacing.sm) {
                providerBadge

                Text(displayTitle)
                    .font(FXTypography.bodyMedium)
                    .foregroundStyle(isSelected ? FXColors.fg : FXColors.fgSecondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if agent.shouldShowStatusIndicator {
                    statusIndicator
                }

                if hasLifecycleMenu {
                    lifecycleMenu
                        .opacity(showsLifecycleMenu ? 1 : 0)
                        .allowsHitTesting(showsLifecycleMenu)
                        .accessibilityHidden(!showsLifecycleMenu)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: FXSpacing.sm) {
                Text(providerSourceLabel)
                    .font(FXTypography.overline)
                    .foregroundStyle(FXColors.fgQuaternary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 72, alignment: .leading)

                Text(threadPreview)
                    .font(FXTypography.caption)
                    .foregroundStyle(FXColors.fgTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let activityLabel {
                    Text(activityLabel)
                        .font(FXTypography.monoSmall)
                        .foregroundStyle(activityColor)
                        .lineLimit(1)
                        .fixedSize()
                }
            }

        }
        .padding(.horizontal, FXSpacing.md)
        .padding(.vertical, FXSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: FXRadii.md)
                .fill(isSelected ? FXColors.bgSelected : (isHovered ? FXColors.bgHover : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: FXRadii.md)
                .strokeBorder(isSelected ? FXColors.border : .clear, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }

    private var lifecycleMenu: some View {
        FXDropdown(
            sections: lifecycleMenuSections,
            enabled: !isLifecycleActionInProgress,
            panelWidth: 220,
            placement: .automatic,
            alignment: .trailing
        ) { isExpanded in
            Group {
                if isLifecycleActionInProgress {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: isExpanded ? "xmark" : "ellipsis")
                        .font(FXTypography.icon(.small))
                        .foregroundStyle(isExpanded ? FXColors.accent : FXColors.fgTertiary)
                }
            }
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .accessibilityLabel("Task actions")
        }
        .help("Task actions")
    }

    private var lifecycleMenuSections: [FXDropdownSection] {
        var sections: [FXDropdownSection] = []
        if let sessionID = agent.conversationState.sessionID, !sessionID.isEmpty {
            sections.append(
                FXDropdownSection(
                    id: "thread-info",
                    items: [
                        FXDropdownItem(
                            id: "copy-thread-id",
                            title: "Copy Provider Thread ID",
                            subtitle: sessionID
                        ) {
                            copyThreadID(sessionID)
                        },
                    ]
                )
            )
        }
        if !lifecycleActions.isEmpty {
            sections.append(
                FXDropdownSection(
                    id: "thread-lifecycle",
                    items: lifecycleActions.map { action in
                        FXDropdownItem(
                            id: action.rawValue,
                            title: action.title,
                            subtitle: lifecycleActionSubtitle(action),
                            isEnabled: lifecycleActionEnabled,
                            tone: action.isDestructive ? .destructive : .standard
                        ) {
                            appState.requestThreadLifecycleAction(action, for: agent)
                        }
                    }
                )
            )
        }
        return sections
    }

    private var lifecycleActions: [ThreadLifecycleActionKind] {
        appState.threadLifecycleActions(for: agent)
    }

    private var lifecycleActionEnabled: Bool {
        appState.threadLifecycleBlockedReason(for: agent, in: project) == nil
    }

    private var isLifecycleActionInProgress: Bool {
        appState.isThreadLifecycleActionInProgress(for: agent.id)
    }

    private var showsLifecycleMenu: Bool {
        (isHovered || isSelected) && hasLifecycleMenu
    }

    private var hasLifecycleMenu: Bool {
        agent.conversationState.sessionID?.isEmpty == false
            || !lifecycleActions.isEmpty
            || isLifecycleActionInProgress
    }

    private func lifecycleActionSubtitle(_ action: ThreadLifecycleActionKind) -> String {
        if let blockedReason = appState.threadLifecycleBlockedReason(for: agent, in: project) {
            return blockedReason
        }
        switch action {
        case .deleteDraft:
            return "Remove this local FlowX draft"
        case .archiveProviderTask:
            return "Restore later from Archived; includes spawned tasks"
        case .deleteProviderTask:
            return "Permanent; includes spawned tasks"
        case .moveProviderTaskToTrash:
            return "Recoverable from macOS Trash"
        }
    }

    private var providerBadge: some View {
        FXBadge(providerShortLabel, tone: providerBadgeTone)
            .accessibilityLabel("Source: \(agent.providerName)")
    }

    private var statusIndicator: some View {
        HStack(spacing: FXSpacing.xxs) {
            statusGlyph

            Text(statusLabel)
                .font(FXTypography.monoSmall)
                .lineLimit(1)
        }
        .foregroundStyle(statusColor)
        .frame(width: 76, alignment: .trailing)
        .help(statusHelp)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(statusHelp)
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch agent.status {
        case .running:
            PulsingDot(color: statusColor)
        case .waitingForInput:
            Image(systemName: "questionmark.bubble.fill")
                .font(FXTypography.icon(.small))
        case .waitingForApproval:
            Image(systemName: "hand.raised.fill")
                .font(FXTypography.icon(.small))
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(FXTypography.icon(.small))
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .font(FXTypography.icon(.small))
        case .idle:
            EmptyView()
        }
    }

    private var statusLabel: String {
        return switch agent.status {
        case .running: "RUNNING"
        case .waitingForInput: "INPUT"
        case .waitingForApproval: "APPROVAL"
        case .completed: "DONE"
        case .error: "ERROR"
        case .idle: ""
        }
    }

    private var statusHelp: String {
        return switch agent.status {
        case .running:
            "Agent is running"
        case .waitingForInput:
            "Waiting for your answer in this thread"
        case .waitingForApproval:
            "Waiting for your approval in this thread"
        case .completed:
            "Agent completed"
        case .error:
            "Agent needs attention"
        case .idle:
            ""
        }
    }

    private var statusColor: Color {
        return switch agent.status {
        case .running: FXColors.accent
        case .waitingForInput, .waitingForApproval: FXColors.warning
        case .completed: FXColors.success
        case .error: FXColors.error
        case .idle: FXColors.fgQuaternary
        }
    }

    private var providerShortLabel: String {
        switch agent.providerID {
        case "codex":
            "CODEX"
        case "claude":
            "CLAUDE"
        default:
            agent.providerName.uppercased()
        }
    }

    private var providerSourceLabel: String {
        guard let source = agent.nativeThreadBinding?.identity.providerSource,
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "DRAFT"
        }

        return source
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .uppercased()
    }

    private var displayTitle: String {
        let nativeTitle = agent.nativeThreadBinding?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let nativeTitle, !nativeTitle.isEmpty {
            return nativeTitle
        }
        return agent.title
    }

    private var providerBadgeTone: FXBadgeTone {
        switch agent.providerID {
        case "claude":
            .accentSecondary
        default:
            .accent
        }
    }

    private var threadPreview: String {
        if let nativePreview = agent.nativePreview {
            return flattenedPreview(nativePreview)
        }

        guard let latestText = agent.messages.reversed().lazy
            .map(\.textContent)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return agent.conversationState.sessionID == nil ? "Draft · not started" : "Provider thread"
        }

        return flattenedPreview(latestText)
    }

    private func flattenedPreview(_ text: String) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return flattened.isEmpty ? "Provider thread" : flattened
    }

    private var activityLabel: String? {
        guard let timestamp = agent.nativeUpdatedAt ?? agent.messages.last?.timestamp else {
            return nil
        }

        return timestamp.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }

    private var activityColor: Color {
        FXColors.fgQuaternary
    }

    private func selectThread() {
        withAnimation(FXAnimation.snappy) {
            appState.activateAgent(agent.id, in: project.id)
        }
    }

    private func copyThreadID(_ sessionID: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sessionID, forType: .string)
    }

}
