import SwiftUI
import FXDesign

struct RightPanelView: View {
    @Environment(AppState.self) private var appState
    @FocusState private var commitMessageFocused: Bool

    private var activeProject: ProjectState? {
        appState.activeProject
    }

    private var gitInfo: GitStatusService.GitInfo? {
        activeProject?.gitInfo
    }

    private var showsCommitButton: Bool {
        appState.rightPanelTab == .changes && (gitInfo?.isGitRepo == true) && (gitInfo?.hasChanges == true)
    }

    private var showsPushButton: Bool {
        appState.rightPanelTab == .changes && (gitInfo?.canPush == true)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                ForEach(RightPanelTab.allCases, id: \.self) { tab in
                    tabButton(tab, isActive: appState.rightPanelTab == tab) {
                        withAnimation(FXAnimation.quick) {
                            appState.rightPanelTab = tab
                        }
                    }
                }
                Spacer()

                if let project = activeProject, showsCommitButton {
                    FXButton(project.commitComposerVisible ? "Cancel" : "Commit", icon: project.commitComposerVisible ? "xmark" : "checkmark", style: .secondary) {
                        appState.toggleCommitComposer()
                    }
                    .disabled(project.isPerformingGitAction)
                    .opacity(project.isPerformingGitAction ? 0.5 : 1.0)
                    .padding(.trailing, FXSpacing.sm)
                }

                if showsPushButton {
                    FXButton("Push", icon: "arrow.up", style: .primary) {
                        Task { @MainActor in
                            await appState.pushActiveProject()
                        }
                    }
                    .disabled(activeProject?.isPerformingGitAction == true)
                    .opacity(activeProject?.isPerformingGitAction == true ? 0.5 : 1.0)
                    .padding(.trailing, FXSpacing.md)
                }
            }
            .padding(.leading, FXSpacing.md)
            .padding(.vertical, FXSpacing.xs)

            FXDivider()

            if let project = activeProject, appState.rightPanelTab == .changes, project.commitComposerVisible {
                commitComposer(project)
                FXDivider()
            }

            // Content
            switch appState.rightPanelTab {
            case .changes:
                ChangesPanel()
            case .files:
                FilesPanel()
            }
        }
        .background(FXColors.panelBg)
        .onChange(of: activeProject?.commitComposerVisible == true) { _, isVisible in
            guard isVisible else { return }
            Task { @MainActor in
                commitMessageFocused = true
            }
        }
    }

    private func tabButton(_ tab: RightPanelTab, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(tab.rawValue)
                .font(FXTypography.captionMedium)
                .foregroundStyle(isActive ? FXColors.fg : FXColors.fgTertiary)
                .padding(.horizontal, FXSpacing.md)
                .padding(.vertical, FXSpacing.xs)
                .background(
                    isActive ? FXColors.bgSelected : .clear
                )
                .clipShape(RoundedRectangle(cornerRadius: FXRadii.sm))
        }
        .buttonStyle(.plain)
    }

    private func commitComposer(_ project: ProjectState) -> some View {
        @Bindable var project = project
        let hasUntrackedFiles = project.gitInfo.files.contains(where: \.isUntracked)
        let canCommit = !project.isPerformingGitAction && !project.commitMessageDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return VStack(alignment: .leading, spacing: FXSpacing.sm) {
            HStack(spacing: FXSpacing.sm) {
                TextField("Write a commit message", text: $project.commitMessageDraft)
                    .textFieldStyle(.plain)
                    .font(FXTypography.body)
                    .foregroundStyle(FXColors.fg)
                    .padding(.horizontal, FXSpacing.md)
                    .padding(.vertical, FXSpacing.sm)
                    .background(FXColors.bgSurface)
                    .clipShape(RoundedRectangle(cornerRadius: FXRadii.sm))
                    .overlay(
                        RoundedRectangle(cornerRadius: FXRadii.sm)
                            .strokeBorder(FXColors.border, lineWidth: 0.5)
                    )
                    .focused($commitMessageFocused)
                    .onSubmit {
                        guard canCommit else { return }
                        Task { @MainActor in
                            await appState.commitActiveProject()
                        }
                    }

                FXButton(project.isPerformingGitAction ? "Committing..." : "Commit", icon: "checkmark", style: .primary) {
                    Task { @MainActor in
                        await appState.commitActiveProject()
                    }
                }
                .disabled(!canCommit)
                .opacity(canCommit ? 1.0 : 0.5)
            }

            HStack(spacing: FXSpacing.md) {
                if hasUntrackedFiles {
                    Toggle(isOn: $project.includeUntrackedInCommit) {
                        Text("Include untracked files")
                            .font(FXTypography.caption)
                            .foregroundStyle(FXColors.fgSecondary)
                    }
                    .toggleStyle(.checkbox)
                }

                Spacer(minLength: 0)

                if let message = project.gitActionMessage, !message.isEmpty {
                    Text(message)
                        .font(FXTypography.caption)
                        .foregroundStyle(FXColors.error)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .padding(.horizontal, FXSpacing.md)
        .padding(.vertical, FXSpacing.sm)
        .background(FXColors.bgElevated)
    }
}
