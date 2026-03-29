import SwiftUI
import FXDesign

struct FilesPanel: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(appState.activeProject?.repositoryFiles ?? [], id: \.self) { path in
                    Button(action: {
                        if let project = appState.activeProject {
                            appState.selectInspectorPath(path, for: project)
                        }
                    }) {
                        HStack(spacing: FXSpacing.sm) {
                            Image(systemName: "doc")
                                .font(.system(size: 11))
                                .foregroundStyle(FXColors.fgTertiary)
                            Text(path)
                                .font(FXTypography.caption)
                                .foregroundStyle(FXColors.fgSecondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer()
                        }
                        .padding(.horizontal, FXSpacing.md)
                        .padding(.vertical, FXSpacing.sm)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
