import SwiftUI
import FXDesign
import FXTerminal

struct TerminalPanel: View {
    @Bindable var agent: AgentInfo

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle to resize height
            resizeHandle

            // Header bar
            header

            FXDivider()

            // Terminal panes side by side
            HStack(spacing: 0) {
                ForEach(Array(agent.visibleTerminalSessions.enumerated()), id: \.offset) { index, session in
                    if index > 0 {
                        FXDivider(.vertical)
                    }
                    terminalPane(index: index, session: session)
                }
            }
        }
    }

    // MARK: - Resize handle

    private var resizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 6)
            .contentShape(Rectangle())
            .cursor(.resizeUpDown)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let newHeight = agent.workspace.terminalHeight - value.translation.height
                        agent.workspace.terminalHeight = max(120, min(500, newHeight))
                    }
            )
            .overlay(alignment: .top) { FXDivider() }
            .background(FXColors.bgElevated)
            .accessibilityLabel("Resize terminal")
            .accessibilityHint("Drag up or down to change terminal height.")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: FXSpacing.sm) {
            Image(systemName: "terminal")
                .font(.system(size: 11))
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
            withAnimation(FXAnimation.quick) {
                agent.addTerminalPane()
            }
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
                .font(.system(size: 10, weight: .semibold))
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
                .background(FXColors.terminalBg)
        }
        .frame(maxWidth: .infinity)
    }

    private func paneHeader(index: Int, session: TerminalSession) -> some View {
        HStack(spacing: FXSpacing.sm) {
            Text(paneTitle(index: index, session: session))
                .font(FXTypography.captionMedium)
                .foregroundStyle(FXColors.fgSecondary)
                .lineLimit(1)

            Text(session.currentDirectory)
                .font(FXTypography.caption)
                .foregroundStyle(FXColors.fgTertiary)
                .lineLimit(1)

            Spacer(minLength: 0)

            Button(action: {
                withAnimation(FXAnimation.quick) {
                    agent.closeTerminalPane(at: index)
                }
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(FXColors.fgTertiary)
                    .frame(width: 22, height: 22)
                    .background(FXColors.bgSurface.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: FXRadii.xs))
            }
            .buttonStyle(.plain)
            .help(agent.terminalPaneCount > 1 ? "Close this split" : "Hide terminal")
            .accessibilityLabel(agent.terminalPaneCount > 1 ? "Close \(paneTitle(index: index, session: session))" : "Hide terminal")
        }
        .padding(.horizontal, FXSpacing.md)
        .padding(.vertical, FXSpacing.xs)
        .background(FXColors.bgSurface)
    }

    private func paneTitle(index: Int, session: TerminalSession) -> String {
        if let title = session.terminalTitle, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        return agent.terminalPaneCount > 1 ? "Terminal \(index + 1)" : "Terminal"
    }
}

// MARK: - Resize cursor

private extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}
