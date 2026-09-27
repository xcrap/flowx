import SwiftUI
import FXDesign

struct GitCommitComposer: View {
    @Environment(AppState.self) private var appState
    @FocusState private var commitMessageFocused: Bool
    let project: ProjectState

    var body: some View {
        @Bindable var project = project
        let hasUntrackedFiles = project.gitInfo.files.contains(where: \.isUntracked)
        // Only a choice when something is staged and something else is not.
        let offersStagedOnly = project.gitInfo.stagedFileCount > 0 && project.gitInfo.unstagedFileCount > 0
        let stagedOnly = Binding(
            get: { project.commitsStagedOnly },
            set: { project.commitStagedOnlyOverride = $0 }
        )
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
                if offersStagedOnly {
                    Toggle(isOn: stagedOnly) {
                        Text("Staged changes only")
                            .font(FXTypography.caption)
                            .foregroundStyle(FXColors.fgSecondary)
                    }
                    .toggleStyle(.checkbox)
                }

                if hasUntrackedFiles && !project.commitsStagedOnly {
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
        .task { commitMessageFocused = true }
    }
}
