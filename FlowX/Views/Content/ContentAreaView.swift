import SwiftUI
import FXDesign

struct ContentAreaView: View {
    @Environment(AppState.self) private var appState

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
        if agent.workspace.splitOpen {
            HSplitView {
                ConversationView(agent: agent)
                    .frame(minWidth: 480)
                splitContentView(agent: agent)
                    .frame(minWidth: 250)
            }
        } else {
            ConversationView(agent: agent)
        }
    }

    @ViewBuilder
    private func splitContentView(agent: AgentInfo) -> some View {
        switch agent.workspace.splitContent {
        case .diff: DiffView()
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
            Text("Select an agent to get started")
                .font(FXTypography.title3)
                .foregroundStyle(FXColors.fgSecondary)
            Text("Choose a project and agent from the sidebar")
                .font(FXTypography.body)
                .foregroundStyle(FXColors.fgTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FXColors.contentBg)
    }
}
