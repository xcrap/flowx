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
    let projectName: String

    @State private var isHovered = false

    private var isSelected: Bool {
        appState.activeAgentID == agent.id
    }

    var body: some View {
        Button(action: selectThread) {
            rowContent
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            if let sessionID = agent.conversationState.sessionID, !sessionID.isEmpty {
                Button(action: { copyThreadID(sessionID) }) {
                    Label("Copy Provider Thread ID", systemImage: "doc.on.doc")
                }
                Divider()
            }

            if !agent.isProviderNativeThread {
                Button(role: .destructive, action: removeFromFlowX) {
                    Label("Remove Draft", systemImage: "trash")
                }
            }
        }
        .accessibilityLabel("\(agent.providerName) thread, \(displayTitle)")
        .accessibilityHint("Open this thread in \(projectName)")
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: FXSpacing.xs) {
            HStack(spacing: FXSpacing.sm) {
                providerBadge

                Text(displayTitle)
                    .font(FXTypography.bodyMedium)
                    .foregroundStyle(isSelected ? FXColors.fg : FXColors.fgSecondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                statusIndicator
            }

            HStack(alignment: .firstTextBaseline, spacing: FXSpacing.sm) {
                Text(providerSourceLabel)
                    .font(FXTypography.overline)
                    .foregroundStyle(FXColors.fgQuaternary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 72, alignment: .leading)

                Text(threadPreview)
                    .font(FXTypography.caption)
                    .foregroundStyle(FXColors.fgTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(activityLabel)
                    .font(FXTypography.monoSmall)
                    .foregroundStyle(activityColor)
                    .lineLimit(1)
                    .fixedSize()
            }

            if agent.additions > 0 || agent.deletions > 0 {
                changesLine
            }
        }
        .padding(.horizontal, FXSpacing.md)
        .padding(.vertical, FXSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: FXRadii.md)
                .fill(isSelected ? FXColors.bgSelected : (isHovered ? FXColors.bgHover : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: FXRadii.md)
                .strokeBorder(isSelected ? FXColors.border : .clear, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }

    private var providerBadge: some View {
        FXBadge(providerShortLabel, tone: providerBadgeTone)
            .accessibilityLabel("Source: \(agent.providerName)")
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if !agent.conversationState.pendingUserInputRequests.isEmpty {
            Image(systemName: "questionmark.bubble.fill")
                .font(FXTypography.icon(.small))
                .foregroundStyle(FXColors.accent)
                .accessibilityLabel("Waiting for your input")
        } else if agent.isLoadingNativeTranscript {
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("Loading provider transcript")
        } else if agent.nativeTranscriptError != nil {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(FXTypography.icon(.small))
                .foregroundStyle(FXColors.warning)
                .accessibilityLabel("Provider transcript unavailable")
        } else {
            statusIcon
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch agent.status {
        case .running:
            PulsingDot(color: FXColors.success)
                .accessibilityLabel("Running")
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(FXTypography.icon(.small))
                .foregroundStyle(FXColors.success)
                .accessibilityLabel("Completed")
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .font(FXTypography.icon(.small))
                .foregroundStyle(FXColors.error)
                .accessibilityLabel("Needs attention")
        case .idle:
            Circle()
                .fill(FXColors.fgQuaternary)
                .frame(width: 7, height: 7)
                .accessibilityLabel("Idle")
        }
    }

    private var changesLine: some View {
        HStack(spacing: FXSpacing.sm) {
            Image(systemName: "arrow.triangle.branch")
                .font(FXTypography.icon(.micro))
                .foregroundStyle(FXColors.fgQuaternary)

            if agent.additions > 0 {
                Text("+\(agent.additions)")
                    .font(FXTypography.monoSmall)
                    .foregroundStyle(FXColors.diffAddedFg)
            }
            if agent.deletions > 0 {
                Text("-\(agent.deletions)")
                    .font(FXTypography.monoSmall)
                    .foregroundStyle(FXColors.diffRemovedFg)
            }
        }
    }

    private var providerShortLabel: String {
        switch agent.providerID {
        case "codex":
            "CODEX"
        case "claude":
            "CLAUDE"
        default:
            agent.providerName.uppercased()
        }
    }

    private var providerSourceLabel: String {
        guard let source = agent.nativeThreadBinding?.identity.providerSource,
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "DRAFT"
        }

        return source
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .uppercased()
    }

    private var displayTitle: String {
        let nativeTitle = agent.nativeThreadBinding?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let nativeTitle, !nativeTitle.isEmpty {
            return nativeTitle
        }
        return agent.title
    }

    private var providerBadgeTone: FXBadgeTone {
        switch agent.providerID {
        case "claude":
            .accentSecondary
        default:
            .accent
        }
    }

    private var threadPreview: String {
        if let nativePreview = agent.nativePreview {
            return flattenedPreview(nativePreview)
        }

        guard let latestText = agent.messages.reversed().lazy
            .map(\.textContent)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return agent.conversationState.sessionID == nil ? "Draft · not started" : "Provider thread"
        }

        return flattenedPreview(latestText)
    }

    private func flattenedPreview(_ text: String) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return flattened.isEmpty ? "Provider thread" : flattened
    }

    private var activityLabel: String {
        if !agent.conversationState.pendingUserInputRequests.isEmpty {
            return "INPUT"
        }
        if agent.isLoadingNativeTranscript {
            return "LOADING"
        }
        if agent.nativeTranscriptError != nil {
            return "RETRY"
        }
        if agent.status == .running {
            return "LIVE"
        }

        guard let timestamp = agent.nativeUpdatedAt ?? agent.messages.last?.timestamp else {
            return agent.conversationState.sessionID == nil ? "DRAFT" : "SYNCED"
        }

        return timestamp.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }

    private var activityColor: Color {
        if !agent.conversationState.pendingUserInputRequests.isEmpty {
            return FXColors.accent
        }
        if agent.nativeTranscriptError != nil {
            return FXColors.warning
        }
        return switch agent.status {
        case .running:
            FXColors.success
        case .error:
            FXColors.error
        default:
            FXColors.fgQuaternary
        }
    }

    private func selectThread() {
        withAnimation(FXAnimation.snappy) {
            if let project = appState.projects.first(where: { project in
                project.agents.contains(where: { $0.id == agent.id })
            }) {
                appState.activateAgent(agent.id, in: project.id)
            }
        }
    }

    private func copyThreadID(_ sessionID: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sessionID, forType: .string)
    }

    private func removeFromFlowX() {
        withAnimation(FXAnimation.snappy) {
            appState.removeAgent(agent.id)
        }
    }

}
