import AppKit
import SwiftUI
import FXDesign

struct ContentAreaView: View {
    @Environment(AppState.self) private var appState
    @State private var terminalResizePreview: AgentResizePreview?
    @State private var splitResizePreview: AgentResizePreview?

    private let minimumUpperZoneHeight: CGFloat = 200

    var body: some View {
        if let agent = appState.activeAgent {
            GeometryReader { geometry in
                let terminalHeight = displayedTerminalHeight(
                    previewValue(
                        terminalResizePreview,
                        for: agent,
                        fallback: agent.workspace.terminalHeight
                    ),
                    availableHeight: geometry.size.height
                )

                VStack(spacing: 0) {
                    upperZone(agent: agent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if agent.workspace.terminalVisible {
                        TerminalResizeHandle(
                            terminalHeight: terminalHeight,
                            minimumTerminalHeight: FXLayout.minimumTerminalHeight,
                            maximumTerminalHeight: displayedTerminalHeight(
                                FXLayout.maximumTerminalHeight,
                                availableHeight: geometry.size.height
                            ),
                            backgroundColor: FXColors.bgElevated,
                            lineColor: FXColors.borderSubtle,
                            hoverColor: FXColors.accent,
                            onResizeChanged: { height in
                                setTerminalResizePreview(height, for: agent)
                            },
                            onResizeEnded: { height in
                                if abs(agent.workspace.terminalHeight - height) > 0.5 {
                                    agent.workspace.terminalHeight = height
                                }
                                clearTerminalResizePreview(for: agent)
                            },
                            onResizeCancelled: {
                                clearTerminalResizePreview(for: agent)
                            }
                        )
                        .frame(height: TerminalResizeHandle.height)

                        TerminalPanel(agent: agent)
                            .frame(height: terminalHeight)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .transaction { transaction in
                    transaction.animation = nil
                }
            }
            .background(FXColors.contentBg)
            .onChange(of: agent.id) {
                clearResizePreviews()
            }
            .onDisappear {
                clearResizePreviews()
            }
        } else {
            emptyState
        }
    }

    private func displayedTerminalHeight(
        _ requestedHeight: CGFloat,
        availableHeight: CGFloat
    ) -> CGFloat {
        let maximumAvailableHeight = max(
            0,
            availableHeight
                - minimumUpperZoneHeight
                - TerminalResizeHandle.height
        )
        let upperBound = min(FXLayout.maximumTerminalHeight, maximumAvailableHeight)
        let lowerBound = min(FXLayout.minimumTerminalHeight, upperBound)
        return min(max(requestedHeight, lowerBound), upperBound)
    }

    @ViewBuilder
    private func upperZone(agent: AgentInfo) -> some View {
        GeometryReader { geometry in
            let splitVisible = agent.workspace.splitOpen
            let splitWidth = splitPanelWidth(in: geometry.size.width, for: agent)

            HStack(spacing: 0) {
                ConversationView(agent: agent)
                    .id(agent.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(minWidth: FXLayout.minimumConversationWidth)

                if splitVisible {
                    splitPanelContainer(
                        agent: agent,
                        visible: true,
                        width: splitWidth,
                        totalWidth: geometry.size.width
                    )
                }
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
            BrowserPanel(
                agent: agent,
                browser: appState.browserViewModel(for: agent.id)
            )
                .id(agent.id)
        }
    }

    private var emptyState: some View {
        VStack(spacing: FXSpacing.lg) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(FXTypography.icon(.hero))
                .foregroundStyle(FXColors.fgTertiary)

            if let project = appState.activeProject {
                Text("No provider threads in this project")
                    .font(FXTypography.title3)
                    .foregroundStyle(FXColors.fgSecondary)
                Text("Start a Codex or Claude thread in \(project.project.name). Existing provider threads appear here after sync.")
                    .font(FXTypography.body)
                    .foregroundStyle(FXColors.fgTertiary)
                Button(action: { _ = appState.addAgent(to: project, title: "New Thread") }) {
                    Text("New Thread")
                        .font(FXTypography.bodyMedium)
                        .foregroundStyle(FXColors.fg)
                        .padding(.horizontal, FXSpacing.lg)
                        .padding(.vertical, FXSpacing.md)
                        .background(FXColors.bgSurface)
                        .clipShape(RoundedRectangle(cornerRadius: FXRadii.md))
                }
                .buttonStyle(.plain)
            } else {
                Text("Select a provider thread to get started")
                    .font(FXTypography.title3)
                    .foregroundStyle(FXColors.fgSecondary)
                Text("Choose a project and Codex or Claude thread from the sidebar")
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
                .font(FXTypography.icon(.illustration))
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
                .frame(width: max(0, width - FXLayout.splitPanelResizeHandleWidth))
                .frame(maxHeight: .infinity)
                .clipped()
        }
        .frame(width: width, alignment: .trailing)
        .allowsHitTesting(visible)
    }

    private func splitPanelWidth(in totalWidth: CGFloat, for agent: AgentInfo) -> CGFloat {
        let proposedWidth = previewValue(
            splitResizePreview,
            for: agent,
            fallback: totalWidth * agent.workspace.splitRatio
        )
        return clampSplitPanelWidth(proposedWidth, totalWidth: totalWidth)
    }

    private func clampSplitPanelWidth(_ width: CGFloat, totalWidth: CGFloat) -> CGFloat {
        let bounds = splitPanelWidthBounds(totalWidth: totalWidth)
        return min(max(width, bounds.lowerBound), bounds.upperBound)
    }

    private func splitPanelWidthBounds(totalWidth: CGFloat) -> ClosedRange<CGFloat> {
        let maximumWidth = max(0, totalWidth - FXLayout.minimumConversationWidth)
        let preferredMinimumWidth =
            FXLayout.minimumBrowserPreviewWidth + FXLayout.splitPanelResizeHandleWidth
        let minimumWidth = min(preferredMinimumWidth, maximumWidth)
        return minimumWidth ... maximumWidth
    }

    private func splitResizeHandle(totalWidth: CGFloat, agent: AgentInfo) -> some View {
        let bounds = splitPanelWidthBounds(totalWidth: totalWidth)
        return LiveHorizontalResizeHandle(
            width: FXLayout.splitPanelResizeHandleWidth,
            currentPanelWidth: splitPanelWidth(in: totalWidth, for: agent),
            minimumPanelWidth: bounds.lowerBound,
            maximumPanelWidth: bounds.upperBound,
            lineColor: FXColors.borderSubtle,
            hoverColor: FXColors.accent,
            helpText: "Resize browser pane",
            onResizeChanged: { width in
                setSplitResizePreview(width, for: agent)
            },
            onResizeEnded: { width in
                let resolvedWidth = clampSplitPanelWidth(
                    width,
                    totalWidth: totalWidth
                )
                let resolvedRatio = resolvedWidth / max(totalWidth, 1)
                if abs(agent.workspace.splitRatio - resolvedRatio) > 0.0001 {
                    agent.workspace.splitRatio = resolvedRatio
                }
                clearSplitResizePreview(for: agent)
            },
            onResizeCancelled: {
                clearSplitResizePreview(for: agent)
            }
        )
    }

    private func previewValue(
        _ preview: AgentResizePreview?,
        for agent: AgentInfo,
        fallback: CGFloat
    ) -> CGFloat {
        guard preview?.agentID == agent.id else { return fallback }
        return preview?.value ?? fallback
    }

    private func setTerminalResizePreview(_ height: CGFloat, for agent: AgentInfo) {
        if terminalResizePreview?.agentID == agent.id,
           let currentHeight = terminalResizePreview?.value,
           abs(currentHeight - height) < 0.5 {
            return
        }
        withoutAnimation {
            terminalResizePreview = AgentResizePreview(
                agentID: agent.id,
                value: height
            )
        }
    }

    private func clearTerminalResizePreview(for agent: AgentInfo) {
        guard terminalResizePreview?.agentID == agent.id else { return }
        withoutAnimation {
            terminalResizePreview = nil
        }
    }

    private func setSplitResizePreview(_ width: CGFloat, for agent: AgentInfo) {
        if splitResizePreview?.agentID == agent.id,
           let currentWidth = splitResizePreview?.value,
           abs(currentWidth - width) < 0.5 {
            return
        }
        withoutAnimation {
            splitResizePreview = AgentResizePreview(
                agentID: agent.id,
                value: width
            )
        }
    }

    private func clearSplitResizePreview(for agent: AgentInfo) {
        guard splitResizePreview?.agentID == agent.id else { return }
        withoutAnimation {
            splitResizePreview = nil
        }
    }

    private func clearResizePreviews() {
        withoutAnimation {
            terminalResizePreview = nil
            splitResizePreview = nil
        }
    }

    private func withoutAnimation(_ update: () -> Void) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction, update)
    }
}

private struct AgentResizePreview: Equatable {
    let agentID: UUID
    let value: CGFloat
}
