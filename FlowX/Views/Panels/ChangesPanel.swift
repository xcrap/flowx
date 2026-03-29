import SwiftUI
import FXDesign

struct ChangesPanel: View {
    @Environment(AppState.self) private var appState
    @State private var filterMode: FilterMode = .local

    enum FilterMode: String, CaseIterable {
        case local = "Local"
        case base = "Base"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Filter
            HStack(spacing: FXSpacing.xxs) {
                ForEach(FilterMode.allCases, id: \.self) { mode in
                    Button(action: { withAnimation(FXAnimation.quick) { filterMode = mode } }) {
                        Text(mode.rawValue)
                            .font(FXTypography.captionMedium)
                            .foregroundStyle(filterMode == mode ? FXColors.fg : FXColors.fgTertiary)
                            .padding(.horizontal, FXSpacing.sm)
                            .padding(.vertical, FXSpacing.xxxs)
                            .background(filterMode == mode ? FXColors.bgSelected : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: FXRadii.xs))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, FXSpacing.md)
            .padding(.vertical, FXSpacing.sm)

            FXDivider()

            // File list
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let agent = appState.activeAgent {
                        ForEach(agent.fileChanges) { file in
                            fileRow(file)
                        }
                    }
                }
            }
        }
    }

    private func fileRow(_ file: FileChangeInfo) -> some View {
        Button(action: {
            if let project = appState.activeProject {
                appState.selectInspectorPath(file.path, for: project)
            }
        }) {
            HStack(spacing: FXSpacing.sm) {
                VStack(alignment: .leading, spacing: FXSpacing.xxxs) {
                    Text(file.path)
                        .font(FXTypography.caption)
                        .foregroundStyle(FXColors.fgSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                Spacer(minLength: 0)

                HStack(spacing: FXSpacing.xxs) {
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
                }

                Image(systemName: file.isStaged ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(file.isStaged ? FXColors.success : FXColors.fgTertiary)
            }
            .padding(.horizontal, FXSpacing.md)
            .padding(.vertical, FXSpacing.sm)
        }
        .buttonStyle(.plain)
    }
}
