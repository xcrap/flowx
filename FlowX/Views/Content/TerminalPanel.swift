import SwiftUI
import FXDesign
import FXTerminal

struct TerminalPanel: View {
    @Bindable var agent: AgentInfo

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            header

            FXDivider()

            // Terminal panes side by side
            HStack(spacing: 0) {
                ForEach(Array(agent.visibleTerminalSessions.enumerated()), id: \.element.id) { index, session in
                    if index > 0 {
                        FXDivider(.vertical)
                    }
                    terminalPane(index: index, session: session)
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: FXSpacing.sm) {
            Image(systemName: "terminal")
                .font(FXTypography.icon(.small))
                .foregroundStyle(FXColors.fgTertiary)
            Text("Terminal")
                .font(FXTypography.captionMedium)
                .foregroundStyle(FXColors.fgSecondary)

            if agent.terminalPaneCount > 1 {
                Text("\(agent.terminalPaneCount) open")
                    .font(FXTypography.caption)
                    .foregroundStyle(FXColors.fgTertiary)
            }

            Spacer()

            addSplitButton
        }
        .padding(.horizontal, FXSpacing.md)
        .padding(.vertical, FXSpacing.xs)
        .background(FXColors.bgElevated)
    }

    private var addSplitButton: some View {
        terminalControlButton(
            icon: "plus",
            enabled: agent.terminalPaneCount < 3,
            accessibilityLabel: "Add terminal split",
            tooltip: "Add split"
        ) {
            agent.addTerminalPane()
        }
    }

    private func terminalControlButton(
        icon: String,
        enabled: Bool,
        accessibilityLabel: String,
        tooltip: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: {
            guard enabled else { return }
            action()
        }) {
            Image(systemName: icon)
                .font(FXTypography.icon(.micro))
                .foregroundStyle(enabled ? FXColors.fgSecondary : FXColors.fgQuaternary)
                .frame(width: 24, height: 22)
                .background(FXColors.bgSurface.opacity(enabled ? 0.7 : 0.3))
                .clipShape(RoundedRectangle(cornerRadius: FXRadii.xs))
                .overlay(
                    RoundedRectangle(cornerRadius: FXRadii.xs)
                        .strokeBorder(FXColors.borderSubtle, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .disabled(!enabled)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Terminal pane

    private func terminalPane(index: Int, session: TerminalSession) -> some View {
        VStack(spacing: 0) {
            paneHeader(index: index, session: session)
            FXDivider()

            TerminalSurface(session: session)
                .id(session.viewIdentity)
                .background(FXColors.terminalBg)
        }
        .frame(maxWidth: .infinity)
    }

    private func paneHeader(index: Int, session: TerminalSession) -> some View {
        HStack(spacing: FXSpacing.sm) {
            Circle()
                .fill(session.isRunning ? FXColors.success : exitStatusColor(for: session))
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)

            Text(paneTitle(index: index, session: session))
                .font(FXTypography.captionMedium)
                .foregroundStyle(FXColors.fgSecondary)
                .lineLimit(1)

            Text(session.currentDirectory)
                .font(FXTypography.monoSmall)
                .foregroundStyle(FXColors.fgTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(session.currentDirectory)

            Spacer(minLength: 0)

            if let launchError = session.launchError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(FXTypography.icon(.micro))
                    .foregroundStyle(FXColors.warning)
                    .help(launchError)
                    .accessibilityLabel("Terminal launch warning: \(launchError)")
            }

            if !session.isRunning {
                terminalStatusBadge(for: session)

                FXIconButton(icon: "arrow.clockwise", label: "Restart terminal") {
                    session.restart()
                }
            } else {
                FXIconButton(icon: "eraser", label: "Clear terminal") {
                    session.clearScreen()
                    session.focus()
                }
                .disabled(!session.isRunning)

                FXIconButton(icon: "stop.fill", label: "Interrupt terminal", tint: FXColors.warning) {
                    session.interrupt()
                    session.focus()
                }
                .disabled(!session.isRunning)
            }

            FXIconButton(icon: "xmark", label: agent.terminalPaneCount > 1 ? "Close \(paneTitle(index: index, session: session))" : "Hide terminal") {
                agent.closeTerminalPane(at: index)
            }
        }
        .padding(.horizontal, FXSpacing.md)
        .padding(.vertical, FXSpacing.xs)
        .background(FXColors.bgSurface)
        .accessibilityElement(children: .contain)
    }

    private func exitStatusColor(for session: TerminalSession) -> Color {
        if session.launchError != nil { return FXColors.warning }
        guard let exitCode = session.lastExitCode else { return FXColors.fgQuaternary }
        return exitCode == 0 ? FXColors.success : FXColors.error
    }

    private func terminalStatusBadge(for session: TerminalSession) -> some View {
        let text: String
        let tone: FXBadgeTone
        let accessibilityText: String

        if session.launchError != nil {
            text = "Stopped"
            tone = .warning
            accessibilityText = "Terminal stopped with a launch warning"
        } else if let exitCode = session.lastExitCode {
            text = exitCode == 0 ? "Exited" : "Exit \(exitCode)"
            tone = exitCode == 0 ? .success : .error
            accessibilityText = exitCode == 0 ? "Terminal exited successfully" : "Terminal exited with code \(exitCode)"
        } else {
            text = "Stopped"
            tone = .neutral
            accessibilityText = "Terminal stopped"
        }

        return FXBadge(text, tone: tone)
            .accessibilityLabel(accessibilityText)
    }

    private func paneTitle(index: Int, session: TerminalSession) -> String {
        if let title = session.terminalTitle, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        return agent.terminalPaneCount > 1 ? "Terminal \(index + 1)" : "Terminal"
    }
}
