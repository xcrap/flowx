import SwiftUI
import FXDesign

struct SidebarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: FXSpacing.xl) {
                    ForEach(appState.projects) { project in
                        ProjectRow(project: project)
                    }
                }
                .padding(.horizontal, FXSpacing.md)
                .padding(.top, FXSpacing.md)
                .padding(.bottom, FXSpacing.lg)
            }

            FXDivider()

            Button(action: { appState.openAddRepositoryPanel() }) {
                HStack(spacing: FXSpacing.sm) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 12, weight: .medium))
                    Text("Add Repository")
                        .font(FXTypography.bodyMedium)
                    Spacer()
                }
                .foregroundStyle(FXColors.fgSecondary)
                .padding(.horizontal, FXSpacing.lg)
                .padding(.vertical, FXSpacing.lg)
            }
            .buttonStyle(.plain)
        }
        .background(FXColors.sidebarBg)
        .contextMenu {
            Button(action: { appState.openAddRepositoryPanel() }) {
                Label("Add Repository", systemImage: "folder.badge.plus")
            }
        }
    }
}
