import SwiftUI
import AppKit
import FXCore
import FXDesign

private let maximumSplitDiffTextColumns = 160

private struct ParsedDiffLine: Identifiable, Sendable {
    enum Kind: Sendable {
        case meta
        case hunk
        case context
        case addition
        case deletion
    }

    let id: Int
    let kind: Kind
    let text: String
    let oldLine: Int?
    let newLine: Int?
}

private enum SplitDiffSideKind: Sendable {
    case empty
    case context
    case addition
    case deletion
}

private struct SplitDiffRow: Identifiable, Sendable {
    enum Kind: Sendable {
        case meta
        case hunk
        case content
    }

    let id: Int
    let kind: Kind
    let oldLine: Int?
    let newLine: Int?
    let oldText: String
    let newText: String
    let oldSide: SplitDiffSideKind
    let newSide: SplitDiffSideKind
}

private struct DiffTaskKey: Hashable, Sendable {
    let projectID: UUID
    let mode: InspectorComparisonMode
    let contentRevision: UInt64
    let fileSignature: String
}

private struct DiffSection: Identifiable, Sendable {
    let id: String
    let path: String?
    let title: String
    let additions: Int
    let deletions: Int
    let maximumLineNumber: Int
    let estimatedCacheWeight: Int
    let parsedLines: [ParsedDiffLine]
}

private struct SplitSectionRows: Sendable {
    let rows: [SplitDiffRow]
    let maximumOldLine: Int
    let maximumNewLine: Int
    let maximumTextColumns: Int
}

private struct SplitRowsTaskKey: Hashable {
    let displayedDiffKey: DiffTaskKey?
    let displayMode: InspectorDiffDisplayMode
}

@MainActor
private enum DiffSectionCache {
    private struct Entry {
        let sections: [DiffSection]
        let estimatedWeight: Int
        let lineCount: Int
    }

    private static let maxEntries = 4
    private static let maxEstimatedWeight = 48 * 1_024 * 1_024
    private static let maxLineCount = 160_000
    private static var entriesByKey: [DiffTaskKey: Entry] = [:]
    private static var orderedKeys: [DiffTaskKey] = []
    private static var estimatedWeight = 0
    private static var lineCount = 0

    static func sections(for key: DiffTaskKey) -> [DiffSection]? {
        entriesByKey[key]?.sections
    }

    static func store(_ sections: [DiffSection], for key: DiffTaskKey) {
        remove(key)

        let entryWeight = sections.reduce(into: 0) { result, section in
            result += section.estimatedCacheWeight
        }
        let entryLineCount = sections.reduce(into: 0) { result, section in
            result += section.parsedLines.count
        }

        guard entryWeight <= maxEstimatedWeight, entryLineCount <= maxLineCount else {
            return
        }

        entriesByKey[key] = Entry(
            sections: sections,
            estimatedWeight: entryWeight,
            lineCount: entryLineCount
        )
        orderedKeys.append(key)
        estimatedWeight += entryWeight
        lineCount += entryLineCount

        while orderedKeys.count > maxEntries
            || estimatedWeight > maxEstimatedWeight
            || lineCount > maxLineCount {
            remove(orderedKeys[0])
        }
    }

    private static func remove(_ key: DiffTaskKey) {
        orderedKeys.removeAll { $0 == key }
        guard let removedEntry = entriesByKey.removeValue(forKey: key) else {
            return
        }
        estimatedWeight = max(0, estimatedWeight - removedEntry.estimatedWeight)
        lineCount = max(0, lineCount - removedEntry.lineCount)
    }
}

struct DiffView: View {
    @Environment(AppState.self) private var appState

    private static let parseExecutor = BoundedTaskExecutor(maxConcurrentTasks: 1)

    @State private var diffSections: [DiffSection] = []
    @State private var isLoadingDiff = false
    @State private var loadFailureKey: DiffTaskKey?
    @State private var activeLoadKey: DiffTaskKey?
    @State private var displayedDiffKey: DiffTaskKey?
    @State private var collapsedSectionIDs: Set<String> = []
    @State private var splitRowsBySectionID: [String: SplitSectionRows] = [:]

    private let diffSectionAccessoryWidth: CGFloat = 28

    var body: some View {
        if let project = appState.activeProject {
            VStack(spacing: 0) {
                header(project)
                FXDivider()
                content(project)
            }
            .background(FXColors.panelBg)
            .task(id: diffTaskKey(for: project)) {
                await loadProjectDiff(for: project)
            }
            .task(id: splitRowsTaskKey(for: project)) {
                await precomputeSplitRowsIfNeeded(for: project)
            }
        } else {
            messageView(
                title: "No project selected",
                body: "Open a git-backed project to inspect its current diff."
            )
        }
    }

