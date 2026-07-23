import AppKit
import SwiftUI
import FXAgent
import FXDesign

struct ProjectRow: View {
    @Environment(AppState.self) private var appState
    @Bindable var project: ProjectState
    let threadSearchQuery: String
    let currentDate: Date

    @State private var visibleThreadLimit = Self.initialVisibleThreadLimit
    @State private var paginatedSearchQuery = ""
    @State private var archivedTasksExpanded = false

    private static let initialVisibleThreadLimit = 24
    private static let visibleThreadIncrement = 24

    var body: some View {
        let matchingAgents = filteredAgents
        let effectiveLimit = paginatedSearchQuery == normalizedSearchQuery
            ? visibleThreadLimit
            : Self.initialVisibleThreadLimit
        let visibleAgents = matchingAgents.prefix(effectiveLimit)
        let remainingThreadCount = max(0, matchingAgents.count - visibleAgents.count)
        let matchingArchivedBindings = filteredArchivedBindings

        VStack(alignment: .leading, spacing: 0) {
            // Project header
            HStack(spacing: FXSpacing.xs) {
                Button(action: { withAnimation(FXAnimation.snappy) { project.isExpanded.toggle() } }) {
                    HStack(spacing: FXSpacing.sm) {
                        Image(systemName: project.isExpanded ? "chevron.down" : "chevron.right")
                            .font(FXTypography.icon(.micro))
                            .foregroundStyle(FXColors.fgTertiary)
                            .frame(width: 12)

                        Text(project.project.name.uppercased())
                            .font(FXTypography.overline)
                            .foregroundStyle(FXColors.fgTertiary)
                            .tracking(0.35)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .allowsTightening(true)
                            .layoutPriority(1)

                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(project.project.name)
                .accessibilityLabel("Toggle \(project.project.name) project")

                if project.isSyncingNativeThreads {
                    ProgressView()
                        .controlSize(.mini)
                        .help("Syncing provider threads")
                        .accessibilityLabel("Syncing provider threads")
                }

                FXDropdown(
                    sections: threadProviderSections,
                    enabled: !threadProviderSections.isEmpty,
                    panelWidth: 220,
                    placement: .below,
                    alignment: .trailing
                ) { isExpanded in
                    Image(systemName: isExpanded ? "xmark" : "plus")
                        .font(FXTypography.icon(.small))
                        .foregroundStyle(isExpanded ? FXColors.accent : FXColors.fgTertiary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                        .accessibilityLabel("New provider thread")
                }
                .help("New provider thread")
            }
            .padding(.leading, FXSpacing.md)
            .padding(.vertical, FXSpacing.xxxs)
            .contextMenu {
                Button(action: createDefaultThread) {
                    Label("New Thread", systemImage: "plus.bubble")
                }
                .disabled(!canCreateDefaultThread)
                Button(action: refreshThreads) {
                    Label("Refresh Provider Threads", systemImage: "arrow.clockwise")
                }
                Divider()
                Button(action: showInFinder) {
                    Label("Show in Finder", systemImage: "folder")
                }
                Button(action: copyPath) {
                    Label("Copy Path", systemImage: "doc.on.doc")
                }
                Divider()
                Button(role: .destructive, action: { appState.removeProject(project.id) }) {
                    Label("Remove Project", systemImage: "trash")
                }
            }

            // Provider-native thread list
            if project.isExpanded || isSearching {
                VStack(alignment: .leading, spacing: FXSpacing.xs) {
                    if let syncError = project.nativeThreadSyncError {
                        syncErrorRow(syncError)
                    }

                    if let notice = project.threadLifecycleNotice {
                        lifecycleNoticeRow(notice)
                    }

                    if project.agents.isEmpty && project.archivedNativeThreadBindings.isEmpty {
                        emptyThreadState
                    } else if matchingAgents.isEmpty && matchingArchivedBindings.isEmpty {
                        noMatchingThreadsState
                    } else if !matchingAgents.isEmpty {
                        LazyVStack(spacing: FXSpacing.xxxs) {
                            ForEach(visibleAgents) { agent in
                                ThreadRow(
                                    agent: agent,
                                    project: project,
                                    currentDate: currentDate
                                )
                            }
                        }

                        if remainingThreadCount > 0 {
                            showMoreThreadsButton(remainingCount: remainingThreadCount)
                        }
                    }

                    if !matchingArchivedBindings.isEmpty {
                        archivedTasksSection(matchingArchivedBindings)
                    }
                }
            }
        }
        .onChange(of: normalizedSearchQuery) { _, newValue in
            paginatedSearchQuery = newValue
            visibleThreadLimit = Self.initialVisibleThreadLimit
        }
    }

    private var normalizedSearchQuery: String {
        threadSearchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private var isSearching: Bool {
        !normalizedSearchQuery.isEmpty
    }

    private var searchTerms: [Substring] {
        normalizedSearchQuery.split(whereSeparator: \.isWhitespace)
    }

    private var filteredAgents: [AgentInfo] {
        guard !searchTerms.isEmpty else { return project.agents }

        return project.agents.filter { agent in
            let binding = agent.nativeThreadBinding
            let searchableText = [
                binding?.title ?? agent.title,
                binding?.preview ?? agent.messages.last?.textContent ?? "",
                agent.providerName,
                agent.providerID,
                binding?.identity.providerSource ?? "draft",
            ]
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

            return searchTerms.allSatisfy { searchableText.contains(String($0)) }
        }
    }

    private var filteredArchivedBindings: [NativeThreadBinding] {
        guard !searchTerms.isEmpty else { return project.archivedNativeThreadBindings }
        return project.archivedNativeThreadBindings.filter { binding in
            let searchableText = [
                binding.title,
                binding.preview,
                binding.identity.providerID,
                "archived",
            ]
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return searchTerms.allSatisfy { searchableText.contains(String($0)) }
        }
    }

    private func lifecycleNoticeRow(_ notice: String) -> some View {
        HStack(spacing: FXSpacing.sm) {
            Image(systemName: project.threadLifecycleNoticeIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(FXTypography.icon(.small))
                .foregroundStyle(project.threadLifecycleNoticeIsError ? FXColors.error : FXColors.success)

            Text(notice)
                .font(FXTypography.caption)
                .foregroundStyle(project.threadLifecycleNoticeIsError ? FXColors.error : FXColors.fgTertiary)
                .lineLimit(2)

            Spacer(minLength: 0)

            FXIconButton(icon: "xmark", label: "Dismiss task notice", size: 20) {
                project.threadLifecycleNotice = nil
            }
        }
        .padding(.horizontal, FXSpacing.md)
        .padding(.vertical, FXSpacing.xs)
    }

    private func archivedTasksSection(_ bindings: [NativeThreadBinding]) -> some View {
        VStack(alignment: .leading, spacing: FXSpacing.xs) {
            Button {
                withAnimation(FXAnimation.snappy) {
                    archivedTasksExpanded.toggle()
                }
            } label: {
                HStack(spacing: FXSpacing.sm) {
                    Image(systemName: (archivedTasksExpanded || isSearching) ? "chevron.down" : "chevron.right")
                        .font(FXTypography.icon(.micro))
                    Image(systemName: "archivebox")
                        .font(FXTypography.icon(.small))
                    Text("ARCHIVED")
                        .font(FXTypography.overline)
                        .tracking(0.8)
                    Spacer(minLength: 0)
                    Text("\(bindings.count)")
                        .font(FXTypography.monoSmall)
                }
                .foregroundStyle(FXColors.fgTertiary)
                .padding(.horizontal, FXSpacing.md)
                .padding(.vertical, FXSpacing.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if archivedTasksExpanded || isSearching {
                LazyVStack(spacing: FXSpacing.xxxs) {
                    ForEach(bindings, id: \.identity) { binding in
                        ArchivedThreadRow(binding: binding, project: project)
                    }
                }
            }
        }
    }

    private func showMoreThreadsButton(remainingCount: Int) -> some View {
        Button {
            paginatedSearchQuery = normalizedSearchQuery
            visibleThreadLimit += Self.visibleThreadIncrement
        } label: {
            HStack(spacing: FXSpacing.sm) {
                Image(systemName: "chevron.down")
                    .font(FXTypography.icon(.micro))

                Text("Show \(min(Self.visibleThreadIncrement, remainingCount)) more")
                    .font(FXTypography.captionMedium)

                Spacer(minLength: 0)

                Text("\(remainingCount) remaining")
                    .font(FXTypography.monoSmall)
                    .foregroundStyle(FXColors.fgQuaternary)
            }
            .foregroundStyle(FXColors.fgTertiary)
            .padding(.horizontal, FXSpacing.md)
            .padding(.vertical, FXSpacing.sm)
            .background(FXColors.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: FXRadii.md))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Loads the next provider task results for this project")
    }

    private var threadProviderSections: [FXDropdownSection] {
        let providers = appState.providerRegistry.allProviders.sorted { $0.displayName < $1.displayName }
        guard !providers.isEmpty else { return [] }

        return [
            FXDropdownSection(
                id: "new-thread-provider",
                title: "Start with provider",
                items: providers.map { provider in
                    let runtimeAvailable = appState.runtimeHealth[provider.id]?.isUsable == true
                    return FXDropdownItem(
                        id: provider.id,
                        title: provider.displayName,
                        subtitle: runtimeAvailable
                            ? "Provider-native conversation"
                            : "Runtime unavailable · install or refresh in Settings",
                        isEnabled: runtimeAvailable && !provider.availableModels.isEmpty
                    ) {
                        createThread(providerID: provider.id)
                    }
                }
            )
        ]
    }

    private func createDefaultThread() {
        let providerID = appState.preferences.resolvedDefaultProviderID(using: appState.providerRegistry)
        createThread(providerID: providerID)
    }

    private var canCreateDefaultThread: Bool {
        let providerID = appState.preferences.resolvedDefaultProviderID(using: appState.providerRegistry)
        guard let provider = appState.providerRegistry.provider(for: providerID) else { return false }
        return appState.runtimeHealth[providerID]?.isUsable == true
            && !provider.availableModels.isEmpty
    }

    private func createThread(providerID: String) {
        guard let provider = appState.providerRegistry.provider(for: providerID),
              appState.runtimeHealth[providerID]?.isUsable == true,
              !provider.availableModels.isEmpty else { return }

        let thread = appState.addAgent(to: project, title: "New Thread")
        let modelID = appState.preferences.resolvedDefaultModelID(for: providerID, using: appState.providerRegistry)
        let model = provider.availableModels.first(where: { $0.id == modelID }) ?? provider.availableModels[0]

        thread.providerID = providerID
        thread.modelID = model.id
        thread.effort = model.defaultReasoningEffort ?? thread.effort
        thread.conversationState.activeProviderID = providerID
        thread.conversationState.activeModelID = model.id
        thread.conversationState.configuredContextWindow = model.contextWindow
    }

    private var emptyThreadState: some View {
        HStack(alignment: .top, spacing: FXSpacing.sm) {
            Image(systemName: project.isSyncingNativeThreads ? "arrow.triangle.2.circlepath" : "bubble.left.and.bubble.right")
                .font(FXTypography.icon(.regular))
                .foregroundStyle(FXColors.fgQuaternary)

            VStack(alignment: .leading, spacing: FXSpacing.xxxs) {
                Text(project.isSyncingNativeThreads ? "Finding provider threads…" : "No provider threads found")
                    .font(FXTypography.captionMedium)
                    .foregroundStyle(FXColors.fgSecondary)

                Text(project.isSyncingNativeThreads
                    ? "Checking the native Codex and Claude history for this workspace."
                    : "Use + to start a new provider-native conversation.")
                    .font(FXTypography.caption)
                    .foregroundStyle(FXColors.fgTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, FXSpacing.md)
        .padding(.vertical, FXSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var noMatchingThreadsState: some View {
        HStack(alignment: .top, spacing: FXSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(FXTypography.icon(.regular))
                .foregroundStyle(FXColors.fgQuaternary)

            VStack(alignment: .leading, spacing: FXSpacing.xxxs) {
                Text("No matching tasks")
                    .font(FXTypography.captionMedium)
                    .foregroundStyle(FXColors.fgSecondary)

                Text("Try a title, prompt, provider, or source.")
                    .font(FXTypography.caption)
                    .foregroundStyle(FXColors.fgTertiary)
            }
        }
        .padding(.horizontal, FXSpacing.md)
        .padding(.vertical, FXSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func syncErrorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: FXSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(FXTypography.icon(.small))
                .foregroundStyle(FXColors.warning)

            Text(message)
                .font(FXTypography.caption)
                .foregroundStyle(FXColors.fgTertiary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            FXIconButton(icon: "arrow.clockwise", label: "Retry provider sync", size: 24, action: refreshThreads)
        }
        .padding(.horizontal, FXSpacing.md)
        .padding(.vertical, FXSpacing.xs)
        .background(FXColors.warning.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: FXRadii.md))
    }

    private func refreshThreads() {
        guard !project.isSyncingNativeThreads else { return }
        appState.refreshNativeThreads(for: project)
    }

    private func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([project.project.rootURL])
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(project.project.rootPath, forType: .string)
    }
}

private struct ArchivedThreadRow: View {
    @Environment(AppState.self) private var appState
    let binding: NativeThreadBinding
    @Bindable var project: ProjectState

    var body: some View {
        HStack(spacing: FXSpacing.sm) {
            FXBadge(binding.identity.providerID.uppercased(), tone: .accent)

            VStack(alignment: .leading, spacing: FXSpacing.xxxs) {
                Text(binding.title)
                    .font(FXTypography.bodyMedium)
                    .foregroundStyle(FXColors.fgSecondary)
                    .lineLimit(1)

                Text(binding.preview.isEmpty ? "Archived provider task" : flattenedPreview)
                    .font(FXTypography.caption)
                    .foregroundStyle(FXColors.fgTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if isActionInProgress {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Updating archived task")
            } else {
                FXDropdown(
                    sections: actionSections,
                    enabled: !project.isSyncingNativeThreads,
                    panelWidth: 200,
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
                .help("Archived task actions")
            }
        }
        .padding(.horizontal, FXSpacing.md)
        .padding(.vertical, FXSpacing.sm)
        .background(FXColors.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: FXRadii.md))
        .contextMenu {
            Button("Restore Task") {
                restore()
            }
            .disabled(project.isSyncingNativeThreads || isActionInProgress)

            if canDeletePermanently {
                Divider()
                Button("Delete Permanently", role: .destructive) {
                    deletePermanently()
                }
                .disabled(project.isSyncingNativeThreads || isActionInProgress)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Archived Codex task, \(binding.title)")
    }

    private var actionSections: [FXDropdownSection] {
        let restoreItem = FXDropdownItem(
            id: "restore",
            title: "Restore Task",
            subtitle: "Unarchive in Codex",
            isEnabled: !project.isSyncingNativeThreads && !isActionInProgress,
            action: restore
        )
        var items = [restoreItem]
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
        return [
            FXDropdownSection(
                id: "archived-task",
                items: items
            ),
        ]
    }

    private var isActionInProgress: Bool {
        appState.isArchivedThreadActionInProgress(binding.identity)
    }

    private var canDeletePermanently: Bool {
        appState.providerRegistry.provider(for: binding.identity.providerID)
            is any AIProviderNativeThreadDeleting
    }

    private var flattenedPreview: String {
        binding.preview
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private func restore() {
        appState.unarchiveNativeThread(binding, in: project)
    }

    private func deletePermanently() {
        appState.requestArchivedThreadDeletion(binding, in: project)
    }
}
