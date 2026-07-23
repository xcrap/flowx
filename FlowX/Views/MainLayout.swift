import SwiftUI
import AppKit
import FXAgent
import FXDesign

/// Enables window dragging from a specific view region
struct DragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragNSView { DragNSView() }
    func updateNSView(_ v: DragNSView, context: Context) {}

    class DragNSView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

struct MainLayout: View {
    @Environment(AppState.self) private var appState
    @State private var rightPanelResizePreview: CGFloat?

    private let rightPanelHandleWidth: CGFloat = 5
    private let titleBarHeight: CGFloat = 44
    private let settingsPanelWidth: CGFloat = 420

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 0) {
                    // Single-row title bar — traffic lights float on top of this
                    titleBar

                    // Content
                    HStack(spacing: 0) {
                        if appState.sidebarVisible {
                            SidebarView()
                                .frame(width: 260)
                            FXDivider(.vertical)
                        }

                        ContentAreaView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if appState.rightPanelVisible {
                            rightPanelContainer(totalWidth: geometry.size.width)
                        }
                    }
                }

                if appState.settingsVisible {
                    settingsOverlay(totalSize: geometry.size)
                        .padding(.top, titleBarHeight)
                        .zIndex(5)
                }

                if appState.commandPaletteVisible {
                    CommandPaletteView()
                        .transition(.opacity)
                        .zIndex(10)
                }

                if let confirmation = appState.threadLifecycleConfirmation {
                    ThreadLifecycleConfirmationView(confirmation: confirmation)
                        .transition(.opacity)
                        .zIndex(20)
                }
            }
        }
        .ignoresSafeArea()
        .onDisappear {
            clearRightPanelResizePreview()
        }
    }

    private func rightPanel(totalWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            rightPanelResizeHandle(totalWidth: totalWidth)
            RightPanelView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: displayedRightPanelWidth(in: totalWidth))
        .background(FXColors.panelBg)
    }

    private func rightPanelContainer(totalWidth: CGFloat) -> some View {
        rightPanel(totalWidth: totalWidth)
    }

    private func settingsOverlay(totalSize: CGSize) -> some View {
        HStack(spacing: 0) {
            FXDivider(.vertical)
            SettingsPanel()
                .frame(width: settingsPanelWidth, height: max(0, totalSize.height - titleBarHeight))
        }
        .background(FXColors.panelBg)
        .shadow(color: FXColors.overlay.opacity(0.24), radius: 18, x: -4, y: 0)
    }

    private func rightPanelResizeHandle(totalWidth: CGFloat) -> some View {
        let bounds = rightPanelWidthBounds(in: totalWidth)
        return LiveHorizontalResizeHandle(
            width: rightPanelHandleWidth,
            currentPanelWidth: displayedRightPanelWidth(in: totalWidth),
            minimumPanelWidth: bounds.lowerBound,
            maximumPanelWidth: bounds.upperBound,
            lineColor: FXColors.borderSubtle,
            hoverColor: FXColors.accent,
            helpText: "Resize git panel",
            onResizeChanged: { width in
                setRightPanelResizePreview(width)
            },
            onResizeEnded: { width in
                let resolvedWidth = clampRightPanelWidth(width, in: totalWidth)
                if abs(appState.rightPanelWidth - resolvedWidth) > 0.5 {
                    appState.rightPanelWidth = resolvedWidth
                }
                clearRightPanelResizePreview()
            },
            onResizeCancelled: {
                clearRightPanelResizePreview()
            }
        )
    }

    private func displayedRightPanelWidth(in totalWidth: CGFloat) -> CGFloat {
        let bounds = rightPanelWidthBounds(in: totalWidth)
        let requestedWidth = rightPanelResizePreview ?? appState.rightPanelWidth
        return min(max(requestedWidth, bounds.lowerBound), bounds.upperBound)
    }

    private func clampRightPanelWidth(_ width: CGFloat, in totalWidth: CGFloat) -> CGFloat {
        let bounds = rightPanelWidthBounds(in: totalWidth)
        return min(max(width, bounds.lowerBound), bounds.upperBound)
    }

    private func rightPanelWidthBounds(in totalWidth: CGFloat) -> ClosedRange<CGFloat> {
        let reservedSidebarWidth: CGFloat = appState.sidebarVisible ? 260 : 0
        let minimumContentWidth = FXLayout.minimumConversationWidth
            + (appState.activeAgent?.workspace.splitOpen == true
                ? FXLayout.minimumBrowserPreviewWidth + FXLayout.splitPanelResizeHandleWidth
                : 0)
        let maximumVisibleWidth = min(
            FlowXLayoutDefaults.maxRightPanelWidth,
            max(0, totalWidth - reservedSidebarWidth - minimumContentWidth)
        )
        let minimumVisibleWidth = min(FlowXLayoutDefaults.minRightPanelWidth, maximumVisibleWidth)
        return minimumVisibleWidth ... maximumVisibleWidth
    }

    private func setRightPanelResizePreview(_ width: CGFloat) {
        if let currentWidth = rightPanelResizePreview,
           abs(currentWidth - width) < 0.5 {
            return
        }
        withoutResizeAnimation {
            rightPanelResizePreview = width
        }
    }

    private func clearRightPanelResizePreview() {
        guard rightPanelResizePreview != nil else { return }
        withoutResizeAnimation {
            rightPanelResizePreview = nil
        }
    }

    private func withoutResizeAnimation(_ update: () -> Void) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction, update)
    }

    private var titleBar: some View {
        ZStack {
            DragHandle()

            // Center: project / provider thread / branch — truly centered
            if let agent = appState.activeAgent, let project = appState.activeProject {
                HStack(spacing: FXSpacing.sm) {
                    Text(project.project.name)
                        .font(FXTypography.caption)
                        .foregroundStyle(FXColors.fgTertiary)

                    if !project.gitInfo.branch.isEmpty {
                        metadataSeparator

                        Image(systemName: "arrow.triangle.branch")
                            .font(FXTypography.icon(.small))
                            .foregroundStyle(FXColors.fgSecondary)

                        Text(project.gitInfo.branch)
                            .font(FXTypography.captionMedium)
                            .foregroundStyle(FXColors.fgSecondary)
                    }

                    metadataSeparator

                    FXBadge(
                        agent.providerName.uppercased(),
                        tone: agent.providerID == "claude" ? .accentSecondary : .accent
                    )

                    Text(agent.nativeThreadBinding?.title ?? agent.title)
                        .font(FXTypography.bodyMedium)
                        .foregroundStyle(FXColors.fg)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 260)
                        .help(agent.nativeThreadBinding?.title ?? agent.title)
                        .accessibilityLabel("Thread: \(agent.nativeThreadBinding?.title ?? agent.title)")

                    if agent.shouldShowStatusIndicator {
                        threadStatusBadge(for: agent)
                    }

                    if project.gitInfo.additions > 0 || project.gitInfo.deletions > 0 {
                        metadataSeparator
                        Button(action: appState.toggleGitPanel) {
                            HStack(spacing: FXSpacing.sm) {
                                Text("+\(project.gitInfo.additions)")
                                    .font(FXTypography.monoSmall)
                                    .foregroundStyle(FXColors.diffAddedFg)
                                Text("-\(project.gitInfo.deletions)")
                                    .font(FXTypography.monoSmall)
                                    .foregroundStyle(FXColors.diffRemovedFg)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Toggle git panel")
                        .accessibilityLabel("Toggle git panel")
                    }
                }
            }

            // Right: buttons
            HStack {
                Spacer()

                if appState.activeAgent != nil {
                    HStack(spacing: FXSpacing.xxs) {
                        headerButton(
                            icon: "terminal",
                            label: "Toggle terminal",
                            active: appState.activeAgent?.workspace.terminalVisible == true
                        ) {
                            appState.activeAgent?.workspace.terminalVisible.toggle()
                        }
                        if appState.activeProjectCanShowGitPanel {
                            headerButton(
                                icon: "sidebar.right",
                                label: "Toggle git panel",
                                active: appState.rightPanelVisible
                            ) {
                                appState.toggleGitPanel()
                            }
                        }
                        headerButton(
                            icon: "globe",
                            label: "Toggle browser split",
                            active: appState.activeAgent?.workspace.splitOpen == true && appState.activeAgent?.workspace.splitContent == .browser
                        ) {
                            appState.toggleBrowserPreview()
                        }
                        headerButton(icon: "gearshape", label: "Toggle settings", active: appState.settingsVisible) {
                            appState.settingsVisible.toggle()
                        }
                    }
                }
            }
            .padding(.trailing, FXSpacing.md)
        }
        .frame(height: 44)
        .background(FXColors.bgElevated)
        .overlay(alignment: .bottom) { FXDivider() }
    }

    private var metadataSeparator: some View {
        Text("·")
            .font(FXTypography.caption)
            .foregroundStyle(FXColors.fgTertiary.opacity(0.65))
    }

    private func statusColor(for status: AgentStatus) -> Color {
        switch status {
        case .idle:
            FXColors.fgTertiary
        case .running:
            FXColors.accent
        case .waitingForInput, .waitingForApproval:
            FXColors.warning
        case .completed:
            FXColors.success
        case .error:
            FXColors.error
        }
    }

    private func statusIcon(for status: AgentStatus) -> String {
        switch status {
        case .idle:
            "circle.fill"
        case .running:
            "waveform.circle.fill"
        case .waitingForInput:
            "questionmark.bubble.fill"
        case .waitingForApproval:
            "hand.raised.fill"
        case .completed:
            "checkmark.circle.fill"
        case .error:
            "xmark.circle.fill"
        }
    }

    private func statusLabel(for status: AgentStatus) -> String {
        switch status {
        case .idle: "Idle"
        case .running: "Running"
        case .waitingForInput: "Input needed"
        case .waitingForApproval: "Approval needed"
        case .completed: "Done"
        case .error: "Error"
        }
    }

    private func threadStatusBadge(for agent: AgentInfo) -> some View {
        let color = statusColor(for: agent.status)
        return HStack(spacing: FXSpacing.xxs) {
            Image(systemName: statusIcon(for: agent.status))
                .font(FXTypography.icon(.micro))

            Text(statusLabel(for: agent.status))
                .font(FXTypography.monoSmall)
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, FXSpacing.sm)
        .padding(.vertical, FXSpacing.xxs)
        .background(FXColors.bgSurface)
        .clipShape(Capsule())
        .help(statusLabel(for: agent.status))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(statusLabel(for: agent.status))
    }

    private func headerButton(icon: String, label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(FXTypography.icon(.control))
                .foregroundStyle(active ? FXColors.accent : FXColors.fgTertiary)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(active ? "Visible" : "Hidden")
    }
}