    private func header(_ project: ProjectState) -> some View {
        let visibleFiles = visibleDiffFiles(for: project)
        let fileSections = diffSections.filter { $0.path != nil }

        return HStack(spacing: FXSpacing.md) {
            VStack(alignment: .leading, spacing: FXSpacing.xxxs) {
                Text(diffTitle(for: visibleFiles.count, mode: project.inspectorComparisonMode))
                    .font(FXTypography.captionMedium)
                    .foregroundStyle(FXColors.fgSecondary)
                    .lineLimit(1)

                Text(project.project.name)
                    .font(FXTypography.caption)
                    .foregroundStyle(FXColors.fgTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            comparisonModePicker(project)
            diffDisplayModePicker(project)

            if fileSections.count > 1 {
                changedFilePicker(project, sections: fileSections)
            }
        }
        .padding(.horizontal, FXSpacing.md)
        .padding(.vertical, FXSpacing.sm)
        .background(FXColors.bgElevated)
    }

    @ViewBuilder
    private func content(_ project: ProjectState) -> some View {
        let visibleFiles = visibleDiffFiles(for: project)
        let snapshot = diffTaskKey(for: project)
        let canPreserveDisplayedCanvas = canPreserveDisplayedCanvas(for: snapshot)

        if !project.gitInfo.isGitRepo {
            messageView(
                title: "No git repository",
                body: "Open a git-backed folder to inspect its current diff."
            )
        } else if visibleFiles.isEmpty {
            messageView(
                title: emptyStateTitle(for: project.inspectorComparisonMode),
                body: emptyStateBody(for: project.inspectorComparisonMode)
            )
        } else if displayedDiffKey == snapshot, !diffSections.isEmpty {
            diffWorkspace(
                project: project,
                sections: diffSections,
                scrollTargetPath: project.selectedInspectorPath
            )
        } else if canPreserveDisplayedCanvas {
            diffWorkspace(
                project: project,
                sections: diffSections,
                scrollTargetPath: project.selectedInspectorPath
            )
            .overlay(alignment: .topTrailing) {
                if isLoadingDiff {
                    refreshStatusBadge(title: "Refreshing", isError: false)
                } else if loadFailureKey == snapshot {
                    refreshStatusBadge(title: "Refresh failed", isError: true)
                }
            }
        } else if loadFailureKey == snapshot {
            messageView(
                title: "Diff refresh failed",
                body: "FlowX could not refresh the current project changes."
            )
        } else if displayedDiffKey != snapshot || isLoadingDiff {
            loadingView
        } else {
            messageView(
                title: "Diff unavailable",
                body: "FlowX could not build a git diff for the current project state."
            )
        }
    }

    private var loadingView: some View {
        VStack(spacing: FXSpacing.md) {
            ProgressView()
                .controlSize(.small)

            VStack(spacing: FXSpacing.xs) {
                Text("Loading git diff")
                    .font(FXTypography.bodyMedium)
                    .foregroundStyle(FXColors.fgSecondary)

                Text("Collecting the current project changes.")
                    .font(FXTypography.caption)
                    .foregroundStyle(FXColors.fgTertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FXColors.panelBg)
    }

    private func canPreserveDisplayedCanvas(for snapshot: DiffTaskKey) -> Bool {
        guard !diffSections.isEmpty, let displayedDiffKey else {
            return false
        }
        return displayedDiffKey.projectID == snapshot.projectID
            && displayedDiffKey.mode == snapshot.mode
    }

    private func refreshStatusBadge(title: String, isError: Bool) -> some View {
        HStack(spacing: FXSpacing.xs) {
            if isError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(FXTypography.icon(.small))
                    .foregroundStyle(FXColors.error)
            } else {
                ProgressView()
                    .controlSize(.mini)
                    .tint(FXColors.accent)
            }

            Text(title)
                .font(FXTypography.captionMedium)
                .foregroundStyle(isError ? FXColors.error : FXColors.fgSecondary)
        }
        .padding(.horizontal, FXSpacing.sm)
        .padding(.vertical, FXSpacing.xs)
        .background(FXColors.bgElevated)
        .clipShape(RoundedRectangle(cornerRadius: FXRadii.sm))
        .overlay(
            RoundedRectangle(cornerRadius: FXRadii.sm)
                .strokeBorder(FXColors.border, lineWidth: 0.5)
        )
        .padding(FXSpacing.md)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }

    private func comparisonModePicker(_ project: ProjectState) -> some View {
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
                .accessibilityAddTraits(project.inspectorComparisonMode == mode ? .isSelected : [])
            }
        }
    }

    private func diffDisplayModePicker(_ project: ProjectState) -> some View {
        FXDropdown(
            sections: [
                FXDropdownSection(
                    items: InspectorDiffDisplayMode.allCases.map { mode in
                        FXDropdownItem(
                            id: mode.rawValue,
                            title: mode.rawValue,
                            isSelected: project.inspectorDiffDisplayMode == mode
                        ) {
                            withAnimation(FXAnimation.quick) {
                                project.inspectorDiffDisplayMode = mode
                            }
                        }
                    }
                )
            ],
            panelWidth: 120
        ) { isExpanded in
            HStack(spacing: FXSpacing.xs) {
                Text(project.inspectorDiffDisplayMode.rawValue)
                    .font(FXTypography.captionMedium)
                    .foregroundStyle(FXColors.fg)

                Image(systemName: "chevron.down")
                    .font(FXTypography.icon(.micro))
                    .foregroundStyle(FXColors.fgTertiary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .padding(.horizontal, FXSpacing.sm)
            .padding(.vertical, FXSpacing.xxxs)
            .background(FXColors.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: FXRadii.xs))
        }
        .fixedSize()
    }

    private func diffWorkspace(project: ProjectState, sections: [DiffSection], scrollTargetPath: String?) -> some View {
        let canvasSections = selectedCanvasSections(from: sections, selectedPath: scrollTargetPath)

        return GeometryReader { geometry in
            diffCanvas(
                project: project,
                sections: canvasSections,
                scrollTargetPath: scrollTargetPath,
                viewportWidth: geometry.size.width
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(FXColors.panelBg)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder
    private func diffCanvas(
        project: ProjectState,
        sections: [DiffSection],
        scrollTargetPath: String?,
        viewportWidth: CGFloat
    ) -> some View {
        if project.inspectorDiffDisplayMode == .split {
            splitDiffView(
                project: project,
                sections: sections,
                scrollTargetPath: scrollTargetPath,
                viewportWidth: viewportWidth
            )
        } else {
            diffView(
                project: project,
                sections: sections,
                scrollTargetPath: scrollTargetPath,
                viewportWidth: viewportWidth
            )
        }
    }

    private func changedFilePicker(_ project: ProjectState, sections: [DiffSection]) -> some View {
        let selectedSection = sections.first { $0.path == project.selectedInspectorPath } ?? sections.first
        let selectedValue = selectedSection.map(sectionDisplayPath) ?? "No file selected"

        return FXDropdown(
            sections: [
                FXDropdownSection(
                    id: "changed-files",
                    title: "Changed files",
                    items: sections.map { section in
                        FXDropdownItem(
                            id: section.id,
                            title: sectionDisplayPath(section),
                            subtitle: filePickerSubtitle(section),
                            isSelected: section.path == selectedSection?.path
                        ) {
                            project.selectedInspectorPath = section.path
                        }
                    }
                )
            ],
            panelWidth: 320,
            maxPanelHeight: 360,
            alignment: .trailing
        ) { isExpanded in
            HStack(spacing: FXSpacing.xs) {
                Image(systemName: "list.bullet")
                    .font(FXTypography.icon(.small))

                Text("\(sections.count)")
                    .font(FXTypography.captionMedium)

                Image(systemName: "chevron.down")
                    .font(FXTypography.icon(.micro))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .foregroundStyle(isExpanded ? FXColors.fg : FXColors.fgSecondary)
            .padding(.horizontal, FXSpacing.sm)
            .frame(height: 28)
            .background(isExpanded ? FXColors.bgSelected : FXColors.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: FXRadii.sm))
        }
        .fixedSize()
        .help("Choose from \(sections.count) changed files")
        .accessibilityLabel("Changed file")
        .accessibilityValue("\(selectedValue), \(sections.count) files")
    }

    private func diffView(
        project: ProjectState,
        sections: [DiffSection],
        scrollTargetPath: String?,
        viewportWidth: CGFloat
    ) -> some View {
        let maxLine = sections.reduce(0) { current, section in
            max(current, section.maximumLineNumber)
        }
        let numberWidth = lineNumberWidth(maxLine: maxLine)
        let cardViewportWidth = max(0, viewportWidth - (FXSpacing.md * 2))

        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: FXSpacing.lg) {
                    ForEach(sections) { section in
                        inlineSectionCard(
                            section,
                            selectedPath: scrollTargetPath,
                            project: project,
                            numberWidth: numberWidth,
                            viewportWidth: cardViewportWidth
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, FXSpacing.md)
                .padding(.vertical, FXSpacing.md)
                .textSelection(.enabled)
            }
            .onAppear {
                scrollToSelectedFile(scrollTargetPath, using: proxy, sections: sections)
            }
            .onChange(of: scrollTargetPath) { _, path in
                scrollToSelectedFile(path, using: proxy, sections: sections)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func splitDiffView(
        project: ProjectState,
        sections: [DiffSection],
        scrollTargetPath: String?,
        viewportWidth: CGFloat
    ) -> some View {
        if sections.contains(where: { splitRowsBySectionID[$0.id] == nil }) {
            VStack(spacing: FXSpacing.sm) {
                ProgressView()
                    .controlSize(.small)
                Text("Preparing split diff…")
                    .font(FXTypography.caption)
                    .foregroundStyle(FXColors.fgTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(FXColors.panelBg)
        } else {
            let splitSections = sections.compactMap { splitRowsBySectionID[$0.id] }
            let maxOldLine = splitSections.reduce(0) { max($0, $1.maximumOldLine) }
            let maxNewLine = splitSections.reduce(0) { max($0, $1.maximumNewLine) }
            let numberWidth = max(lineNumberWidth(maxLine: maxOldLine), lineNumberWidth(maxLine: maxNewLine))
            let cardViewportWidth = max(0, viewportWidth - (FXSpacing.md * 2))

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: FXSpacing.lg) {
                        ForEach(sections) { section in
                            let sectionColumnWidth = splitColumnWidth(
                                viewportWidth: cardViewportWidth,
                                numberWidth: numberWidth,
                                maximumTextColumns: splitRowsBySectionID[section.id]?.maximumTextColumns ?? 0
                            )

                            splitSectionCard(
                                section,
                                selectedPath: scrollTargetPath,
                                project: project,
                                numberWidth: numberWidth,
                                viewportWidth: cardViewportWidth,
                                columnWidth: sectionColumnWidth
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, FXSpacing.md)
                    .padding(.vertical, FXSpacing.md)
                    .textSelection(.enabled)
                }
                .onAppear {
                    scrollToSelectedFile(scrollTargetPath, using: proxy, sections: sections)
                }
                .onChange(of: scrollTargetPath) { _, path in
                    scrollToSelectedFile(path, using: proxy, sections: sections)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func splitColumnWidth(
        viewportWidth: CGFloat,
        numberWidth: CGFloat,
        maximumTextColumns: Int
    ) -> CGFloat {
        let font = NSFont.monospacedSystemFont(
            ofSize: FXTypography.terminalPointSize,
            weight: .regular
        )
        let glyphWidth = ceil(
            ("M" as NSString).size(withAttributes: [.font: font]).width
        )
        let lineNumberWidth = numberWidth + (FXSpacing.sm * 2)
        let boundedTextColumns = min(max(0, maximumTextColumns), maximumSplitDiffTextColumns)
        let textWidth = (CGFloat(boundedTextColumns) * glyphWidth) + (FXSpacing.md * 2)
        let minimumColumnWidth = max(0, (viewportWidth - 1) / 2)
        return ceil(max(minimumColumnWidth, lineNumberWidth + textWidth))
    }

    private func inlineSectionCard(
        _ section: DiffSection,
        selectedPath: String?,
        project: ProjectState,
        numberWidth: CGFloat,
        viewportWidth: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            sectionHeader(section, selectedPath: selectedPath, project: project)
                .id(section.id)

            if !isCollapsed(section) {
                ScrollView(.horizontal) {
                    LazyVStack(spacing: 0) {
                        ForEach(section.parsedLines) { line in
                            inlineDiffLine(
                                line,
                                numberWidth: numberWidth,
                                viewportWidth: viewportWidth
                            )
                        }
                    }
                    .frame(minWidth: viewportWidth, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
            }
        }
        .frame(minWidth: viewportWidth, maxWidth: .infinity, alignment: .leading)
        .background(FXColors.bgSurface.opacity(0.24))
        .clipShape(RoundedRectangle(cornerRadius: FXRadii.lg))
        .overlay(
            RoundedRectangle(cornerRadius: FXRadii.lg)
                .strokeBorder(FXColors.border, lineWidth: 0.5)
        )
    }

    private func inlineDiffLine(
        _ line: ParsedDiffLine,
        numberWidth: CGFloat,
        viewportWidth: CGFloat
    ) -> some View {
        HStack(spacing: 0) {
            lineNumberCell(line.oldLine, width: numberWidth, emphasis: line.kind == .deletion ? .deletion : .neutral)
            lineNumberCell(line.newLine, width: numberWidth, emphasis: line.kind == .addition ? .addition : .neutral)

            Text(verbatim: line.text.isEmpty ? " " : line.text)
                .font(FXTypography.mono)
                .foregroundStyle(textColor(for: line.kind))
                .padding(.horizontal, FXSpacing.md)
                .padding(.vertical, 1)
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 0)
        }
        .frame(minWidth: viewportWidth, alignment: .leading)
        .background(backgroundColor(for: line.kind))
    }

    private func splitSectionCard(
        _ section: DiffSection,
        selectedPath: String?,
        project: ProjectState,
        numberWidth: CGFloat,
        viewportWidth: CGFloat,
        columnWidth: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            sectionHeader(section, selectedPath: selectedPath, project: project)
                .id(section.id)

            if !isCollapsed(section) {
                ScrollView(.horizontal) {
                    LazyVStack(spacing: 0) {
                        ForEach(splitRowsBySectionID[section.id]?.rows ?? []) { row in
                            splitRowView(
                                row,
                                numberWidth: numberWidth,
                                viewportWidth: viewportWidth,
                                columnWidth: columnWidth
                            )
                        }
                    }
                    .frame(minWidth: viewportWidth, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
            }
        }
        .frame(minWidth: viewportWidth, maxWidth: .infinity, alignment: .leading)
        .background(FXColors.bgSurface.opacity(0.24))
        .clipShape(RoundedRectangle(cornerRadius: FXRadii.lg))
        .overlay(
            RoundedRectangle(cornerRadius: FXRadii.lg)
                .strokeBorder(FXColors.border, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func splitRowView(
        _ row: SplitDiffRow,
        numberWidth: CGFloat,
        viewportWidth: CGFloat,
        columnWidth: CGFloat
    ) -> some View {
        switch row.kind {
        case .meta:
            splitAnnotationRow(
                text: row.oldText,
                foreground: FXColors.fgTertiary,
                background: FXColors.bgSurface.opacity(0.35),
                viewportWidth: viewportWidth
            )
        case .hunk:
            splitAnnotationRow(
                text: row.oldText,
                foreground: FXColors.info,
                background: FXColors.info.opacity(0.08),
                viewportWidth: viewportWidth
            )
        case .content:
            HStack(spacing: 0) {
                splitDiffCell(
                    line: row.oldLine,
                    text: row.oldText,
                    width: numberWidth,
                    side: row.oldSide,
                    columnWidth: columnWidth
                )

                FXDivider(.vertical)

                splitDiffCell(
                    line: row.newLine,
                    text: row.newText,
                    width: numberWidth,
                    side: row.newSide,
                    columnWidth: columnWidth
                )
            }
            .frame(width: (columnWidth * 2) + 1, alignment: .leading)
        }
    }

    private func sectionHeader(_ section: DiffSection, selectedPath: String?, project: ProjectState) -> some View {
        let isSelected = selectedPath == section.path
        let isCollapsed = isCollapsed(section)

        return HStack(spacing: FXSpacing.sm) {
            Button(action: {
                withAnimation(FXAnimation.quick) {
                    toggleSection(section)
                }
            }) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(FXTypography.icon(.small))
                    .foregroundStyle(FXColors.fgQuaternary)
                    .frame(width: diffSectionAccessoryWidth, height: diffSectionAccessoryWidth)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Expand diff section" : "Collapse diff section")
            .accessibilityLabel(isCollapsed ? "Expand \(section.title) diff" : "Collapse \(section.title) diff")

            Button(action: {
                if let path = section.path {
                    project.selectedInspectorPath = path
                }
            }) {
                HStack(spacing: FXSpacing.sm) {
                    sectionPathLabel(section, isSelected: isSelected)
                    Spacer(minLength: 0)
                    diffCountSummary(section)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            Color.clear
                .frame(width: diffSectionAccessoryWidth, height: 1)
        }
        .padding(.horizontal, FXSpacing.md)
        .padding(.vertical, FXSpacing.sm)
        .frame(minHeight: 46)
        .background(isSelected ? FXColors.bgSelected : FXColors.bgElevated)
        .overlay(alignment: .bottom) {
            FXDivider()
        }
        .contextMenu {
            Button(isCollapsed ? "Expand Diff" : "Collapse Diff") {
                toggleSection(section)
            }
            if let path = section.path {
                Button("Open in Editor") {
                    openFile(path, in: project)
                }
            }
        }
    }

    private func sectionPathLabel(_ section: DiffSection, isSelected: Bool) -> some View {
        Text(sectionDisplayPath(section))
            .font(FXTypography.captionMedium)
            .foregroundStyle(isSelected ? FXColors.fg : FXColors.fgSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func diffCountSummary(_ section: DiffSection) -> some View {
        HStack(spacing: FXSpacing.xs) {
            if section.additions > 0 {
                Text("+\(section.additions)")
                    .font(FXTypography.monoSmall)
                    .foregroundStyle(FXColors.diffAddedFg)
            }

            if section.deletions > 0 {
                Text("-\(section.deletions)")
                    .font(FXTypography.monoSmall)
                    .foregroundStyle(FXColors.diffRemovedFg)
            }
        }
    }

    private func sectionDisplayPath(_ section: DiffSection) -> String {
        guard let path = section.path else { return section.title }
        return path.contains("/") ? path : "./\(path)"
    }

    private func filePickerSubtitle(_ section: DiffSection) -> String? {
        var components: [String] = []
        if section.additions > 0 {
            components.append("+\(section.additions)")
        }
        if section.deletions > 0 {
            components.append("-\(section.deletions)")
        }
        return components.isEmpty ? nil : components.joined(separator: "  ")
    }

    private func messageView(title: String, body: String) -> some View {
        VStack(spacing: FXSpacing.md) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(FXTypography.icon(.illustration))
                .foregroundStyle(FXColors.fgTertiary)

            VStack(spacing: FXSpacing.xs) {
                Text(title)
                    .font(FXTypography.bodyMedium)
                    .foregroundStyle(FXColors.fgSecondary)

                Text(body)
                    .font(FXTypography.caption)
                    .foregroundStyle(FXColors.fgTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FXColors.panelBg)
    }

    private func lineNumberCell(_ value: Int?, width: CGFloat, emphasis: LineNumberEmphasis) -> some View {
        Text(value.map { String($0) } ?? "")
            .font(FXTypography.monoSmall)
            .foregroundStyle(lineNumberColor(for: emphasis))
            .frame(width: width, alignment: .trailing)
            .padding(.horizontal, FXSpacing.sm)
            .padding(.vertical, 1)
            .background(FXColors.bgElevated.opacity(0.55))
    }

    private func splitAnnotationRow(
        text: String,
        foreground: Color,
        background: Color,
        viewportWidth: CGFloat
    ) -> some View {
        HStack(spacing: 0) {
            Text(verbatim: text.isEmpty ? " " : text)
                .font(FXTypography.mono)
                .foregroundStyle(foreground)
                .padding(.horizontal, FXSpacing.md)
                .padding(.vertical, 1)
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 0)
        }
        .frame(minWidth: viewportWidth, alignment: .leading)
        .background(background)
    }

    private func splitDiffCell(
        line: Int?,
        text: String,
        width: CGFloat,
        side: SplitDiffSideKind,
        columnWidth: CGFloat
    ) -> some View {
        HStack(spacing: 0) {
            lineNumberCell(line, width: width, emphasis: lineNumberEmphasis(for: side))

            Text(verbatim: text.isEmpty ? " " : text)
                .font(FXTypography.mono)
                .foregroundStyle(splitTextColor(for: side))
                .padding(.horizontal, FXSpacing.md)
                .padding(.vertical, 1)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: columnWidth, alignment: .leading)
        .background(splitBackgroundColor(for: side))
    }

    nonisolated private static func parseDiff(_ text: String) -> [ParsedDiffLine] {
        var lines: [ParsedDiffLine] = []
        var oldLine: Int?
        var newLine: Int?
        var nextID = 0

        func appendLine(kind: ParsedDiffLine.Kind, text: String, oldLine: Int?, newLine: Int?) {
            lines.append(
                ParsedDiffLine(
                    id: nextID,
                    kind: kind,
                    text: text,
                    oldLine: oldLine,
                    newLine: newLine
                )
            )
            nextID += 1
        }

        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            if index.isMultiple(of: 256), Task.isCancelled {
                return []
            }
            if rawLine.hasPrefix("@@") {
                let hunkLines = Self.hunkLineNumbers(from: rawLine)
                oldLine = hunkLines?.0
                newLine = hunkLines?.1
                appendLine(kind: .hunk, text: rawLine, oldLine: nil, newLine: nil)
                continue
            }

            if rawLine.hasPrefix("diff --git")
                || rawLine.hasPrefix("index ")
                || rawLine.hasPrefix("--- ")
                || rawLine.hasPrefix("+++ ")
                || rawLine.hasPrefix("\\ No newline") {
                continue
            }

            if rawLine.hasPrefix("+"), !rawLine.hasPrefix("+++") {
                appendLine(kind: .addition, text: rawLine, oldLine: nil, newLine: newLine)
                newLine = newLine.map { $0 + 1 }
                continue
            }

            if rawLine.hasPrefix("-"), !rawLine.hasPrefix("---") {
                appendLine(kind: .deletion, text: rawLine, oldLine: oldLine, newLine: nil)
                oldLine = oldLine.map { $0 + 1 }
                continue
            }

            appendLine(kind: .context, text: rawLine, oldLine: oldLine, newLine: newLine)
            oldLine = oldLine.map { $0 + 1 }
            newLine = newLine.map { $0 + 1 }
        }

        return lines
    }

    nonisolated private static func splitRows(from parsedLines: [ParsedDiffLine]) -> SplitSectionRows {
        var rows: [SplitDiffRow] = []
        var index = 0
        var nextID = 0
        var maximumOldLine = 0
        var maximumNewLine = 0
        var maximumTextColumns = 0

        func appendRow(
            kind: SplitDiffRow.Kind,
            oldLine: Int?,
            newLine: Int?,
            oldText: String,
            newText: String,
            oldSide: SplitDiffSideKind,
            newSide: SplitDiffSideKind
        ) {
            rows.append(
                SplitDiffRow(
                    id: nextID,
                    kind: kind,
                    oldLine: oldLine,
                    newLine: newLine,
                    oldText: oldText,
                    newText: newText,
                    oldSide: oldSide,
                    newSide: newSide
                )
            )
            maximumOldLine = max(maximumOldLine, oldLine ?? 0)
            maximumNewLine = max(maximumNewLine, newLine ?? 0)
            maximumTextColumns = max(
                maximumTextColumns,
                Self.displayColumnCount(oldText),
                Self.displayColumnCount(newText)
            )
            nextID += 1
        }

        while index < parsedLines.count {
            if index.isMultiple(of: 256), Task.isCancelled {
                return SplitSectionRows(
                    rows: [],
                    maximumOldLine: maximumOldLine,
                    maximumNewLine: maximumNewLine,
                    maximumTextColumns: maximumTextColumns
                )
            }
            let line = parsedLines[index]

            switch line.kind {
            case .meta:
                appendRow(
                    kind: .meta,
                    oldLine: nil,
                    newLine: nil,
                    oldText: line.text,
                    newText: "",
                    oldSide: .context,
                    newSide: .empty
                )
                index += 1

            case .hunk:
                appendRow(
                    kind: .hunk,
                    oldLine: nil,
                    newLine: nil,
                    oldText: line.text,
                    newText: "",
                    oldSide: .context,
                    newSide: .empty
                )
                index += 1

            case .context:
                let content = Self.splitDisplayText(for: line)
                appendRow(
                    kind: .content,
                    oldLine: line.oldLine,
                    newLine: line.newLine,
                    oldText: content,
                    newText: content,
                    oldSide: .context,
                    newSide: .context
                )
                index += 1

            case .deletion:
                var deletions: [ParsedDiffLine] = []
                while index < parsedLines.count, parsedLines[index].kind == .deletion {
                    if deletions.count.isMultiple(of: 256), Task.isCancelled {
                        return SplitSectionRows(
                            rows: [],
                            maximumOldLine: maximumOldLine,
                            maximumNewLine: maximumNewLine,
                            maximumTextColumns: maximumTextColumns
                        )
                    }
                    deletions.append(parsedLines[index])
                    index += 1
                }

                var additions: [ParsedDiffLine] = []
                let additionStart = index
                while index < parsedLines.count, parsedLines[index].kind == .addition {
                    if additions.count.isMultiple(of: 256), Task.isCancelled {
                        return SplitSectionRows(
                            rows: [],
                            maximumOldLine: maximumOldLine,
                            maximumNewLine: maximumNewLine,
                            maximumTextColumns: maximumTextColumns
                        )
                    }
                    additions.append(parsedLines[index])
                    index += 1
                }

                if additions.isEmpty {
                    index = additionStart
                }

                let pairCount = max(deletions.count, additions.count)
                for offset in 0..<pairCount {
                    if offset.isMultiple(of: 256), Task.isCancelled {
                        return SplitSectionRows(
                            rows: [],
                            maximumOldLine: maximumOldLine,
                            maximumNewLine: maximumNewLine,
                            maximumTextColumns: maximumTextColumns
                        )
                    }
                    let deletion = offset < deletions.count ? deletions[offset] : nil
                    let addition = offset < additions.count ? additions[offset] : nil
                    appendRow(
                        kind: .content,
                        oldLine: deletion?.oldLine,
                        newLine: addition?.newLine,
                        oldText: deletion.map(Self.splitDisplayText(for:)) ?? "",
                        newText: addition.map(Self.splitDisplayText(for:)) ?? "",
                        oldSide: deletion == nil ? .empty : .deletion,
                        newSide: addition == nil ? .empty : .addition
                    )
                }

            case .addition:
                appendRow(
                    kind: .content,
                    oldLine: nil,
                    newLine: line.newLine,
                    oldText: "",
                    newText: Self.splitDisplayText(for: line),
                    oldSide: .empty,
                    newSide: .addition
                )
                index += 1
            }
        }

        if rows.isEmpty {
            let placeholder = SplitDiffRow(
                    id: 0,
                    kind: .meta,
                    oldLine: nil,
                    newLine: nil,
                    oldText: "No diff available.",
                    newText: "",
                    oldSide: .context,
                    newSide: .empty
                )
            return SplitSectionRows(
                rows: [placeholder],
                maximumOldLine: 0,
                maximumNewLine: 0,
                maximumTextColumns: Self.displayColumnCount(placeholder.oldText)
            )
        }

        return SplitSectionRows(
            rows: rows,
            maximumOldLine: maximumOldLine,
            maximumNewLine: maximumNewLine,
            maximumTextColumns: maximumTextColumns
        )
    }

    nonisolated private static func splitRowsMap(from sections: [DiffSection]) -> [String: SplitSectionRows] {
        var rowsBySectionID: [String: SplitSectionRows] = [:]
        rowsBySectionID.reserveCapacity(sections.count)

        for section in sections {
            guard !Task.isCancelled else { return [:] }
            rowsBySectionID[section.id] = splitRows(from: section.parsedLines)
            guard !Task.isCancelled else { return [:] }
        }

        return rowsBySectionID
    }

    nonisolated private static func sections(from text: String) -> [DiffSection] {
        var sections: [DiffSection] = []
        var currentPath: String?
        var currentRawLines: [String] = []

        func flushSection() {
            guard let currentPath else {
                currentRawLines.removeAll(keepingCapacity: true)
                return
            }

            let parsedLines = Self.parseDiff(currentRawLines.joined(separator: "\n"))
            guard !parsedLines.isEmpty else {
                currentRawLines.removeAll(keepingCapacity: true)
                return
            }
            sections.append(
                Self.makeSection(
                    id: currentPath,
                    path: currentPath,
                    lines: parsedLines
                )
            )
            currentRawLines.removeAll(keepingCapacity: true)
        }

        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            if index.isMultiple(of: 256), Task.isCancelled {
                return []
            }
            if rawLine.hasPrefix("diff --git "),
               let anchorPath = Self.diffAnchorPath(from: rawLine) {
                flushSection()
                currentPath = anchorPath
                continue
            }

            currentRawLines.append(rawLine)
        }

        flushSection()
        return sections
    }

    nonisolated private static func makeSection(id: String, path: String?, lines: [ParsedDiffLine]) -> DiffSection {
        var additions = 0
        var deletions = 0
        var maximumLineNumber = 0
        var estimatedCacheWeight = 256
        for line in lines {
            switch line.kind {
            case .addition:
                additions += 1
            case .deletion:
                deletions += 1
            case .meta, .hunk, .context:
                break
            }
            maximumLineNumber = max(
                maximumLineNumber,
                line.oldLine ?? 0,
                line.newLine ?? 0
            )
            estimatedCacheWeight += 96 + line.text.utf8.count
        }

        let title = path.map { ($0 as NSString).lastPathComponent } ?? "Project diff"
        estimatedCacheWeight += id.utf8.count
            + (path?.utf8.count ?? 0)
            + title.utf8.count

        return DiffSection(
            id: id,
            path: path,
            title: title,
            additions: additions,
            deletions: deletions,
            maximumLineNumber: maximumLineNumber,
            estimatedCacheWeight: estimatedCacheWeight,
            parsedLines: lines
        )
    }

    nonisolated private static func splitDisplayText(for line: ParsedDiffLine) -> String {
        switch line.kind {
        case .addition, .deletion, .context:
            String(line.text.dropFirst())
        case .meta, .hunk:
            line.text
        }
    }

    nonisolated private static func displayColumnCount(_ text: String) -> Int {
        var columns = 0
        for scalar in text.unicodeScalars {
            if scalar.value == 9 {
                columns += 4 - (columns % 4)
            } else if scalar.value < 128 {
                columns += 1
            } else {
                // Conservatively reserve two monospace cells for non-ASCII
                // fallback glyphs so code never overlaps the split divider.
                columns += 2
            }
            if columns >= maximumSplitDiffTextColumns {
                return maximumSplitDiffTextColumns
            }
        }
        return columns
    }

    nonisolated private static func hunkLineNumbers(from line: String) -> (Int, Int)? {
        let components = line.split(separator: " ")
        guard components.count >= 3,
              let oldValue = Self.hunkComponentStart(String(components[1])),
              let newValue = Self.hunkComponentStart(String(components[2])) else {
            return nil
        }
        return (oldValue, newValue)
    }

    nonisolated private static func hunkComponentStart(_ component: String) -> Int? {
        let trimmed = component.trimmingCharacters(in: CharacterSet(charactersIn: "-+"))
        let start = trimmed.split(separator: ",").first.map(String.init) ?? trimmed
        return Int(start)
    }

    nonisolated private static func diffAnchorPath(from line: String) -> String? {
        let prefix = "diff --git "
        guard line.hasPrefix(prefix) else { return nil }

        let header = line.dropFirst(prefix.count)
        var cursor = header.startIndex
        guard let oldToken = gitPathToken(in: header, cursor: &cursor),
              let newToken = gitPathToken(in: header, cursor: &cursor) else {
            return nil
        }

        // A deletion names /dev/null on the new side; otherwise the b/ path is
        // authoritative, including rename destinations.
        let selectedToken = newToken == "/dev/null" ? oldToken : newToken
        let path: Substring
        if selectedToken.hasPrefix("a/") || selectedToken.hasPrefix("b/") {
            path = selectedToken.dropFirst(2)
        } else {
            path = selectedToken[...]
        }
        return path.isEmpty ? nil : String(path)
    }

    /// Reads one path from a git patch header. Git wraps paths containing
    /// whitespace or control/non-ASCII bytes in C-style quotes, with UTF-8
    /// bytes represented as octal escapes when `core.quotePath` is enabled.
    nonisolated private static func gitPathToken(
        in text: Substring,
        cursor: inout Substring.Index
    ) -> Substring? {
        while cursor < text.endIndex, text[cursor].isWhitespace {
            cursor = text.index(after: cursor)
        }
        guard cursor < text.endIndex else { return nil }

        guard text[cursor] == "\"" else {
            let start = cursor
            while cursor < text.endIndex, !text[cursor].isWhitespace {
                cursor = text.index(after: cursor)
            }
            return text[start..<cursor]
        }

        cursor = text.index(after: cursor)
        var bytes: [UInt8] = []

        while cursor < text.endIndex {
            let character = text[cursor]
            cursor = text.index(after: cursor)

            if character == "\"" {
                return Substring(String(decoding: bytes, as: UTF8.self))
            }

            guard character == "\\" else {
                bytes.append(contentsOf: String(character).utf8)
                continue
            }

            guard cursor < text.endIndex else { return nil }
            let escaped = text[cursor]
            cursor = text.index(after: cursor)

            if let firstOctal = octalDigit(escaped) {
                var value = Int(firstOctal)
                var digitCount = 1
                while digitCount < 3,
                      cursor < text.endIndex,
                      let nextOctal = octalDigit(text[cursor]) {
                    value = value * 8 + Int(nextOctal)
                    cursor = text.index(after: cursor)
                    digitCount += 1
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
                continue
            }

            switch escaped {
            case "a": bytes.append(7)
            case "b": bytes.append(8)
            case "t": bytes.append(9)
            case "n": bytes.append(10)
            case "v": bytes.append(11)
            case "f": bytes.append(12)
            case "r": bytes.append(13)
            case "\"": bytes.append(34)
            case "\\": bytes.append(92)
            default: bytes.append(contentsOf: String(escaped).utf8)
            }
        }

        return nil
    }

    nonisolated private static func octalDigit(_ character: Character) -> UInt8? {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first,
              (48...55).contains(scalar.value) else {
            return nil
        }
        return UInt8(scalar.value - 48)
    }

    private func diffTaskKey(for project: ProjectState) -> DiffTaskKey {
        DiffTaskKey(
            projectID: project.id,
            mode: project.inspectorComparisonMode,
            contentRevision: project.gitInfo.contentRevision,
            fileSignature: visibleDiffFiles(for: project)
                .map { "\($0.path)|\($0.status)|\($0.additions)|\($0.deletions)" }
                .joined(separator: "||")
        )
    }

    private func splitRowsTaskKey(for project: ProjectState) -> SplitRowsTaskKey {
        SplitRowsTaskKey(
            displayedDiffKey: displayedDiffKey,
            displayMode: project.inspectorDiffDisplayMode
        )
    }

    private func visibleDiffFiles(for project: ProjectState) -> [GitStatusService.FileStatus] {
        switch project.inspectorComparisonMode {
        case .unstaged:
            project.gitInfo.files.filter(\.hasUnstagedChanges)
        case .staged:
            project.gitInfo.files.filter(\.hasStagedChanges)
        case .base:
            project.gitInfo.files
        }
    }

    private func selectedCanvasSections(
        from sections: [DiffSection],
        selectedPath _: String?
    ) -> [DiffSection] {
        let fileSections = sections.filter { $0.path != nil }
        return fileSections.isEmpty ? sections : fileSections
    }

    private func ensureSelectedDiffPath(for project: ProjectState, sections: [DiffSection]) {
        let availablePaths = sections.compactMap(\.path)
        guard !availablePaths.isEmpty else { return }
        if let selectedPath = project.selectedInspectorPath,
           availablePaths.contains(selectedPath) {
            return
        }
        project.selectedInspectorPath = availablePaths[0]
    }

    private func loadProjectDiff(for project: ProjectState) async {
        let snapshot = diffTaskKey(for: project)
        let visibleFiles = visibleDiffFiles(for: project)
        activeLoadKey = snapshot
        loadFailureKey = nil

        guard project.gitInfo.isGitRepo, !visibleFiles.isEmpty else {
            diffSections = []
            splitRowsBySectionID = [:]
            displayedDiffKey = nil
            isLoadingDiff = false
            loadFailureKey = nil
            return
        }

        if let cachedSections = DiffSectionCache.sections(for: snapshot) {
            diffSections = cachedSections
            splitRowsBySectionID = [:]
            displayedDiffKey = snapshot
            isLoadingDiff = false
            loadFailureKey = nil
            ensureSelectedDiffPath(for: project, sections: cachedSections)
            return
        }

        isLoadingDiff = true
        let diff = await appState.gitStatusService.projectDiff(
            projectID: project.id,
            mode: project.inspectorComparisonMode,
            files: visibleFiles
        )

        guard !Task.isCancelled,
              activeLoadKey == snapshot,
              diffTaskKey(for: project) == snapshot else { return }
        let sections: [DiffSection]
        do {
            sections = try await Self.parseExecutor.run(priority: .userInitiated) {
                DiffView.sections(from: diff)
            }
        } catch is CancellationError {
            return
        } catch {
            guard activeLoadKey == snapshot,
                  diffTaskKey(for: project) == snapshot else { return }
            isLoadingDiff = false
            loadFailureKey = snapshot
            return
        }
        guard !Task.isCancelled,
              activeLoadKey == snapshot,
              diffTaskKey(for: project) == snapshot else { return }
        DiffSectionCache.store(sections, for: snapshot)
        diffSections = sections
        splitRowsBySectionID = [:]
        displayedDiffKey = snapshot
        isLoadingDiff = false
        loadFailureKey = nil
        ensureSelectedDiffPath(for: project, sections: sections)
    }

    private func precomputeSplitRowsIfNeeded(for project: ProjectState) async {
        guard project.inspectorDiffDisplayMode == .split else {
            if !splitRowsBySectionID.isEmpty {
                splitRowsBySectionID = [:]
            }
            return
        }

        let snapshot = displayedDiffKey
        let sections = selectedCanvasSections(
            from: diffSections,
            selectedPath: project.selectedInspectorPath
        )
        guard snapshot != nil, !sections.isEmpty else { return }

        let missingSections = sections.filter { splitRowsBySectionID[$0.id] == nil }
        guard !missingSections.isEmpty else { return }

        let computedRows: [String: SplitSectionRows]
        do {
            computedRows = try await Self.parseExecutor.run(priority: .userInitiated) {
                Self.splitRowsMap(from: missingSections)
            }
        } catch is CancellationError {
            return
        } catch {
            return
        }

        guard !Task.isCancelled,
              displayedDiffKey == snapshot,
              project.inspectorDiffDisplayMode == .split else {
            return
        }

        splitRowsBySectionID.merge(computedRows) { current, _ in current }
    }

    private func diffTitle(for fileCount: Int, mode: InspectorComparisonMode) -> String {
        switch mode {
        case .unstaged:
            return fileCount == 1 ? "1 unstaged file" : "\(fileCount) unstaged files"
        case .staged:
            return fileCount == 1 ? "1 staged file" : "\(fileCount) staged files"
        case .base:
            return fileCount == 1 ? "1 changed file" : "\(fileCount) changed files"
        }
    }

    private func emptyStateTitle(for mode: InspectorComparisonMode) -> String {
        switch mode {
        case .unstaged:
            "No unstaged changes"
        case .staged:
            "Nothing staged"
        case .base:
            "Working tree is clean"
        }
    }

    private func emptyStateBody(for mode: InspectorComparisonMode) -> String {
        switch mode {
        case .unstaged:
            "Edit tracked files or add new files to see the local diff here."
        case .staged:
            "Stage changes first to inspect the staged diff."
        case .base:
            "This project has no git differences against its current base."
        }
    }

    private func scrollToSelectedFile(_ path: String?, using proxy: ScrollViewProxy, sections: [DiffSection]) {
        guard let path,
              let section = sections.first(where: { $0.path == path }) else {
            return
        }

        Task { @MainActor in
            proxy.scrollTo(section.id, anchor: .top)
        }
    }

    private func lineNumberWidth(maxLine: Int) -> CGFloat {
        let digits = max(2, String(maxLine).count)
        return CGFloat(20 + digits * 8)
    }

    private func textColor(for kind: ParsedDiffLine.Kind) -> Color {
        switch kind {
        case .meta:
            FXColors.fgTertiary
        case .hunk:
            FXColors.info
        case .context:
            FXColors.fgSecondary
        case .addition:
            FXColors.diffAddedFg
        case .deletion:
            FXColors.diffRemovedFg
        }
    }

    private func backgroundColor(for kind: ParsedDiffLine.Kind) -> Color {
        switch kind {
        case .meta:
            FXColors.bgSurface.opacity(0.35)
        case .hunk:
            FXColors.info.opacity(0.08)
        case .context:
            .clear
        case .addition:
            FXColors.diffAddedBg
        case .deletion:
            FXColors.diffRemovedBg
        }
    }

    private func splitTextColor(for side: SplitDiffSideKind) -> Color {
        switch side {
        case .empty:
            FXColors.fgQuaternary.opacity(0.35)
        case .context:
            FXColors.fgSecondary
        case .addition:
            FXColors.diffAddedFg
        case .deletion:
            FXColors.diffRemovedFg
        }
    }

    private func splitBackgroundColor(for side: SplitDiffSideKind) -> Color {
        switch side {
        case .empty:
            FXColors.bgSurface.opacity(0.18)
        case .context:
            .clear
        case .addition:
            FXColors.diffAddedBg
        case .deletion:
            FXColors.diffRemovedBg
        }
    }

    private func lineNumberColor(for emphasis: LineNumberEmphasis) -> Color {
        switch emphasis {
        case .neutral:
            FXColors.fgQuaternary
        case .addition:
            FXColors.diffAddedFg
        case .deletion:
            FXColors.diffRemovedFg
        }
    }

    private func lineNumberEmphasis(for side: SplitDiffSideKind) -> LineNumberEmphasis {
        switch side {
        case .addition:
            .addition
        case .deletion:
            .deletion
        case .context, .empty:
            .neutral
        }
    }

    private func toggleSection(_ section: DiffSection) {
        if collapsedSectionIDs.contains(section.id) {
            collapsedSectionIDs.remove(section.id)
        } else {
            collapsedSectionIDs.insert(section.id)
        }
    }

    private func isCollapsed(_ section: DiffSection) -> Bool {
        collapsedSectionIDs.contains(section.id)
    }

    private func openFile(_ path: String, in project: ProjectState) {
        NSWorkspace.shared.open(project.project.rootURL.appendingPathComponent(path))
    }

}

private enum LineNumberEmphasis {
    case neutral
    case addition
    case deletion
}
