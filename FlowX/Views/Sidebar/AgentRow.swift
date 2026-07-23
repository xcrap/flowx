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
    @FocusState private var isFocused: Bool

    private var isSelected: Bool {
        appState.activeAgentID == agent.id
    }

    var body: some View {
        rowContent
        .contentShape(Rectangle())
        .onTapGesture(perform: selectThread)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
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
        HStack(spacing: FXSpacing.sm) {
            FXActivityDot(color: providerColor, state: activityDotState)
                .help(sourceAndStatusHelp)
                .accessibilityLabel(sourceAndStatusHelp)

            Text(displayTitle)
                .font(FXTypography.bodyMedium)
                .foregroundStyle(isSelected ? FXColors.fg : FXColors.fgSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .allowsTightening(true)
                .layoutPriority(1)

            Spacer(minLength: 0)

            if hasLifecycleMenu {
                lifecycleMenu
                    .opacity(showsLifecycleMenu ? 1 : 0)
                    .allowsHitTesting(showsLifecycleMenu)
                    .accessibilityHidden(!showsLifecycleMenu)
            }
        }
        .padding(.horizontal, FXSpacing.md)
        .padding(.vertical, FXSpacing.xs)
        .frame(minHeight: 32)
        .background(
            RoundedRectangle(cornerRadius: FXRadii.md)
                .fill(
                    isSelected
                        ? FXColors.bgSelected
                        : ((isHovered || isFocused) ? FXColors.bgHover : .clear)
                )
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
        (isHovered || isFocused) && hasLifecycleMenu
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
            return "Restore later in Settings; includes spawned tasks"
        case .deleteProviderTask:
            return "Permanent; includes spawned tasks"
        case .moveProviderTaskToTrash:
            return "Recoverable from macOS Trash"
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

    private var sourceAndStatusHelp: String {
        guard agent.shouldShowStatusIndicator else {
            return "\(agent.providerName) task"
        }
        return "\(agent.providerName) · \(statusHelp)"
    }

    private var activityDotState: FXActivityDotState {
        guard agent.shouldShowStatusIndicator else { return .idle }
        return switch agent.status {
        case .running:
            .running
        case .waitingForInput, .waitingForApproval:
            .waiting
        case .completed:
            .completed
        case .error:
            .error
        case .idle:
            .idle
        }
    }

    private var displayTitle: String {
        let nativeTitle = agent.nativeThreadBinding?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let nativeTitle, !nativeTitle.isEmpty {
            return nativeTitle
        }
        return agent.title
    }

    private var providerColor: Color {
        switch agent.providerID {
        case "claude":
            FXColors.accentSecondary
        default:
            FXColors.accent
        }
    }

    private func selectThread() {
        appState.activateAgent(agent.id, in: project.id)
    }

    private func copyThreadID(_ sessionID: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sessionID, forType: .string)
    }

}
