import SwiftUI
import FXDesign

struct ChangesPanel: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let project = appState.activeProject {
            if project.gitInfo.isGitRepo {
                VStack(spacing: 0) {
                    header(project)
                    FXDivider()
                    content(project)
                }
            } else {
                panelMessage(
                    icon: "tray",
                    title: "No git repository",
                    body: "Open a git-backed folder to inspect changes and compare against the current base."
                )
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
        if visibleFiles(for: project).isEmpty {
            panelMessage(
                icon: emptyStateIcon(for: project.inspectorComparisonMode),
                title: emptyStateTitle(for: project.inspectorComparisonMode),
                body: emptyStateBody(for: project.inspectorComparisonMode)
            )
        } else {
            ScrollView {
                LazyVStack(spacing: FXSpacing.xxs) {
                    ForEach(visibleFiles(for: project)) { file in
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
        let additions = visibleAdditions(for: file, mode: project.inspectorComparisonMode)
        let deletions = visibleDeletions(for: file, mode: project.inspectorComparisonMode)

        return Button(action: {
            appState.selectInspectorPath(file.path, for: project)
        }) {
            HStack(spacing: FXSpacing.md) {
                Image(systemName: iconName(for: file))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(statusColor(for: file, mode: project.inspectorComparisonMode))
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
                    if additions > 0 {
                        Text("+\(additions)")
                            .font(FXTypography.monoSmall)
                            .foregroundStyle(FXColors.success)
                    }

                    if deletions > 0 {
                        Text("-\(deletions)")
                            .font(FXTypography.monoSmall)
                            .foregroundStyle(FXColors.error)
                    }

                    Text(statusLabel(for: file, mode: project.inspectorComparisonMode))
                        .font(FXTypography.monoSmall)
                        .foregroundStyle(statusColor(for: file, mode: project.inspectorComparisonMode))
                        .padding(.horizontal, FXSpacing.xs)
                        .padding(.vertical, 1)
                        .background(statusColor(for: file, mode: project.inspectorComparisonMode).opacity(0.12))
                        .clipShape(Capsule())

                    if file.hasStagedChanges {
                        stageBadge("S", tint: FXColors.success)
                    }

                    if file.hasUnstagedChanges {
                        stageBadge("U", tint: FXColors.warning)
                    }
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
        let count = visibleFiles(for: project).count
        switch project.inspectorComparisonMode {
        case .unstaged:
            return count == 1 ? "1 unstaged file" : "\(count) unstaged files"
        case .staged:
            return count == 1 ? "1 staged file" : "\(count) staged files"
        case .base:
            return count == 1 ? "1 changed file" : "\(count) changed files"
        }
    }

    private func visibleFiles(for project: ProjectState) -> [GitStatusService.FileStatus] {
        switch project.inspectorComparisonMode {
        case .unstaged:
            project.gitInfo.files.filter(\.hasUnstagedChanges)
        case .staged:
            project.gitInfo.files.filter(\.hasStagedChanges)
        case .base:
            project.gitInfo.files
        }
    }

    private func visibleAdditions(for file: GitStatusService.FileStatus, mode: InspectorComparisonMode) -> Int {
        switch mode {
        case .unstaged:
            file.unstagedAdditions
        case .staged:
            file.stagedAdditions
        case .base:
            file.additions
        }
    }

    private func visibleDeletions(for file: GitStatusService.FileStatus, mode: InspectorComparisonMode) -> Int {
        switch mode {
        case .unstaged:
            file.unstagedDeletions
        case .staged:
            file.stagedDeletions
        case .base:
            file.deletions
        }
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

    private func statusColor(for file: GitStatusService.FileStatus, mode: InspectorComparisonMode) -> Color {
        let effectiveStatus = statusCode(for: file, mode: mode)

        if effectiveStatus == "??" {
            return FXColors.success
        }
        if effectiveStatus.contains("D") {
            return FXColors.error
        }
        if effectiveStatus.contains("R") {
            return FXColors.info
        }
        return FXColors.warning
    }

    private func statusLabel(for file: GitStatusService.FileStatus, mode: InspectorComparisonMode) -> String {
        let effectiveStatus = statusCode(for: file, mode: mode)

        if effectiveStatus == "??" {
            return "NEW"
        }
        if effectiveStatus.contains("D") {
            return "DEL"
        }
        if effectiveStatus.contains("R") {
            return "REN"
        }
        if effectiveStatus.contains("A") {
            return "ADD"
        }
        return "MOD"
    }

    private func statusCode(for file: GitStatusService.FileStatus, mode: InspectorComparisonMode) -> String {
        switch mode {
        case .unstaged:
            return file.isUntracked ? "??" : file.unstagedStatus
        case .staged:
            return file.stagedStatus
        case .base:
            if file.hasUnstagedChanges {
                return file.isUntracked ? "??" : file.unstagedStatus
            }
            return file.stagedStatus
        }
    }

    private func emptyStateIcon(for mode: InspectorComparisonMode) -> String {
        switch mode {
        case .unstaged:
            "checkmark.circle"
        case .staged:
            "square.and.arrow.down"
        case .base:
            "checkmark.circle"
        }
    }

    private func emptyStateTitle(for mode: InspectorComparisonMode) -> String {
        switch mode {
        case .unstaged:
            "No unstaged changes"
        case .staged:
            "Nothing staged"
        case .base:
            "No local changes"
        }
    }

    private func emptyStateBody(for mode: InspectorComparisonMode) -> String {
        switch mode {
        case .unstaged:
            "Working tree is clean. Edit files or start a prompt to see unstaged changes here."
        case .staged:
            "Stage changes in git to inspect the exact snapshot that will be committed."
        case .base:
            "Working tree is clean. Start a prompt or edit files to see changes here."
        }
    }

    private func stageBadge(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(FXTypography.monoSmall)
            .foregroundStyle(tint)
            .padding(.horizontal, FXSpacing.xs)
            .padding(.vertical, 1)
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
    }
}
