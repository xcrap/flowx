import SwiftUI
import FXDesign

struct ChangesPanel: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let project = appState.activeProject {
            VStack(spacing: 0) {
                header(project)
                FXDivider()
                content(project)
            }
        } else {
            panelMessage(
                icon: "arrow.triangle.branch",
                title: "No project selected",
                body: "Choose a project to inspect local changes."
            )
        }
    }

    private func header(_ project: ProjectState) -> some View {
        HStack(spacing: FXSpacing.xxs) {
            ForEach(InspectorComparisonMode.allCases, id: \.self) { mode in
                Button(action: {
                    withAnimation(FXAnimation.quick) {
                        appState.setInspectorComparisonMode(mode, for: project)
                    }
                }) {
                    Text(mode.rawValue)
                        .font(FXTypography.captionMedium)
                        .foregroundStyle(project.inspectorComparisonMode == mode ? FXColors.fg : FXColors.fgTertiary)
                        .padding(.horizontal, FXSpacing.sm)
                        .padding(.vertical, FXSpacing.xxxs)
                        .background(project.inspectorComparisonMode == mode ? FXColors.bgSelected : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: FXRadii.xs))
                }
                .buttonStyle(.plain)
                .disabled(!project.gitInfo.isGitRepo)
            }

            Spacer()

            if let summaryText = summaryText(for: project) {
                Text(summaryText)
                    .font(FXTypography.caption)
                    .foregroundStyle(FXColors.fgTertiary)
            }
        }
        .padding(.horizontal, FXSpacing.md)
        .padding(.vertical, FXSpacing.sm)
        .background(FXColors.bgElevated)
    }

    @ViewBuilder
    private func content(_ project: ProjectState) -> some View {
        if !project.gitInfo.isGitRepo {
            panelMessage(
                icon: "tray",
                title: "No git repository",
                body: "Open a git-backed folder to inspect changes and compare against the current base."
            )
        } else if project.gitInfo.files.isEmpty {
            panelMessage(
                icon: "checkmark.circle",
                title: "No local changes",
                body: "Working tree is clean. Start a prompt or edit files to see changes here."
            )
        } else {
            ScrollView {
                LazyVStack(spacing: FXSpacing.xxs) {
                    ForEach(project.gitInfo.files) { file in
                        fileRow(file, in: project)
                    }
                }
                .padding(.horizontal, FXSpacing.sm)
                .padding(.vertical, FXSpacing.sm)
            }
            .background(FXColors.bg)
        }
    }

    private func fileRow(_ file: GitStatusService.FileStatus, in project: ProjectState) -> some View {
        let isSelected = project.selectedInspectorPath == file.path
        let filename = fileName(for: file.path)
        let parent = parentPath(for: file.path)

        return Button(action: {
            appState.selectInspectorPath(file.path, for: project)
        }) {
            HStack(spacing: FXSpacing.md) {
                Image(systemName: iconName(for: file))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(statusColor(for: file))
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: FXSpacing.xxxs) {
                    Text(filename)
                        .font(FXTypography.captionMedium)
                        .foregroundStyle(isSelected ? FXColors.fg : FXColors.fgSecondary)
                        .lineLimit(1)

                    if let parent, !parent.isEmpty {
                        Text(parent)
                            .font(FXTypography.caption)
                            .foregroundStyle(FXColors.fgTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 0)

                HStack(spacing: FXSpacing.xs) {
                    if file.additions > 0 {
                        Text("+\(file.additions)")
                            .font(FXTypography.monoSmall)
                            .foregroundStyle(FXColors.success)
                    }

                    if file.deletions > 0 {
                        Text("-\(file.deletions)")
                            .font(FXTypography.monoSmall)
                            .foregroundStyle(FXColors.error)
                    }

                    Text(statusLabel(for: file))
                        .font(FXTypography.monoSmall)
                        .foregroundStyle(statusColor(for: file))
                        .padding(.horizontal, FXSpacing.xs)
                        .padding(.vertical, 1)
                        .background(statusColor(for: file).opacity(0.12))
                        .clipShape(Capsule())

                    Image(systemName: file.isStaged ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12))
                        .foregroundStyle(file.isStaged ? FXColors.success : FXColors.fgQuaternary)
                }
            }
            .padding(.horizontal, FXSpacing.md)
            .padding(.vertical, FXSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: FXRadii.md)
                    .fill(isSelected ? FXColors.bgSelected : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: FXRadii.md)
                    .strokeBorder(isSelected ? FXColors.borderMedium : .clear, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func panelMessage(icon: String, title: String, body: String) -> some View {
        VStack(spacing: FXSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(FXColors.fgTertiary)

            VStack(spacing: FXSpacing.xs) {
                Text(title)
                    .font(FXTypography.bodyMedium)
                    .foregroundStyle(FXColors.fgSecondary)

                Text(body)
                    .font(FXTypography.caption)
                    .foregroundStyle(FXColors.fgTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 220)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FXColors.bg)
    }

    private func summaryText(for project: ProjectState) -> String? {
        guard project.gitInfo.isGitRepo else { return nil }
        let count = project.gitInfo.files.count
        return count == 1 ? "1 changed file" : "\(count) changed files"
    }

    private func fileName(for path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private func parentPath(for path: String) -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        return parent == "." ? nil : parent
    }

    private func iconName(for file: GitStatusService.FileStatus) -> String {
        if file.isUntracked {
            return "plus.square.dashed"
        }
        if file.status.contains("D") {
            return "trash"
        }
        if file.status.contains("R") {
            return "arrow.triangle.swap"
        }
        return "doc.text"
    }

    private func statusColor(for file: GitStatusService.FileStatus) -> Color {
        if file.isUntracked {
            return FXColors.success
        }
        if file.status.contains("D") {
            return FXColors.error
        }
        if file.status.contains("R") {
            return FXColors.info
        }
        return FXColors.warning
    }

    private func statusLabel(for file: GitStatusService.FileStatus) -> String {
        if file.isUntracked {
            return "NEW"
        }
        if file.status.contains("D") {
            return "DEL"
        }
        if file.status.contains("R") {
            return "REN"
        }
        if file.status.contains("A") {
            return "ADD"
        }
        return "MOD"
    }
}