private struct ThreadLifecycleConfirmationView: View {
    @Environment(AppState.self) private var appState
    @FocusState private var cancelFocused: Bool
    let confirmation: ThreadLifecycleConfirmation

    var body: some View {
        ZStack {
            FXColors.overlay
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: FXSpacing.lg) {
                HStack(spacing: FXSpacing.md) {
                    Image(systemName: confirmation.action.systemImage)
                        .font(FXTypography.icon(.large))
                        .foregroundStyle(confirmation.action.isDestructive ? FXColors.error : FXColors.accent)

                    Text(confirmation.title)
                        .font(FXTypography.title2)
                        .foregroundStyle(FXColors.fg)
                }

                Text(confirmation.message)
                    .font(FXTypography.body)
                    .foregroundStyle(FXColors.fgSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: FXSpacing.sm) {
                    Spacer(minLength: 0)

                    FXButton("Cancel", style: .secondary) {
                        appState.cancelThreadLifecycleConfirmation()
                    }
                    .focused($cancelFocused)
                    .keyboardShortcut(.cancelAction)

                    FXButton(
                        confirmation.action.shortTitle,
                        style: confirmation.action.isDestructive ? .danger : .primary
                    ) {
                        appState.confirmThreadLifecycleAction()
                    }
                }
            }
            .padding(FXSpacing.xl)
            .frame(width: 440)
            .background(FXColors.bgElevated)
            .clipShape(RoundedRectangle(cornerRadius: FXRadii.xxl))
            .overlay(
                RoundedRectangle(cornerRadius: FXRadii.xxl)
                    .strokeBorder(FXColors.borderMedium, lineWidth: 0.5)
            )
            .shadow(color: FXColors.overlay, radius: 24, y: 14)
        }
        .onExitCommand {
            appState.cancelThreadLifecycleConfirmation()
        }
        .onAppear {
            cancelFocused = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(confirmation.title)
    }
}

