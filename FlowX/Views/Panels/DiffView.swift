import SwiftUI
import UniformTypeIdentifiers
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
    let maximumTextColumns: Int
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

private struct DiffCanvasRevision: Hashable {
    let diff: DiffTaskKey?
    let mode: InspectorDiffDisplayMode
    let disclosure: DiffDisclosureState
    let selectedPath: String?
    let viewportWidth: CGFloat
}

private struct DiffFileJumpRequest: Hashable {
    let path: String?
    let sequence: Int
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
    @State private var disclosure = DiffDisclosureState()
    @State private var fileNavigatorVisible = true
    @State private var fileFilter = ""
    @State private var fileJumpSequence = 0
    @State private var splitRowsBySectionID: [String: SplitSectionRows] = [:]

    private let diffSectionAccessoryWidth: CGFloat = 28

    var body: some View {
        if let project = appState.activeProject {
            VStack(spacing: 0) {
                header(project)
                FXDivider()
                if project.commitComposerVisible {
                    GitCommitComposer(project: project)
                    FXDivider()
                }
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
        let fileCount = visibleDiffFiles(for: project).count
        return VStack(spacing: FXSpacing.sm) {
            HStack(spacing: FXSpacing.sm) {
                comparisonModePicker(project)
                Spacer(minLength: FXSpacing.xs)
                repositoryActions(project)
            }
            ViewThatFits(in: .horizontal) {
                diffToolbar(project, fileCount: fileCount, compact: false)
                diffToolbar(project, fileCount: fileCount, compact: true)
            }
        }
        .padding(.horizontal, FXSpacing.md)
        .padding(.vertical, FXSpacing.sm)
        .background(FXColors.bgElevated)
    }

    private func diffToolbar(_ project: ProjectState, fileCount: Int, compact: Bool) -> some View {
        HStack(spacing: FXSpacing.sm) {
            FXCompactActionButton("Files \(fileCount)", icon: "sidebar.left") {
                fileNavigatorVisible.toggle()
            }
            .accessibilityLabel(fileNavigatorVisible ? "Hide changed files" : "Show changed files")
            .accessibilityAddTraits(fileNavigatorVisible ? .isSelected : [])
            .disabled(fileCount == 0)

            Group {
                if compact {
                    FXIconButton(icon: "arrow.down.right.and.arrow.up.left", label: "Collapse all diffs") {
                        setAllSectionsCollapsed(true)
                    }
                    FXIconButton(icon: "arrow.up.left.and.arrow.down.right", label: "Expand all diffs") {
                        setAllSectionsCollapsed(false)
                    }
                } else {
                    FXCompactActionButton("Collapse all", icon: "arrow.down.right.and.arrow.up.left") {
                        setAllSectionsCollapsed(true)
                    }
                    FXCompactActionButton("Expand all", icon: "arrow.up.left.and.arrow.down.right") {
                        setAllSectionsCollapsed(false)
                    }
                }
            }
            .disabled(diffSections.isEmpty || fileCount == 0)
            Spacer(minLength: FXSpacing.xs)
            diffDisplayModePicker(project)
        }
    }

    @ViewBuilder
    private func repositoryActions(_ project: ProjectState) -> some View {
        if project.gitInfo.isGitRepo && (project.gitInfo.hasChanges || project.commitComposerVisible) {
            FXCompactActionButton(project.commitComposerVisible ? "Cancel commit" : "Commit",
                                  icon: project.commitComposerVisible ? "xmark" : "checkmark") {
                appState.toggleCommitComposer()
            }
            .disabled(project.isPerformingGitAction)
        }
        if project.gitInfo.canPush {
            FXCompactActionButton("Push", icon: "arrow.up") {
                Task { @MainActor in await appState.pushActiveProject() }
            }
            .disabled(project.isPerformingGitAction)
        }
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
        } else if !diffSections.isEmpty,
                  displayedDiffKey == snapshot || canPreserveDisplayedCanvas {
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
                .strokeBorder(FXColors.border, lineWidth: FXBorderWidth.hairline)
        )
        .padding(FXSpacing.md)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }

    private func comparisonModePicker(_ project: ProjectState) -> some View {
        FXSegmentedControl("Compare changes", options: InspectorComparisonMode.allCases.map {
            FXSegmentedOption($0, title: $0.rawValue)
        }, selection: Binding(
            get: { project.inspectorComparisonMode },
            set: { appState.setInspectorComparisonMode($0, for: project) }
        ))
        .disabled(!project.gitInfo.isGitRepo)
    }

    private func diffDisplayModePicker(_ project: ProjectState) -> some View {
        FXSegmentedControl("Diff layout", options: InspectorDiffDisplayMode.allCases.map {
            FXSegmentedOption($0, title: $0.rawValue)
        }, selection: Binding(
            get: { project.inspectorDiffDisplayMode },
            set: { project.inspectorDiffDisplayMode = $0 }
        ))
    }

    private func diffWorkspace(project: ProjectState, sections: [DiffSection], scrollTargetPath: String?) -> some View {
        let canvasSections = selectedCanvasSections(from: sections, selectedPath: scrollTargetPath)
        return GeometryReader { geometry in
            if fileNavigatorVisible, geometry.size.width >= FXLayout.diffNavigatorSideBySideWidth {
                HStack(spacing: 0) {
                    fileNavigator(project, sections: canvasSections)
                        .frame(width: FXLayout.diffNavigatorWidth)
                    FXDivider(.vertical)
                    diffCanvasContainer(project, sections: canvasSections,
                                        scrollTargetPath: scrollTargetPath,
                                        width: geometry.size.width - FXLayout.diffNavigatorWidth - 1)
                }
            } else {
                VStack(spacing: 0) {
                    if fileNavigatorVisible {
                        fileNavigator(project, sections: canvasSections)
                            .frame(height: min(FXLayout.diffNavigatorCompactHeight, geometry.size.height * 0.35))
                        FXDivider()
                    }
                    diffCanvasContainer(project, sections: canvasSections,
                                        scrollTargetPath: scrollTargetPath, width: geometry.size.width)
                }
            }
        }
        .background(FXColors.panelBg)
        .clipped()
    }

    private func diffCanvasContainer(_ project: ProjectState, sections: [DiffSection],
                                     scrollTargetPath: String?, width: CGFloat) -> some View {
        diffCanvas(project: project, sections: sections, scrollTargetPath: scrollTargetPath,
                   viewportWidth: max(0, width - FXSpacing.md * 2))
            .padding(.horizontal, FXSpacing.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .clipped()
    }

    private func fileNavigator(_ project: ProjectState, sections: [DiffSection]) -> some View {
        FXFileNavigator(items: sections.compactMap { section in
            section.path.map { FXFileNavigatorItem(path: $0, additions: section.additions, deletions: section.deletions) }
        }, selectedPath: project.selectedInspectorPath, query: $fileFilter) { path in
            disclosure.setCollapsed(false, for: path)
            project.selectedInspectorPath = path
            fileJumpSequence &+= 1
        }
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

    private func diffView(
        project: ProjectState,
        sections: [DiffSection],
        scrollTargetPath: String?,
        viewportWidth: CGFloat
    ) -> some View {
        virtualizedCanvas(project: project, sections: sections,
                          scrollTargetPath: scrollTargetPath, viewportWidth: viewportWidth,
                          split: false)
    }

    @ViewBuilder
    private func splitDiffView(
        project: ProjectState,
        sections: [DiffSection],
        scrollTargetPath: String?,
        viewportWidth: CGFloat
    ) -> some View {
        if sections.contains(where: { splitRowsBySectionID[$0.id] == nil }) {
            ProgressView("Preparing split diff…")
                .font(FXTypography.caption)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            virtualizedCanvas(project: project, sections: sections,
                              scrollTargetPath: scrollTargetPath, viewportWidth: viewportWidth,
                              split: true)
        }
    }

    private func virtualizedCanvas(
        project: ProjectState, sections: [DiffSection],
        scrollTargetPath: String?, viewportWidth: CGFloat, split: Bool
    ) -> some View {
        let preparedSplitRows = splitRowsBySectionID
        let collapsed = Set(sections.indices.filter { isCollapsed(sections[$0]) })
        let layout = DiffRowLayout(
            lineCounts: sections.map { split ? (preparedSplitRows[$0.id]?.rows.count ?? 0) : $0.parsedLines.count },
            collapsedSections: collapsed
        )
        let maximumLine = sections.reduce(0) { max($0, $1.maximumLineNumber) }
        let numberWidth = lineNumberWidth(maxLine: maximumLine)
        let maximumColumns = sections.reduce(0) { max($0, $1.maximumTextColumns) }
        let columnWidth = max(0, (viewportWidth - 1) / 2)
        let contentWidth = split ? max(viewportWidth, columnWidth * 2 + 1)
            : max(viewportWidth, CGFloat(maximumColumns) * FXTypography.terminalPointSize * 0.62
                    + (numberWidth + FXSpacing.sm * 2) * 2 + FXSpacing.md * 2)
        let targetSection = sections.firstIndex { $0.path == scrollTargetPath }
        let lineHeight = ceil(FXTypography.terminalPointSize * 1.4) + FXSpacing.xxxs

        return FXVirtualizedList(
            count: layout.count,
            revision: DiffCanvasRevision(diff: displayedDiffKey, mode: project.inspectorDiffDisplayMode,
                                         disclosure: disclosure, selectedPath: scrollTargetPath,
                                         viewportWidth: viewportWidth),
            contentWidth: contentWidth,
            scrollTarget: targetSection.flatMap { layout.headerRow(for: $0) },
            scrollRequest: DiffFileJumpRequest(path: scrollTargetPath, sequence: fileJumpSequence),
            rowHeight: { row in layout.location(at: row)?.line == nil ? 62 : lineHeight },
            copyText: { row in
                guard let location = layout.location(at: row) else { return nil }
                let section = sections[location.section]
                guard let line = location.line else { return sectionDisplayPath(section) }
                if split, let value = preparedSplitRows[section.id]?.rows[line] {
                    return value.oldText == value.newText ? value.newText : value.oldText + "\t" + value.newText
                }
                return section.parsedLines[line].text
            }
        ) { row in
            if let location = layout.location(at: row) {
                let section = sections[location.section]
                if let line = location.line {
                    Group {
                        if split, let value = preparedSplitRows[section.id]?.rows[line] {
                            splitRowView(value, numberWidth: numberWidth,
                                         viewportWidth: contentWidth, columnWidth: columnWidth)
                        } else {
                            inlineDiffLine(section.parsedLines[line], numberWidth: numberWidth,
                                           viewportWidth: contentWidth)
                        }
                    }
                    .frame(width: contentWidth, height: lineHeight, alignment: .leading)
                    .clipped()
                    .textSelection(.enabled)
                } else {
                    sectionHeader(section, selectedPath: scrollTargetPath, project: project)
                        .frame(width: viewportWidth, height: 46)
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: FXRadii.lg, topTrailingRadius: FXRadii.lg))
                        .padding(.top, FXSpacing.lg)
                        .frame(width: contentWidth, alignment: .leading)
                }
            }
        }
    }

    private func inlineDiffLine(
        _ line: ParsedDiffLine,
        numberWidth: CGFloat,
        viewportWidth: CGFloat
    ) -> some View {
        HStack(spacing: 0) {
            lineNumberCell(line.oldLine, width: numberWidth, emphasis: line.kind == .deletion ? .deletion : .neutral)
            lineNumberCell(line.newLine, width: numberWidth, emphasis: line.kind == .addition ? .addition : .neutral)

            Text(verbatim: Self.visibleLineText(line.text))
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
                background: FXColors.infoMuted,
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
                toggleSection(section)
            }) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(FXTypography.icon(.small))
                    .foregroundStyle(FXColors.fgTertiary)
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
        .fxContextMenu(sections: sectionMenuSections(section, isCollapsed: isCollapsed, project: project))
    }

