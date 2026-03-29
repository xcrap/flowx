import AppKit
import SwiftUI
import FXDesign

struct ProjectRow: View {
    @Environment(AppState.self) private var appState
    @Bindable var project: ProjectState

    var body: some View {
        VStack(alignment: .leading, spacing: FXSpacing.xs) {
            // Project header
            Button(action: { withAnimation(FXAnimation.snappy) { project.isExpanded.toggle() } }) {
                HStack(spacing: FXSpacing.sm) {
                    Image(systemName: project.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(FXColors.fgTertiary)
                        .frame(width: 12)

                    Text(project.project.name.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(FXColors.fgTertiary)
                        .tracking(0.8)

                    Spacer()
                }
                .padding(.horizontal, FXSpacing.md)
                .padding(.vertical, FXSpacing.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button(action: { _ = appState.addAgent(to: project) }) {
                    Label("New Agent", systemImage: "plus.bubble")
                }
                Divider()
                Button(action: showInFinder) {
                    Label("Show in Finder", systemImage: "folder")
                }
                Button(action: copyPath) {
                    Label("Copy Path", systemImage: "doc.on.doc")
                }
                Divider()
                Button(role: .destructive, action: { appState.removeProject(project.id) }) {
                    Label("Remove Project", systemImage: "trash")
                }
            }

            // Agent list
            if project.isExpanded {
                VStack(spacing: FXSpacing.xxxs) {
                    ForEach(project.agents) { agent in
                        AgentRow(agent: agent, projectName: project.project.name)
                    }
                }
            }
        }
    }

    private func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([project.project.rootURL])
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(project.project.rootPath, forType: .string)
    }
}