private struct CommandPaletteView: View {
    @Environment(AppState.self) private var appState

    @FocusState private var searchFocused: Bool
    @State private var query = ""
    @State private var selectedActionID: String?

    private struct PaletteAction: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let systemImage: String
        let keywords: [String]
        let shortcut: String?
        let perform: () -> Void

        init(
            id: String? = nil,
            title: String,
            subtitle: String,
            systemImage: String,
            keywords: [String],
            shortcut: String? = nil,
            perform: @escaping () -> Void
        ) {
            self.id = id ?? "action:\(title)|\(systemImage)"
            self.title = title
            self.subtitle = subtitle
            self.systemImage = systemImage
            self.keywords = keywords
            self.shortcut = shortcut
            self.perform = perform
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            FXColors.overlay
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)

            VStack(alignment: .leading, spacing: 0) {
                searchField
                FXDivider()
                actionList
            }
            .frame(width: 560)
            .background(FXColors.bgElevated)
            .clipShape(RoundedRectangle(cornerRadius: FXRadii.xxl))
            .overlay(
                RoundedRectangle(cornerRadius: FXRadii.xxl)
                    .strokeBorder(FXColors.borderMedium, lineWidth: 0.5)
            )
            .shadow(color: FXColors.overlay, radius: 28, y: 16)
            .padding(.top, 84)
        }
        .onAppear {
            query = ""
            selectedActionID = actions.first?.id
            searchFocused = true
        }
        .onChange(of: query) { _, _ in
            selectedActionID = filteredActions.first?.id
        }
        .onMoveCommand(perform: moveSelection)
        .onExitCommand(perform: dismiss)
    }

    private var searchField: some View {
        HStack(spacing: FXSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(FXTypography.icon(.medium))
                .foregroundStyle(FXColors.fgTertiary)

            TextField("Search actions", text: $query)
                .textFieldStyle(.plain)
                .font(FXTypography.body)
                .foregroundStyle(FXColors.fg)
                .focused($searchFocused)
                .accessibilityLabel("Command palette search")
                .onSubmit {
                    if let selected = selectedAction {
                        run(selected)
                    }
                }

            Button(action: dismiss) {
                Text("Esc")
                    .font(FXTypography.monoSmall)
                    .foregroundStyle(FXColors.fgTertiary)
                    .padding(.horizontal, FXSpacing.xs)
                    .padding(.vertical, 2)
                    .background(FXColors.bgSurface)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close command palette")
        }
        .padding(.horizontal, FXSpacing.lg)
        .padding(.vertical, FXSpacing.md)
    }

    private var actionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: FXSpacing.xxs) {
                if filteredActions.isEmpty {
                    VStack(spacing: FXSpacing.sm) {
                        Image(systemName: "sparkle.magnifyingglass")
                            .font(FXTypography.icon(.large))
                            .foregroundStyle(FXColors.fgTertiary)

                        Text("No matching actions")
                            .font(FXTypography.bodyMedium)
                            .foregroundStyle(FXColors.fgSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, FXSpacing.xxxl)
                } else {
                    ForEach(filteredActions) { action in
                        Button(action: { run(action) }) {
                            HStack(spacing: FXSpacing.md) {
                                Image(systemName: action.systemImage)
                                    .font(FXTypography.icon(.control))
                                    .foregroundStyle(FXColors.accent)
                                    .frame(width: 20)

                                VStack(alignment: .leading, spacing: FXSpacing.xxxs) {
                                    Text(action.title)
                                        .font(FXTypography.bodyMedium)
                                        .foregroundStyle(FXColors.fg)
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                    Text(action.subtitle)
                                        .font(FXTypography.caption)
                                        .foregroundStyle(FXColors.fgTertiary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }

                                if let shortcut = action.shortcut {
                                    Text(shortcut)
                                        .font(FXTypography.monoSmall)
                                        .foregroundStyle(FXColors.fgTertiary)
                                        .padding(.horizontal, FXSpacing.xs)
                                        .padding(.vertical, FXSpacing.xxxs)
                                        .background(FXColors.bgElevated)
                                        .clipShape(RoundedRectangle(cornerRadius: FXRadii.xs))
                                }
                            }
                            .padding(.horizontal, FXSpacing.lg)
                            .padding(.vertical, FXSpacing.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(selectedActionID == action.id ? FXColors.bgSelected : FXColors.bgSurface.opacity(0.45))
                            .clipShape(RoundedRectangle(cornerRadius: FXRadii.lg))
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            if hovering { selectedActionID = action.id }
                        }
                        .accessibilityValue(selectedActionID == action.id ? "Selected" : "")
                    }
                }
            }
            .padding(FXSpacing.sm)
        }
        .frame(maxHeight: 440)
    }

    private var filteredActions: [PaletteAction] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else { return actions }

        return actions.filter { action in
            if action.title.lowercased().contains(normalizedQuery) || action.subtitle.lowercased().contains(normalizedQuery) {
                return true
            }
            return action.keywords.contains { $0.contains(normalizedQuery) }
        }
    }

    private var selectedAction: PaletteAction? {
        filteredActions.first(where: { $0.id == selectedActionID }) ?? filteredActions.first
    }

    private var actions: [PaletteAction] {
        var items: [PaletteAction] = [
            PaletteAction(
                title: "Add Project",
                subtitle: "Open a folder and add it to the sidebar",
                systemImage: "folder.badge.plus",
                keywords: ["repo", "project", "folder", "open"],
                shortcut: "⌘O"
            ) {
                appState.openAddProjectPanel()
            },
            PaletteAction(
                title: appState.sidebarVisible ? "Hide Sidebar" : "Show Sidebar",
                subtitle: "Toggle the left project sidebar",
                systemImage: "sidebar.left",
                keywords: ["sidebar", "navigation", "left"],
                shortcut: "⌘B"
            ) {
                appState.sidebarVisible.toggle()
            },
            PaletteAction(
                title: appState.rightPanelVisible ? "Hide Git Panel" : "Show Git Panel",
                subtitle: "Toggle the right git panel",
                systemImage: "sidebar.right",
                keywords: ["git", "changes", "diff", "right panel"],
                shortcut: "⌘G"
            ) {
                appState.toggleGitPanel()
            },
            PaletteAction(
                title: appState.settingsVisible ? "Hide Settings" : "Show Settings",
                subtitle: "Open the settings panel",
                systemImage: "gearshape",
                keywords: ["settings", "preferences", "config"],
                shortcut: "⌘,"
            ) {
                appState.settingsVisible.toggle()
            },
        ]

        if let agent = appState.activeAgent {
            let hasDraft = !agent.conversationState.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !agent.conversationState.pendingAttachments.isEmpty
            let selectedModelID = agent.explicitModelID ?? agent.nativeModelID
            let currentModel = selectedModelID.flatMap { modelID in
                appState.providerRegistry
                    .provider(for: agent.providerID)?
                    .availableModels
                    .first(where: { $0.id == modelID })
            }

            if hasDraft {
                let defaultMode = appState.preferences.defaultFollowUpMode

                if agent.isStreaming {
                    items.append(
                        followUpPaletteAction(
                            mode: defaultMode,
                            shortcut: "⌘↩",
                            isDefault: true,
                            agent: agent
                        )
                    )
                    items.append(
                        followUpPaletteAction(
                            mode: defaultMode.opposite,
                            shortcut: "⌃↩",
                            isDefault: false,
                            agent: agent
                        )
                    )
                } else {
                    items.append(
                        PaletteAction(
                            id: "prompt:send",
                            title: "Send Prompt",
                            subtitle: "Run the current composer draft",
                            systemImage: "arrow.up.circle.fill",
                            keywords: ["send", "prompt", "run", "command return", "control return"],
                            shortcut: "⌘↩ / ⌃↩"
                        ) {
                            appState.sendPrompt(
                                for: agent,
                                followUpMode: defaultMode
                            )
                        }
                    )
                }
            }

            if agent.isStreaming {
                items.append(
                    PaletteAction(
                        title: "Stop Current Run",
                        subtitle: "Interrupt the active provider turn",
                        systemImage: "stop.circle.fill",
                        keywords: ["stop", "cancel", "interrupt"],
                        shortcut: "⌘."
                    ) {
                        appState.cancelPrompt(for: agent)
                    }
                )
            } else {
                items.append(
                    PaletteAction(
                        title: "Reset Conversation",
                        subtitle: "Clear messages and start a new provider session",
                        systemImage: "arrow.counterclockwise",
                        keywords: ["reset", "clear", "conversation", "session"]
                    ) {
                        appState.resetConversation(for: agent)
                    }
                )
            }

            if let project = appState.activeProject,
               appState.threadLifecycleBlockedReason(for: agent, in: project) == nil {
                for action in appState.threadLifecycleActions(for: agent) {
                    items.append(
                        PaletteAction(
                            id: "task-lifecycle:\(action.rawValue):\(agent.id.uuidString)",
                            title: action.title,
                            subtitle: lifecycleActionSubtitle(action),
                            systemImage: action.systemImage,
                            keywords: ["task", "thread", "archive", "delete", "trash", "remove"]
                        ) {
                            appState.requestThreadLifecycleAction(action, for: agent)
                        }
                    )
                }
            }

            let supportsImages = currentModel?.supportsVision
                ?? appState.providerRegistry
                    .provider(for: agent.providerID)?
                    .capabilities.supportedAttachments.contains(.image)
                ?? false

            if supportsImages {
                items.append(
                    PaletteAction(
                        title: "Attach Images",
                        subtitle: "Choose images for the current prompt",
                        systemImage: "paperclip",
                        keywords: ["attach", "image", "photo", "vision"],
                        shortcut: "⇧⌘A"
                    ) {
                        appState.attachFiles(to: agent)
                    }
                )
            }

            items.append(
                PaletteAction(
                    title: agent.workspace.terminalVisible ? "Hide Terminal" : "Show Terminal",
                    subtitle: "Toggle the bottom terminal area",
                    systemImage: "terminal",
                    keywords: ["terminal", "console", "shell"],
                    shortcut: "⌘T"
                ) {
                    agent.workspace.terminalVisible.toggle()
                }
            )

            items.append(
                PaletteAction(
                    title: (agent.workspace.splitOpen && agent.workspace.splitContent == .browser) ? "Close Browser Split" : "Open Browser Split",
                    subtitle: "Toggle the browser in the split pane",
                    systemImage: "globe",
                    keywords: ["browser", "preview", "web"],
                    shortcut: "⌘P"
                ) {
                    appState.toggleBrowserPreview()
                }
            )

            if agent.terminalPaneCount < 3 {
                items.append(
                    PaletteAction(
                        title: "Add Terminal Split",
                        subtitle: "Open another terminal pane in this workspace",
                        systemImage: "rectangle.split.3x1",
                        keywords: ["terminal", "split", "shell"],
                        shortcut: "⇧⌘T"
                    ) {
                        agent.addTerminalPane()
                    }
                )
            }

            if agent.visibleTerminalSessions.contains(where: \.isRunning) {
                items.append(
                    PaletteAction(
                        title: "Clear All Terminals",
                        subtitle: "Clear every running terminal pane",
                        systemImage: "eraser",
                        keywords: ["terminal", "clear", "shell"]
                    ) {
                        for session in agent.visibleTerminalSessions where session.isRunning {
                            session.clearScreen()
                        }
                    }
                )
            }

            if agent.visibleTerminalSessions.contains(where: { !$0.isRunning }) {
                items.append(
                    PaletteAction(
                        title: "Restart Stopped Terminals",
                        subtitle: "Restart every stopped terminal pane",
                        systemImage: "arrow.clockwise",
                        keywords: ["terminal", "restart", "shell"]
                    ) {
                        for session in agent.visibleTerminalSessions where !session.isRunning {
                            session.restart()
                        }
                    }
                )
            }
        }

        if let project = appState.activeProject {
            if hasUsableProvider {
                items.append(
                    PaletteAction(
                        title: "New Thread",
                        subtitle: "Start a provider-native thread in \(project.project.name)",
                        systemImage: "plus.circle",
                        keywords: ["thread", "conversation", "provider", "create", "new"],
                        shortcut: "⌘N"
                    ) {
                        _ = appState.addAgent(to: project, title: "New Thread")
                    }
                )
            }

            if !project.isSyncingNativeThreads {
                for binding in project.archivedNativeThreadBindings
                    where !appState.isArchivedThreadActionInProgress(binding.identity) {
                    items.append(
                        PaletteAction(
                            id: "task-unarchive:\(binding.identity.providerID):\(binding.identity.sessionID)",
                            title: "Restore \(binding.title)",
                            subtitle: "Unarchive this Codex task",
                            systemImage: "arrow.uturn.backward.circle",
                            keywords: ["restore", "unarchive", "archived", "task", "thread", binding.title.lowercased()]
                        ) {
                            appState.unarchiveNativeThread(binding, in: project)
                        }
                    )

                    if appState.providerRegistry.provider(for: binding.identity.providerID)
                        is any AIProviderNativeThreadDeleting {
                        items.append(
                            PaletteAction(
                                id: "task-delete-archived:\(binding.identity.providerID):\(binding.identity.sessionID)",
                                title: "Delete \(binding.title) Permanently",
                                subtitle: "Permanently delete this archived Codex task",
                                systemImage: "trash",
                                keywords: ["delete", "permanent", "archived", "task", "thread", binding.title.lowercased()]
                            ) {
                                appState.requestArchivedThreadDeletion(binding, in: project)
                            }
                        )
                    }
                }
            }

            for agent in project.agents {
                let threadTitle = agent.nativeThreadBinding?.title ?? agent.title
                items.append(
                    PaletteAction(
                        id: threadPaletteActionID(for: agent),
                        title: "Open \(threadTitle)",
                        subtitle: "Focus this provider thread",
                        systemImage: "person.crop.circle",
                        keywords: ["switch", "thread", "provider", agent.providerID, threadTitle.lowercased()]
                    ) {
                        appState.activateAgent(agent.id, in: project.id)
                    }
                )
            }
        }

        return items
    }

    private func followUpPaletteAction(
        mode: PromptFollowUpMode,
        shortcut: String,
        isDefault: Bool,
        agent: AgentInfo
    ) -> PaletteAction {
        let isSteer = mode == .steer
        return PaletteAction(
            id: "prompt:follow-up:\(isDefault ? "default" : "alternate")",
            title: isSteer ? "Steer Active Run" : "Queue Follow-Up",
            subtitle: isSteer
                ? "Guide the active run immediately\(isDefault ? " · default" : " · one message only")"
                : "Run after the current turn\(isDefault ? " · default" : " · one message only")",
            systemImage: isSteer ? "arrow.up.forward.circle.fill" : "plus.circle.fill",
            keywords: isSteer
                ? ["steer", "guide", "interrupt", "follow up", "prompt", "control return", "command return"]
                : ["queue", "later", "after turn", "follow up", "prompt", "control return", "command return"],
            shortcut: shortcut
        ) {
            appState.sendPrompt(for: agent, followUpMode: mode)
        }
    }

    private func lifecycleActionSubtitle(_ action: ThreadLifecycleActionKind) -> String {
        switch action {
        case .deleteDraft:
            "Remove this FlowX-owned draft and its local workspace layout"
        case .archiveProviderTask:
            "Archive this Codex task and its spawned descendants"
        case .deleteProviderTask:
            "Permanently delete this Codex task and its spawned descendants"
        case .moveProviderTaskToTrash:
            "Recoverably move this Claude session to macOS Trash"
        }
    }

    private var hasUsableProvider: Bool {
        appState.providerRegistry.allProviders.contains { provider in
            appState.runtimeHealth[provider.id]?.isUsable == true
                && !provider.availableModels.isEmpty
        }
    }

    private func run(_ action: PaletteAction) {
        dismiss()
        action.perform()
    }

    private func threadPaletteActionID(for agent: AgentInfo) -> String {
        if let identity = agent.nativeThreadBinding?.identity {
            return "thread:\(identity.providerID):\(identity.providerSource):\(identity.sessionID)"
        }
        return "thread:draft:\(agent.id.uuidString)"
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !filteredActions.isEmpty else { return }
        let currentIndex = filteredActions.firstIndex(where: { $0.id == selectedActionID }) ?? 0

        switch direction {
        case .down:
            selectedActionID = filteredActions[min(currentIndex + 1, filteredActions.count - 1)].id
        case .up:
            selectedActionID = filteredActions[max(currentIndex - 1, 0)].id
        default:
            break
        }
    }

    private func dismiss() {
        withAnimation(FXAnimation.panel) {
            appState.commandPaletteVisible = false
        }
    }
}