    private func sectionMenuSections(
        _ section: DiffSection,
        isCollapsed: Bool,
        project: ProjectState
    ) -> [FXDropdownSection] {
        var items = [
            FXDropdownItem(
                id: "toggle-diff",
                title: isCollapsed ? "Expand Diff" : "Collapse Diff"
            ) {
                toggleSection(section)
            },
        ]
        if let path = section.path {
            items.append(
                FXDropdownItem(id: "open-in-editor", title: "Open in Editor") {
                    openFile(path, in: project)
                }
            )
        }
        return [FXDropdownSection(id: "diff-section", items: items)]
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
            Text(verbatim: Self.visibleLineText(text))
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

            Text(verbatim: Self.visibleLineText(text))
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

        // Lines still expected in the current hunk, from its `@@` counts.
        // Inside a hunk only the first character classifies a line, so
        // content such as `-- comment`, `---` or `++i` is never mistaken for
        // a file header.
        var remainingOld = 0
        var remainingNew = 0

        for (index, rawLine) in Self.diffLines(text).enumerated() {
            if index.isMultiple(of: 256), Task.isCancelled {
                return []
            }
            if rawLine.hasPrefix("@@") {
                let hunk = Self.hunkHeader(from: rawLine)
                oldLine = hunk?.oldStart
                newLine = hunk?.newStart
                // An unparseable header still classifies following lines by
                // prefix until the next header.
                remainingOld = hunk?.oldCount ?? .max
                remainingNew = hunk?.newCount ?? .max
                appendLine(kind: .hunk, text: rawLine, oldLine: nil, newLine: nil)
                continue
            }

            if remainingOld > 0 || remainingNew > 0 {
                switch rawLine.first {
                case "+":
                    appendLine(kind: .addition, text: rawLine, oldLine: nil, newLine: newLine)
                    newLine = newLine.map { $0 + 1 }
                    remainingNew -= 1
                    continue
                case "-":
                    appendLine(kind: .deletion, text: rawLine, oldLine: oldLine, newLine: nil)
                    oldLine = oldLine.map { $0 + 1 }
                    remainingOld -= 1
                    continue
                case " ", nil:
                    appendLine(kind: .context, text: rawLine, oldLine: oldLine, newLine: newLine)
                    oldLine = oldLine.map { $0 + 1 }
                    newLine = newLine.map { $0 + 1 }
                    remainingOld -= 1
                    remainingNew -= 1
                    continue
                case "\\":
                    continue
                default:
                    remainingOld = 0
                    remainingNew = 0
                }
            }

            if rawLine.isEmpty
                || rawLine.hasPrefix("diff --git")
                || rawLine.hasPrefix("index ")
                || rawLine.hasPrefix("--- ")
                || rawLine.hasPrefix("+++ ")
                || rawLine.hasPrefix("\\ No newline") {
                continue
            }

            appendLine(kind: .context, text: rawLine, oldLine: nil, newLine: nil)
        }

        return lines
    }

