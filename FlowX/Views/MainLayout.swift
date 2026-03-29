import SwiftUI
import AppKit
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
    @State private var rightPanelDragStartWidth: CGFloat?
    @State private var liveRightPanelWidth: CGFloat?
    @State private var rightPanelHandleHovered = false

    private let rightPanelHandleWidth: CGFloat = 12
    private let titleBarHeight: CGFloat = 48
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
                                .transition(.move(edge: .leading))
                            FXDivider(.vertical)
                        }

                        ContentAreaView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if appState.activeProjectCanShowGitPanel || appState.rightPanelVisible {
                            rightPanelContainer(totalWidth: geometry.size.width)
                        }
                    }
                    .animation(FXAnimation.panel, value: appState.sidebarVisible)
                    .animation(FXAnimation.panel, value: appState.rightPanelVisible)
                    .animation(FXAnimation.panel, value: appState.settingsVisible)
                }

                if appState.settingsVisible {
                    settingsOverlay(totalSize: geometry.size)
                        .padding(.top, titleBarHeight)
                        .transition(.move(edge: .trailing))
                        .zIndex(5)
                }

                if appState.commandPaletteVisible {
                    CommandPaletteView()
                        .transition(.opacity)
                        .zIndex(10)
                }
            }
        }
    }

    private func rightPanel(totalWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            rightPanelResizeHandle(totalWidth: totalWidth)
            RightPanelView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: displayedRightPanelWidth(in: totalWidth))
    }

    private func rightPanelContainer(totalWidth: CGFloat) -> some View {
        let expandedWidth = displayedRightPanelWidth(in: totalWidth)
        let sheetWidth = expandedWidth
        let visibleWidth = appState.rightPanelVisible ? sheetWidth : 0

        return rightPanel(totalWidth: totalWidth)
        .frame(width: sheetWidth, alignment: .trailing)
        .offset(x: appState.rightPanelVisible ? 0 : sheetWidth)
        .frame(width: visibleWidth, alignment: .trailing)
        .clipped()
        .compositingGroup()
        .allowsHitTesting(appState.rightPanelVisible)
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
        Rectangle()
            .fill(.clear)
            .frame(width: rightPanelHandleWidth)
            .overlay {
                Rectangle()
                    .fill(rightPanelHandleHovered ? FXColors.accent.opacity(0.8) : FXColors.borderSubtle)
                    .frame(width: 1)
            }
            .contentShape(Rectangle())
            .background(rightPanelHandleHovered ? FXColors.accent.opacity(0.08) : .clear)
            .onHover { hovering in
                rightPanelHandleHovered = hovering
                if hovering {
                    NSCursor.resizeLeftRight.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if rightPanelDragStartWidth == nil {
                            rightPanelDragStartWidth = displayedRightPanelWidth(in: totalWidth)
                            liveRightPanelWidth = rightPanelDragStartWidth
                        }

                        let baseWidth = rightPanelDragStartWidth ?? displayedRightPanelWidth(in: totalWidth)
                        let proposedWidth = baseWidth - value.translation.width
                        liveRightPanelWidth = clampRightPanelWidth(proposedWidth, in: totalWidth)
                    }
                    .onEnded { _ in
                        if let liveRightPanelWidth {
                            appState.rightPanelWidth = liveRightPanelWidth
                        }
                        liveRightPanelWidth = nil
                        rightPanelDragStartWidth = nil
                        if rightPanelHandleHovered {
                            NSCursor.resizeLeftRight.set()
                        } else {
                            NSCursor.arrow.set()
                        }
                    }
            )
            .help("Resize git panel")
    }

    private func displayedRightPanelWidth(in totalWidth: CGFloat) -> CGFloat {
        let bounds = rightPanelWidthBounds(in: totalWidth)
        let sourceWidth = liveRightPanelWidth ?? appState.rightPanelWidth
        return min(max(sourceWidth, bounds.lowerBound), bounds.upperBound)
    }

    private func clampRightPanelWidth(_ width: CGFloat, in totalWidth: CGFloat) -> CGFloat {
        let bounds = rightPanelWidthBounds(in: totalWidth)
        return min(max(width, bounds.lowerBound), bounds.upperBound)
    }

    private func rightPanelWidthBounds(in totalWidth: CGFloat) -> ClosedRange<CGFloat> {
        let reservedSidebarWidth: CGFloat = appState.sidebarVisible ? 260 : 0
        let minimumContentWidth: CGFloat = 300
        let maximumVisibleWidth = min(
            FlowXLayoutDefaults.maxRightPanelWidth,
            max(0, totalWidth - reservedSidebarWidth - minimumContentWidth)
        )
        let minimumVisibleWidth = min(FlowXLayoutDefaults.minRightPanelWidth, maximumVisibleWidth)
        return minimumVisibleWidth ... maximumVisibleWidth
    }

    private var titleBar: some View {
        ZStack {
            // Drag handle
            DragHandle()

            // Center: project / agent / branch — truly centered
            if let agent = appState.activeAgent, let project = appState.activeProject {
                HStack(spacing: FXSpacing.sm) {
                    Text(project.project.name)
                        .font(FXTypography.caption)
                        .foregroundStyle(FXColors.fgTertiary)

                    if !agent.branch.isEmpty {
                        metadataSeparator

                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(FXColors.fgSecondary)

                        Text(agent.branch)
                            .font(FXTypography.captionMedium)
                            .foregroundStyle(FXColors.fgSecondary)
                    }

                    metadataSeparator

                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(FXColors.fgSecondary)

                    Text(agent.title)
                        .font(FXTypography.bodyMedium)
                        .foregroundStyle(FXColors.fg)

                    if agent.toolCallCount > 0 {
                        metadataSeparator

                        Image(systemName: "hammer")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(FXColors.fgTertiary)

                        Text("\(agent.toolCallCount)")
                            .font(FXTypography.monoSmall)
                            .foregroundStyle(FXColors.fgSecondary)
                    }

                    if agent.additions > 0 || agent.deletions > 0 {
                        metadataSeparator
                        Button(action: appState.toggleGitPanel) {
                            HStack(spacing: FXSpacing.sm) {
                                Text("+\(agent.additions)")
                                    .font(FXTypography.monoSmall)
                                    .foregroundStyle(FXColors.success)
                                Text("-\(agent.deletions)")
                                    .font(FXTypography.monoSmall)
                                    .foregroundStyle(FXColors.error)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Toggle git panel")
                        .accessibilityLabel("Toggle git panel")
                    }
                }
            }

            // Left: FlowX + Right: buttons
            HStack {
                Text("FlowX")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FXColors.fgTertiary)
                    .padding(.leading, FXSpacing.xxl)

                Spacer()

                if appState.activeAgent != nil {
                    HStack(spacing: FXSpacing.xxs) {
                        headerButton(
                            icon: "terminal",
                            label: "Toggle terminal",
                            active: appState.activeAgent?.workspace.terminalVisible == true
                        ) {
                            withAnimation(FXAnimation.panel) { appState.activeAgent?.workspace.terminalVisible.toggle() }
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
                            withAnimation(FXAnimation.panel) { appState.settingsVisible.toggle() }
                        }
                    }
                }
            }
            .padding(.trailing, FXSpacing.md)
        }
        .frame(height: 48)
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
            FXColors.success
        case .completed:
            FXColors.info
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
        case .completed:
            "checkmark.circle.fill"
        case .error:
            "xmark.circle.fill"
        }
    }

    private func headerButton(icon: String, label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? FXColors.accent : FXColors.fgTertiary)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(active ? "Visible" : "Hidden")
    }
}

