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

    var body: some View {
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

                if appState.settingsVisible {
                    FXDivider(.vertical)
                    SettingsPanel()
                        .frame(width: 380)
                        .transition(.move(edge: .trailing))
                } else if appState.rightPanelVisible {
                    FXDivider(.vertical)
                    RightPanelView()
                        .frame(width: 300)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(FXAnimation.panel, value: appState.sidebarVisible)
            .animation(FXAnimation.panel, value: appState.rightPanelVisible)
            .animation(FXAnimation.panel, value: appState.settingsVisible)
        }
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

                    metadataSeparator

                    Image(systemName: statusIcon(for: agent.status))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(statusColor(for: agent.status))

                    Text(agent.status.rawValue.capitalized)
                        .font(FXTypography.caption)
                        .foregroundStyle(statusColor(for: agent.status))

                    if agent.additions > 0 || agent.deletions > 0 {
                        metadataSeparator
                        Text("+\(agent.additions)")
                            .font(FXTypography.monoSmall)
                            .foregroundStyle(FXColors.success)
                        Text("-\(agent.deletions)")
                            .font(FXTypography.monoSmall)
                            .foregroundStyle(FXColors.error)
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
                        headerButton(icon: "rectangle.split.2x1", active: appState.activeAgent?.workspace.splitOpen == true) {
                            withAnimation(FXAnimation.panel) { appState.activeAgent?.workspace.splitOpen.toggle() }
                        }
                        headerButton(icon: "terminal", active: appState.activeAgent?.workspace.terminalVisible == true) {
                            withAnimation(FXAnimation.panel) { appState.activeAgent?.workspace.terminalVisible.toggle() }
                        }
                        headerButton(icon: "sidebar.right", active: appState.rightPanelVisible) {
                            withAnimation(FXAnimation.panel) { appState.rightPanelVisible.toggle() }
                        }
                        headerButton(icon: "globe", active: appState.activeAgent?.workspace.splitOpen == true && appState.activeAgent?.workspace.splitContent == .browser) {
                            withAnimation(FXAnimation.panel) {
                                if let agent = appState.activeAgent {
                                    if agent.workspace.splitOpen && agent.workspace.splitContent == .browser {
                                        agent.workspace.splitOpen = false
                                    } else {
                                        agent.workspace.splitContent = .browser
                                        agent.workspace.splitOpen = true
                                    }
                                }
                            }
                        }
                        headerButton(icon: "gearshape", active: appState.settingsVisible) {
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

    private func headerButton(icon: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? FXColors.accent : FXColors.fgTertiary)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
