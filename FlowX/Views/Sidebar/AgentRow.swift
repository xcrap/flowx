import SwiftUI
import FXDesign

struct AgentRow: View {
    @Environment(AppState.self) private var appState
    @Bindable var agent: AgentInfo
    let projectName: String

    @State private var isHovered = false
    @State private var isRenaming = false
    @State private var draftTitle = ""
    @FocusState private var renameFieldFocused: Bool

    private var isSelected: Bool {
        appState.activeAgentID == agent.id
    }

    var body: some View {
        Group {
            if isRenaming {
                renameContent
            } else {
                Button(action: selectAgent) {
                    rowContent
                }
                .buttonStyle(.plain)
            }
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(action: beginRename) {
                Label("Rename", systemImage: "pencil")
            }
            Button(action: { appState.resetConversation(for: agent) }) {
                Label("Reset Conversation", systemImage: "arrow.counterclockwise")
            }
            Divider()
            Button(role: .destructive, action: deleteAgent) {
                Label("Delete Agent", systemImage: "trash")
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: FXSpacing.md) {
            statusDot

            VStack(alignment: .leading, spacing: FXSpacing.xs) {
                Text(agent.title)
                    .font(FXTypography.body)
                    .foregroundStyle(isSelected ? FXColors.fg : FXColors.fgSecondary)
                    .lineLimit(1)

                if agent.additions > 0 || agent.deletions > 0 {
                    changesLine
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, FXSpacing.lg)
        .padding(.vertical, FXSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: FXRadii.md)
                .fill(isSelected ? FXColors.bgSelected : (isHovered ? FXColors.bgHover : .clear))
        )
        .contentShape(Rectangle())
    }

    private var renameContent: some View {
        HStack(spacing: FXSpacing.md) {
            statusDot

            VStack(alignment: .leading, spacing: FXSpacing.xs) {
                TextField("Agent name", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(FXTypography.body)
                    .foregroundStyle(FXColors.fg)
                    .focused($renameFieldFocused)
                    .onSubmit(commitRename)

                if agent.additions > 0 || agent.deletions > 0 {
                    changesLine
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, FXSpacing.lg)
        .padding(.vertical, FXSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: FXRadii.md)
                .fill(FXColors.bgSelected)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FXRadii.md)
                .strokeBorder(FXColors.border, lineWidth: 0.5)
        )
        .onAppear {
            if draftTitle.isEmpty {
                draftTitle = agent.title
            }
            Task { @MainActor in
                renameFieldFocused = true
            }
        }
        .onChange(of: renameFieldFocused) { _, focused in
            if !focused && isRenaming {
                commitRename()
            }
        }
    }

    private var changesLine: some View {
        HStack(spacing: FXSpacing.sm) {
            Text("+\(agent.additions)")
                .font(FXTypography.monoSmall)
                .foregroundStyle(FXColors.success)
            if agent.deletions > 0 {
                Text("-\(agent.deletions)")
                    .font(FXTypography.monoSmall)
                    .foregroundStyle(FXColors.error)
            }
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        switch agent.status {
        case .running:
            PulsingDot(color: FXColors.success)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(FXColors.success)
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(FXColors.error)
        case .idle:
            Circle()
                .fill(FXColors.fgTertiary.opacity(0.3))
                .frame(width: 8, height: 8)
        }
    }

    private func beginRename() {
        draftTitle = agent.title
        isRenaming = true
    }

    private func commitRename() {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            agent.title = trimmed
        }
        draftTitle = agent.title
        isRenaming = false
    }

    private func selectAgent() {
        withAnimation(FXAnimation.snappy) {
            if let project = appState.projects.first(where: { p in p.agents.contains(where: { $0.id == agent.id }) }) {
                appState.activateAgent(agent.id, in: project.id)
            }
        }
    }

    private func deleteAgent() {
        withAnimation(FXAnimation.snappy) {
            appState.removeAgent(agent.id)
        }
    }
}
