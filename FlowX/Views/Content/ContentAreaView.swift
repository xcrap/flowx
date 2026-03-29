import AppKit
import SwiftUI
import FXDesign

struct ContentAreaView: View {
    @Environment(AppState.self) private var appState
    @State private var splitDragStartWidth: CGFloat?
    @State private var liveSplitPanelWidth: CGFloat?
    @State private var splitHandleHovered = false

    private let splitPanelHandleWidth: CGFloat = 12
    private let minimumConversationWidth: CGFloat = 880
    private let minimumSplitPanelWidth: CGFloat = 320

    var body: some View {
        if let agent = appState.activeAgent {
            GeometryReader { geo in
                VStack(spacing: 0) {
                    // Upper zone: conversation (or horizontal split)
                    upperZone(agent: agent)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: agent.workspace.terminalVisible
                                ? max(200, geo.size.height - agent.workspace.terminalHeight)
                                : .infinity
                        )

                    // Bottom terminal panel
                    if agent.workspace.terminalVisible {
                        TerminalPanel(agent: agent)
                            .frame(height: agent.workspace.terminalHeight)
                            .transition(.slideFromBottom)
                    }
                }
            }
            .background(FXColors.contentBg)
            .animation(FXAnimation.panel, value: agent.workspace.terminalVisible)
            .animation(FXAnimation.panel, value: agent.workspace.splitOpen)
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private func upperZone(agent: AgentInfo) -> some View {
        GeometryReader { geometry in
            let splitVisible = agent.workspace.splitOpen
            let splitWidth = displayedSplitPanelWidth(in: geometry.size.width, for: agent)

            HStack(spacing: 0) {
                ConversationView(agent: agent)
                    .id(agent.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(minWidth: minimumConversationWidth)

                splitPanelContainer(
                    agent: agent,
                    visible: splitVisible,
                    width: splitWidth,
                    totalWidth: geometry.size.width
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
    }

    @ViewBuilder
    private func splitContentView(agent: AgentInfo) -> some View {
        switch agent.workspace.splitContent {
        case .diff:
            unavailableSplitView
        case .browser:
            BrowserPanel(agent: agent)
                .id(agent.id)
        }
    }

    private var emptyState: some View {
        VStack(spacing: FXSpacing.lg) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundStyle(FXColors.fgTertiary)

            if let project = appState.activeProject {
                Text("No agents in this project")
                    .font(FXTypography.title3)
                    .foregroundStyle(FXColors.fgSecondary)
                Text("Create a new agent to start a conversation in \(project.project.name).")
                    .font(FXTypography.body)
                    .foregroundStyle(FXColors.fgTertiary)
                Button(action: { _ = appState.addAgent(to: project) }) {
                    Text("New Agent")
                        .font(FXTypography.bodyMedium)
                        .foregroundStyle(FXColors.fg)
                        .padding(.horizontal, FXSpacing.lg)
                        .padding(.vertical, FXSpacing.md)
                        .background(FXColors.bgSurface)
                        .clipShape(RoundedRectangle(cornerRadius: FXRadii.md))
                }
                .buttonStyle(.plain)
            } else {
                Text("Select an agent to get started")
                    .font(FXTypography.title3)
                    .foregroundStyle(FXColors.fgSecondary)
                Text("Choose a project and agent from the sidebar")
                    .font(FXTypography.body)
                    .foregroundStyle(FXColors.fgTertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FXColors.contentBg)
    }

    private var unavailableSplitView: some View {
        VStack(spacing: FXSpacing.md) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(FXColors.fgTertiary)

            VStack(spacing: FXSpacing.xs) {
                Text("Git diff unavailable")
                    .font(FXTypography.bodyMedium)
                    .foregroundStyle(FXColors.fgSecondary)

                Text(unavailableSplitBody)
                    .font(FXTypography.caption)
                    .foregroundStyle(FXColors.fgTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 220)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FXColors.contentBg)
    }

    private var unavailableSplitBody: String {
        "Git now lives in the right-side Git panel."
    }

    private func splitPanelContainer(agent: AgentInfo, visible: Bool, width: CGFloat, totalWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            splitResizeHandle(totalWidth: totalWidth, agent: agent)
            splitContentView(agent: agent)
                .frame(width: max(0, width - splitPanelHandleWidth))
                .frame(maxHeight: .infinity)
        }
        .frame(width: width, alignment: .trailing)
        .offset(x: visible ? 0 : width)
        .frame(width: visible ? width : 0, alignment: .trailing)
        .clipped()
        .compositingGroup()
        .allowsHitTesting(visible)
    }

    private func splitPanelWidth(in totalWidth: CGFloat, for agent: AgentInfo) -> CGFloat {
        let proposedWidth = totalWidth * agent.workspace.splitRatio
        return clampSplitPanelWidth(proposedWidth, totalWidth: totalWidth)
    }

    private func displayedSplitPanelWidth(in totalWidth: CGFloat, for agent: AgentInfo) -> CGFloat {
        let sourceWidth = liveSplitPanelWidth ?? splitPanelWidth(in: totalWidth, for: agent)
        return clampSplitPanelWidth(sourceWidth, totalWidth: totalWidth)
    }

    private func clampSplitPanelWidth(_ width: CGFloat, totalWidth: CGFloat) -> CGFloat {
        let bounds = splitPanelWidthBounds(totalWidth: totalWidth)
        return min(max(width, bounds.lowerBound), bounds.upperBound)
    }

    private func splitPanelWidthBounds(totalWidth: CGFloat) -> ClosedRange<CGFloat> {
        let maximumWidth = max(0, totalWidth - minimumConversationWidth)
        let minimumWidth = min(minimumSplitPanelWidth, maximumWidth)
        return minimumWidth ... maximumWidth
    }

    private func splitResizeHandle(totalWidth: CGFloat, agent: AgentInfo) -> some View {
        Rectangle()
            .fill(.clear)
            .frame(width: splitPanelHandleWidth)
            .overlay {
                Rectangle()
                    .fill(splitHandleHovered ? FXColors.accent.opacity(0.8) : FXColors.borderSubtle)
                    .frame(width: 1)
            }
            .contentShape(Rectangle())
            .background(splitHandleHovered ? FXColors.accent.opacity(0.08) : .clear)
            .onHover { hovering in
                splitHandleHovered = hovering
                if hovering {
                    NSCursor.resizeLeftRight.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if splitDragStartWidth == nil {
                            splitDragStartWidth = displayedSplitPanelWidth(in: totalWidth, for: agent)
                            liveSplitPanelWidth = splitDragStartWidth
                        }

                        let baseWidth = splitDragStartWidth ?? displayedSplitPanelWidth(in: totalWidth, for: agent)
                        let proposedWidth = baseWidth - value.translation.width
                        liveSplitPanelWidth = clampSplitPanelWidth(proposedWidth, totalWidth: totalWidth)
                    }
                    .onEnded { _ in
                        if let liveSplitPanelWidth {
                            agent.workspace.splitRatio = liveSplitPanelWidth / max(totalWidth, 1)
                        }

                        liveSplitPanelWidth = nil
                        splitDragStartWidth = nil
                        if splitHandleHovered {
                            NSCursor.resizeLeftRight.set()
                        } else {
                            NSCursor.arrow.set()
                        }
                    }
            )
            .help("Resize browser pane")
    }
}