private struct CommandPaletteView: View {
    @Environment(AppState.self) private var appState

    @FocusState private var searchFocused: Bool
    @State private var query = ""

    private struct PaletteAction: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let systemImage: String
        let keywords: [String]
        let perform: () -> Void
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.34)
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
            .shadow(color: .black.opacity(0.35), radius: 28, y: 16)
            .padding(.top, 84)
        }
        .onAppear {
            query = ""
            searchFocused = true
        }
        .onExitCommand(perform: dismiss)
    }

    private var searchField: some View {
        HStack(spacing: FXSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(FXColors.fgTertiary)

            TextField("Search actions", text: $query)
                .textFieldStyle(.plain)
                .font(FXTypography.body)
                .foregroundStyle(FXColors.fg)
                .focused($searchFocused)
                .accessibilityLabel("Command palette search")
                .onSubmit {
                    if let first = filteredActions.first {
                        run(first)
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
            VStack(alignment: .leading, spacing: FXSpacing.xxs) {
                if filteredActions.isEmpty {
                    VStack(spacing: FXSpacing.sm) {
                        Image(systemName: "sparkle.magnifyingglass")
                            .font(.system(size: 18, weight: .medium))
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
                                    .font(.system(size: 13, weight: .medium))
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
                            }
                            .padding(.horizontal, FXSpacing.lg)
                            .padding(.vertical, FXSpacing.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(FXColors.bgSurface.opacity(0.45))
                            .clipShape(RoundedRectangle(cornerRadius: FXRadii.lg))
                        }
                        .buttonStyle(.plain)
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

    private var actions: [PaletteAction] {
        var items: [PaletteAction] = [
            PaletteAction(
                title: "Add Project",
                subtitle: "Open a folder and add it to the sidebar",
                systemImage: "folder.badge.plus",
                keywords: ["repo", "project", "folder", "open"]
            ) {
                appState.openAddProjectPanel()
            },
            PaletteAction(
                title: appState.sidebarVisible ? "Hide Sidebar" : "Show Sidebar",
                subtitle: "Toggle the left project sidebar",
                systemImage: "sidebar.left",
                keywords: ["sidebar", "navigation", "left"]
            ) {
                withAnimation(FXAnimation.panel) {
                    appState.sidebarVisible.toggle()
                }
            },
            PaletteAction(
                title: appState.rightPanelVisible ? "Hide Git Panel" : "Show Git Panel",
                subtitle: "Toggle the right git panel",
                systemImage: "sidebar.right",
                keywords: ["git", "changes", "diff", "right panel"]
            ) {
                appState.toggleGitPanel()
            },
            PaletteAction(
                title: appState.settingsVisible ? "Hide Settings" : "Show Settings",
                subtitle: "Open the settings panel",
                systemImage: "gearshape",
                keywords: ["settings", "preferences", "config"]
            ) {
                withAnimation(FXAnimation.panel) {
                    appState.settingsVisible.toggle()
                }
            },
        ]

        if let agent = appState.activeAgent {
            items.append(
                PaletteAction(
                    title: agent.workspace.terminalVisible ? "Hide Terminal" : "Show Terminal",
                    subtitle: "Toggle the bottom terminal area",
                    systemImage: "terminal",
                    keywords: ["terminal", "console", "shell"]
                ) {
                    withAnimation(FXAnimation.panel) {
                        agent.workspace.terminalVisible.toggle()
                    }
                }
            )

            items.append(
                PaletteAction(
                    title: (agent.workspace.splitOpen && agent.workspace.splitContent == .browser) ? "Close Browser Split" : "Open Browser Split",
                    subtitle: "Toggle the browser in the split pane",
                    systemImage: "globe",
                    keywords: ["browser", "preview", "web"]
                ) {
                    appState.toggleBrowserPreview()
                }
            )
        }

        if let project = appState.activeProject {
            items.append(
                PaletteAction(
                    title: "New Agent",
                    subtitle: "Create another agent in \(project.project.name)",
                    systemImage: "plus.circle",
                    keywords: ["agent", "create", "new"]
                ) {
                    _ = appState.addAgent(to: project)
                }
            )

            if appState.activeProjectCanShowGitPanel {
                items.append(
                    PaletteAction(
                        title: "Show Git Panel",
                        subtitle: "Inspect current git changes",
                        systemImage: "arrow.triangle.branch",
                    keywords: ["changes", "git", "diff", "inspector"]
                    ) {
                        if !appState.rightPanelVisible {
                            appState.toggleGitPanel()
                        }
                    }
                )
            }

            for agent in project.agents {
                items.append(
                    PaletteAction(
                        title: "Switch to \(agent.title)",
                        subtitle: "Focus this agent conversation",
                        systemImage: "person.crop.circle",
                        keywords: ["switch", "agent", agent.title.lowercased()]
                    ) {
                        appState.activateAgent(agent.id, in: project.id)
                    }
                )
            }
        }

        return items
    }

    private func run(_ action: PaletteAction) {
        dismiss()
        action.perform()
    }

    private func dismiss() {
        withAnimation(FXAnimation.panel) {
            appState.commandPaletteVisible = false
        }
    }
}