    /// Splits on LF and drops a trailing CR, so CRLF files do not gain a
    /// phantom blank line per row and Unicode line separators inside content
    /// do not split a diff line.
    nonisolated private static func diffLines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").map { line in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
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

        for (index, rawLine) in Self.diffLines(text).enumerated() {
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
        var maximumTextColumns = 0
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
            maximumTextColumns = max(maximumTextColumns, Self.displayColumnCount(
                Self.visibleLineText(line.text), maximumColumns: 16_400
            ))
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
            maximumTextColumns: maximumTextColumns,
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

    nonisolated private static func displayColumnCount(
        _ text: String, maximumColumns: Int = maximumSplitDiffTextColumns
    ) -> Int {
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
            if columns >= maximumColumns {
                return maximumColumns
            }
        }
        return columns
    }

    nonisolated private static func hunkHeader(
        from line: String
    ) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
        let components = line.split(separator: " ")
        guard components.count >= 3,
              let old = Self.hunkRange(components[1]),
              let new = Self.hunkRange(components[2]) else {
            return nil
        }
        return (old.start, old.count, new.start, new.count)
    }

    /// Parses `-a,b` / `+c,d`; a missing count means one line.
    nonisolated private static func hunkRange(_ component: Substring) -> (start: Int, count: Int)? {
        let trimmed = component.trimmingCharacters(in: CharacterSet(charactersIn: "-+"))
        let parts = trimmed.split(separator: ",", omittingEmptySubsequences: false)
        guard let start = parts.first.flatMap({ Int($0) }) else { return nil }
        let count = parts.count > 1 ? Int(parts[1]) : 1
        guard let count else { return nil }
        return (start, count)
    }

    nonisolated private static func diffAnchorPath(from line: String) -> String? {
        let prefix = "diff --git "
        guard line.hasPrefix(prefix) else { return nil }

        let header = line.dropFirst(prefix.count)
        // Git leaves paths with spaces unquoted (`a/My Notes.md b/My Notes.md`),
        // so whitespace tokenizing would yield `Notes.md`. When both sides name
        // the same path the header is exactly `a/P b/P`; split it by length.
        if header.hasPrefix("a/"), header.count > 5, (header.count - 5).isMultiple(of: 2) {
            let pathLength = (header.count - 5) / 2
            let oldPath = header.dropFirst(2).prefix(pathLength)
            let rest = header.dropFirst(2 + pathLength)
            if rest.hasPrefix(" b/"), rest.dropFirst(3) == oldPath {
                return String(oldPath)
            }
        }
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

    nonisolated private static func visibleLineText(_ text: String) -> String {
        guard !text.isEmpty else { return " " }
        let prefix = text.prefix(4_096)
        return prefix.endIndex == text.endIndex ? text : String(prefix) + " …"
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
            FXColors.infoMuted
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
            .clear
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
            FXColors.fgTertiary
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

    private func setAllSectionsCollapsed(_ collapsed: Bool) {
        disclosure.setAllCollapsed(collapsed)
        fileJumpSequence &+= 1
    }

    private func toggleSection(_ section: DiffSection) {
        disclosure.toggle(section.id)
    }

    private func isCollapsed(_ section: DiffSection) -> Bool {
        disclosure.isCollapsed(section.id)
    }

    private func openFile(_ path: String, in project: ProjectState) {
        // Diff paths are relative to the repository root, which is not the
        // project folder when the project was opened at a subfolder.
        guard let url = appState.gitStatusService.workingTreeURL(projectID: project.id, path: path) else { return }
        let workspace = NSWorkspace.shared
        // Agents write these files. A plain `open(url)` would launch an
        // `.app`, `.command` or `.terminal` file instead of showing it, so only
        // passive viewer types use the default handler; everything else goes
        // to the user's code/text editor, or is revealed in Finder.
        if let type = UTType(filenameExtension: url.pathExtension),
           [.image, .pdf, .audiovisualContent].contains(where: type.conforms(to:)) {
            workspace.open(url)
            return
        }
        guard let editor = workspace.urlForApplication(toOpen: .sourceCode)
            ?? workspace.urlForApplication(toOpen: .plainText) else {
            workspace.activateFileViewerSelecting([url])
            return
        }
        workspace.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }

}

private enum LineNumberEmphasis {
    case neutral
    case addition
    case deletion
}
