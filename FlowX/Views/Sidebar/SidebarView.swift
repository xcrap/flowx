import SwiftUI
import FXDesign

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @State private var threadSearchQuery = ""

    var body: some View {
        VStack(spacing: 0) {
            if !appState.projects.isEmpty {
                taskSearchField
                FXDivider()
            }

            ScrollView {
                if appState.projects.isEmpty {
                    emptyState
                        .padding(.horizontal, FXSpacing.md)
                        .padding(.vertical, FXSpacing.xxxl)
                } else {
                    LazyVStack(spacing: FXSpacing.xl) {
                        ForEach(appState.projects) { project in
                            ProjectRow(
                                project: project,
                                threadSearchQuery: threadSearchQuery
                            )
                        }
                    }
                    .padding(.horizontal, FXSpacing.md)
                    .padding(.top, FXSpacing.md)
                    .padding(.bottom, FXSpacing.lg)
                }
            }

            FXDivider()

            Button(action: { appState.openAddProjectPanel() }) {
                HStack(spacing: FXSpacing.sm) {
                    Image(systemName: "folder.badge.plus")
                        .font(FXTypography.icon(.regular))
                    Text("Add Project")
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
            Button(action: { appState.openAddProjectPanel() }) {
                Label("Add Project", systemImage: "folder.badge.plus")
            }
        }
    }

    private var taskSearchField: some View {
        HStack(spacing: FXSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(FXTypography.icon(.small))
                .foregroundStyle(FXColors.fgQuaternary)

            TextField("Search tasks", text: $threadSearchQuery)
                .textFieldStyle(.plain)
                .font(FXTypography.body)
                .foregroundStyle(FXColors.fgSecondary)
                .accessibilityLabel("Search provider tasks")

            if !threadSearchQuery.isEmpty {
                FXIconButton(
                    icon: "xmark.circle.fill",
                    label: "Clear task search",
                    size: 22
                ) {
                    threadSearchQuery = ""
                }
            }
        }
        .padding(.horizontal, FXSpacing.md)
        .padding(.vertical, FXSpacing.sm)
        .background(FXColors.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: FXRadii.md))
        .overlay(
            RoundedRectangle(cornerRadius: FXRadii.md)
                .strokeBorder(FXColors.borderSubtle, lineWidth: 0.5)
        )
        .padding(.horizontal, FXSpacing.md)
        .padding(.vertical, FXSpacing.sm)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: FXSpacing.lg) {
            Image(systemName: "folder.badge.plus")
                .font(FXTypography.icon(.illustration))
                .foregroundStyle(FXColors.fgTertiary)

            VStack(alignment: .leading, spacing: FXSpacing.xs) {
                Text("No projects yet")
                    .font(FXTypography.title3)
                    .foregroundStyle(FXColors.fgSecondary)

                Text("Add a project below to start conversations, inspect changes, and open terminals side by side.")
                    .font(FXTypography.body)
                    .foregroundStyle(FXColors.fgTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(FXSpacing.xxl)
        .background(FXColors.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: FXRadii.xl))
        .overlay(
            RoundedRectangle(cornerRadius: FXRadii.xl)
                .strokeBorder(FXColors.borderSubtle, lineWidth: 0.5)
        )
    }
}
