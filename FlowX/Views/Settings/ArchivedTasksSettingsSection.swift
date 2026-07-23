import SwiftUI
import FXAgent
import FXDesign

struct ArchivedTasksSettingsPage: View {
    @Environment(AppState.self) private var appState
    @State private var searchQuery = ""

    var body: some View {
        VStack(spacing: 0) {
            archiveSearch
                .padding(.horizontal, FXSpacing.lg)
                .padding(.vertical, FXSpacing.sm)

            FXDivider()

            ScrollView {
                if archivedTaskCount == 0 {
                    emptyState(
                        title: "No archived tasks",
                        detail: "Tasks archived from Codex or Claude will appear here."
                    )
                } else if projectResults.isEmpty {
                    emptyState(
                        title: "No matching tasks",
                        detail: "Try a different title, project, or provider."
                    )
                } else {
                    LazyVStack(alignment: .leading, spacing: FXSpacing.xl) {
                        ForEach(projectResults) { result in
                            Section {
                                if let notice = result.project.threadLifecycleNotice {
                                    ArchivedProjectNotice(
                                        project: result.project,
                                        notice: notice
                                    )
                                }

                                ForEach(result.bindings, id: \.identity) { binding in
                                    ArchivedTaskSettingsRow(
                                        binding: binding,
                                        project: result.project
                                    )
                                }
                            } header: {
                                projectHeader(result)
                            }
                        }
                    }
                    .padding(.horizontal, FXSpacing.lg)
                    .padding(.vertical, FXSpacing.md)
                    .padding(.bottom, FXSpacing.xxl)
                }
            }
        }
    }

    private var archiveSearch: some View {
        HStack(spacing: FXSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(FXTypography.icon(.small))
                .foregroundStyle(FXColors.fgQuaternary)

            TextField("Search archived tasks", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(FXTypography.body)
                .foregroundStyle(FXColors.fgSecondary)
                .accessibilityLabel("Search archived tasks")

            if !searchQuery.isEmpty {
                FXIconButton(
                    icon: "xmark.circle.fill",
                    label: "Clear archive search",
                    size: 22
                ) {
                    searchQuery = ""
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
    }

    private func projectHeader(_ result: ArchivedProjectResult) -> some View {
        HStack(spacing: FXSpacing.sm) {
            Text(result.project.project.name.uppercased())
                .font(FXTypography.overline)
                .foregroundStyle(FXColors.fgTertiary)
                .tracking(0.35)
                .lineLimit(1)

            Spacer(minLength: 0)

            Text(result.bindings.count == 1 ? "1 task" : "\(result.bindings.count) tasks")
                .font(FXTypography.caption)
                .foregroundStyle(FXColors.fgQuaternary)
                .accessibilityLabel("\(result.bindings.count) archived tasks")
        }
        .padding(.horizontal, FXSpacing.xs)
    }

    private func emptyState(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: FXSpacing.sm) {
            Image(systemName: "archivebox")
                .font(FXTypography.icon(.large))
                .foregroundStyle(FXColors.fgQuaternary)

            Text(title)
                .font(FXTypography.bodyMedium)
                .foregroundStyle(FXColors.fgSecondary)

            Text(detail)
                .font(FXTypography.caption)
                .foregroundStyle(FXColors.fgTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(FXSpacing.xl)
    }

    private var projectResults: [ArchivedProjectResult] {
        appState.projects.compactMap { project in
            let bindings = project.archivedNativeThreadBindings.filter { binding in
                guard !searchTerms.isEmpty else { return true }
                let searchableText = [
                    project.project.name,
                    binding.title,
                    binding.preview,
                    binding.identity.providerID,
                    binding.model ?? "",
                ]
                .joined(separator: " ")
                .folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                )
                return searchTerms.allSatisfy {
                    searchableText.contains(String($0))
                }
            }

            guard !bindings.isEmpty else { return nil }
            return ArchivedProjectResult(project: project, bindings: bindings)
        }
    }

    private var searchTerms: [Substring] {
        searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            .split(whereSeparator: \.isWhitespace)
    }

    private var archivedTaskCount: Int {
        appState.projects.reduce(0) {
            $0 + $1.archivedNativeThreadBindings.count
        }
    }
}

private struct ArchivedProjectResult: Identifiable {
    let project: ProjectState
    let bindings: [NativeThreadBinding]

    var id: UUID {
        project.id
    }
}

private struct ArchivedProjectNotice: View {
    @Bindable var project: ProjectState
    let notice: String

    var body: some View {
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
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: FXSpacing.sm) {
            FXActivityDot(color: providerColor)
                .help("\(providerName) archived task")

            VStack(alignment: .leading, spacing: FXSpacing.xxxs) {
                Text(binding.title)
                    .font(FXTypography.bodyMedium)
                    .foregroundStyle(FXColors.fgSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: FXSpacing.xs) {
                    Text(providerName.uppercased())
                        .font(FXTypography.overline)
                        .foregroundStyle(providerColor)

                    Text("·")
                        .font(FXTypography.caption)
                        .foregroundStyle(FXColors.fgQuaternary)

                    Text(binding.updatedAt.formatted(date: .abbreviated, time: .omitted))
                        .font(FXTypography.caption)
                        .foregroundStyle(FXColors.fgTertiary)
                        .lineLimit(1)
                }
            }
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
        .padding(.vertical, FXSpacing.xs)
        .frame(minHeight: 48)
        .background(isHovered ? FXColors.bgHover : FXColors.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: FXRadii.md))
        .overlay {
            RoundedRectangle(cornerRadius: FXRadii.md)
                .strokeBorder(FXColors.borderSubtle, lineWidth: 0.5)
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            if canRename {
                Button("Rename Task…", action: rename)
                    .disabled(project.isSyncingNativeThreads || isActionInProgress)
                Divider()
            }

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
        var items: [FXDropdownItem] = []
        if canRename {
            items.append(
                FXDropdownItem(
                    id: "rename",
                    title: "Rename Task…",
                    subtitle: "Update this task in \(providerName) and FlowX",
                    isEnabled: !project.isSyncingNativeThreads && !isActionInProgress,
                    action: rename
                )
            )
        }
        items.append(
            FXDropdownItem(
                id: "restore",
                title: "Restore Task",
                subtitle: "Return this task to \(project.project.name)",
                isEnabled: !project.isSyncingNativeThreads && !isActionInProgress,
                action: restore
            )
        )

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

    private var canRename: Bool {
        appState.canRenameArchivedNativeThread(binding)
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

    private func rename() {
        appState.requestArchivedThreadRename(binding, in: project)
    }

    private func deletePermanently() {
        appState.requestArchivedThreadDeletion(binding, in: project)
    }
}
