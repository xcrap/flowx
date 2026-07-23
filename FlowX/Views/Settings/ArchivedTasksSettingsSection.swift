import SwiftUI
import FXAgent
import FXDesign

struct ArchivedTasksSettingsSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if projectsWithArchivedTasks.isEmpty {
            HStack(spacing: FXSpacing.sm) {
                Image(systemName: "archivebox")
                    .font(FXTypography.icon(.regular))
                    .foregroundStyle(FXColors.fgQuaternary)

                Text("No archived provider tasks")
                    .font(FXTypography.body)
                    .foregroundStyle(FXColors.fgTertiary)
            }
            .padding(.vertical, FXSpacing.xs)
        } else {
            VStack(alignment: .leading, spacing: FXSpacing.lg) {
                ForEach(projectsWithArchivedTasks) { project in
                    ArchivedProjectSettingsGroup(project: project)
                }
            }
        }
    }

    private var projectsWithArchivedTasks: [ProjectState] {
        appState.projects.filter { !$0.archivedNativeThreadBindings.isEmpty }
    }
}

private struct ArchivedProjectSettingsGroup: View {
    @Bindable var project: ProjectState

    var body: some View {
        VStack(alignment: .leading, spacing: FXSpacing.xs) {
            HStack(spacing: FXSpacing.sm) {
                Text(project.project.name)
                    .font(FXTypography.captionMedium)
                    .foregroundStyle(FXColors.fgSecondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Text("\(project.archivedNativeThreadBindings.count)")
                    .font(FXTypography.caption)
                    .foregroundStyle(FXColors.fgQuaternary)
                    .accessibilityLabel("\(project.archivedNativeThreadBindings.count) archived tasks")
            }

            if let notice = project.threadLifecycleNotice {
                archivedNotice(notice)
            }

            ForEach(project.archivedNativeThreadBindings, id: \.identity) { binding in
                ArchivedTaskSettingsRow(binding: binding, project: project)
            }
        }
    }

    private func archivedNotice(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: FXSpacing.sm) {
            Image(systemName: project.threadLifecycleNoticeIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(FXTypography.icon(.small))
                .foregroundStyle(project.threadLifecycleNoticeIsError ? FXColors.error : FXColors.success)

            Text(notice)
                .font(FXTypography.caption)
                .foregroundStyle(project.threadLifecycleNoticeIsError ? FXColors.error : FXColors.fgTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            FXIconButton(icon: "xmark", label: "Dismiss task notice", size: 20) {
                project.threadLifecycleNotice = nil
            }
        }
        .padding(FXSpacing.sm)
        .background(FXColors.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: FXRadii.sm))
    }
}

private struct ArchivedTaskSettingsRow: View {
    @Environment(AppState.self) private var appState
    let binding: NativeThreadBinding
    @Bindable var project: ProjectState

    var body: some View {
        HStack(spacing: FXSpacing.sm) {
            FXActivityDot(color: providerColor)
                .help("\(providerName) archived task")

            Text(binding.title)
                .font(FXTypography.body)
                .foregroundStyle(FXColors.fgSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            Spacer(minLength: 0)

            if isActionInProgress {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Updating archived task")
            } else {
                FXDropdown(
                    sections: actionSections,
                    enabled: !project.isSyncingNativeThreads,
                    panelWidth: 220,
                    placement: .automatic,
                    alignment: .trailing
                ) { isExpanded in
                    Image(systemName: isExpanded ? "xmark" : "ellipsis")
                        .font(FXTypography.icon(.small))
                        .foregroundStyle(isExpanded ? FXColors.accent : FXColors.fgTertiary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                        .accessibilityLabel("Archived task actions")
                }
                .help("Restore or delete archived task")
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
        .contextMenu {
            Button("Restore Task", action: restore)
                .disabled(project.isSyncingNativeThreads || isActionInProgress)

            if canDeletePermanently {
                Divider()
                Button("Delete Permanently", role: .destructive, action: deletePermanently)
                    .disabled(project.isSyncingNativeThreads || isActionInProgress)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(providerName) archived task, \(binding.title)")
    }

    private var actionSections: [FXDropdownSection] {
        var items = [
            FXDropdownItem(
                id: "restore",
                title: "Restore Task",
                subtitle: "Return this task to \(project.project.name)",
                isEnabled: !project.isSyncingNativeThreads && !isActionInProgress,
                action: restore
            ),
        ]

        if canDeletePermanently {
            items.append(
                FXDropdownItem(
                    id: "delete-permanently",
                    title: "Delete Permanently",
                    subtitle: "Cannot be undone; includes spawned tasks",
                    isEnabled: !project.isSyncingNativeThreads && !isActionInProgress,
                    tone: .destructive,
                    action: deletePermanently
                )
            )
        }

        return [FXDropdownSection(id: "archived-task", items: items)]
    }

    private var isActionInProgress: Bool {
        appState.isArchivedThreadActionInProgress(binding.identity)
    }

    private var canDeletePermanently: Bool {
        appState.providerRegistry.provider(for: binding.identity.providerID)
            is any AIProviderNativeThreadDeleting
    }

    private var providerName: String {
        binding.identity.providerID == "claude" ? "Claude" : "Codex"
    }

    private var providerColor: Color {
        binding.identity.providerID == "claude" ? FXColors.accentSecondary : FXColors.accent
    }

    private func restore() {
        appState.unarchiveNativeThread(binding, in: project)
    }

    private func deletePermanently() {
        appState.requestArchivedThreadDeletion(binding, in: project)
    }
}
