import SwiftUI
import AppKit
import FXDesign

private struct ParsedDiffLine: Identifiable {
    enum Kind {
        case meta
        case hunk
        case context
        case addition
        case deletion
    }

    let id = UUID()
    let kind: Kind
    let text: String
    let oldLine: Int?
    let newLine: Int?
    let anchorPath: String?
}

private enum SplitDiffSideKind {
    case empty
    case context
    case addition
    case deletion
}

private struct SplitDiffRow: Identifiable {
    enum Kind {
        case meta
        case hunk
        case content
    }

    let id = UUID()
    let kind: Kind
    let oldLine: Int?
    let newLine: Int?
    let oldText: String
    let newText: String
    let oldSide: SplitDiffSideKind
    let newSide: SplitDiffSideKind
    let anchorPath: String?
}

private struct DiffTaskKey: Equatable {
    let projectID: UUID
    let mode: InspectorComparisonMode
    let fileSignature: String
}

private struct DiffSection: Identifiable {
    let id: String
    let path: String?
    let title: String
    let subtitle: String?
    let additions: Int
    let deletions: Int
    let parsedLines: [ParsedDiffLine]
    let splitRows: [SplitDiffRow]
}

struct DiffView: View {
    @Environment(AppState.self) private var appState

    @State private var projectDiffText = ""
    @State private var diffSections: [DiffSection] = []
    @State private var isLoadingDiff = false
    @State private var activeLoadKey: DiffTaskKey?
    @State private var collapsedSectionIDs: Set<String> = []
    @State private var showsChangedFiles = true

    private let changedFilesSidebarWidth: CGFloat = 220

    var body: some View {
        if let project = appState.activeProject {
            VStack(spacing: 0) {
                header(project)
                FXDivider()
                content(project)
            }
            .background(FXColors.bg)
            .task(id: diffTaskKey(for: project)) {
                await loadProjectDiff(for: project)
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
        let fileSectionCount = diffSections.filter { $0.path != nil }.count
        let canToggleChangedFiles = fileSectionCount > 1

        return HStack(spacing: FXSpacing.md) {
            Image(systemName: "arrow.left.arrow.right.square")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(FXColors.fgTertiary)

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

            if canToggleChangedFiles {
                changedFilesToggle
            }

            comparisonModePicker(project)
            diffDisplayModePicker(project)
        }
        .padding(.horizontal, FXSpacing.md)
        .padding(.vertical, FXSpacing.sm)
        .background(FXColors.bgElevated)
    }

    @ViewBuilder
    private func content(_ project: ProjectState) -> some View {
        let visibleFiles = visibleDiffFiles(for: project)

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
        } else if isLoadingDiff && diffSections.isEmpty {
            loadingView
        } else if diffSections.isEmpty {
            messageView(
                title: "Diff unavailable",
                body: "FlowX could not build a git diff for the current project state."
            )
        } else {
            diffWorkspace(project: project, sections: diffSections, scrollTargetPath: project.selectedInspectorPath)
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
        .background(FXColors.bg)
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
            }
        }
    }

    private func diffDisplayModePicker(_ project: ProjectState) -> some View {
        Menu {
            ForEach(InspectorDiffDisplayMode.allCases, id: \.self) { mode in
                Button(action: {
                    withAnimation(FXAnimation.quick) {
                        project.inspectorDiffDisplayMode = mode
                    }
                }) {
                    if project.inspectorDiffDisplayMode == mode {
                        Label(mode.rawValue, systemImage: "checkmark")
                    } else {
                        Text(mode.rawValue)
                    }
                }
            }
        } label: {
            HStack(spacing: FXSpacing.xs) {
                Text(project.inspectorDiffDisplayMode.rawValue)
                    .font(FXTypography.captionMedium)
                    .foregroundStyle(FXColors.fg)

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(FXColors.fgTertiary)
            }
            .padding(.horizontal, FXSpacing.sm)
            .padding(.vertical, FXSpacing.xxxs)
            .background(FXColors.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: FXRadii.xs))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func diffWorkspace(project: ProjectState, sections: [DiffSection], scrollTargetPath: String?) -> some View {
        let fileSections = sections.filter { $0.path != nil }
        let showsFilesRail = fileSections.count > 1 && showsChangedFiles

        return HStack(spacing: 0) {
            diffCanvas(project: project, sections: sections, scrollTargetPath: scrollTargetPath)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                .clipped()

            if fileSections.count > 1 {
                changedFilesRail(project: project, sections: fileSections, isVisible: showsFilesRail)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder
    private func diffCanvas(project: ProjectState, sections: [DiffSection], scrollTargetPath: String?) -> some View {
        if project.inspectorDiffDisplayMode == .split {
            splitDiffView(project: project, sections: sections, scrollTargetPath: scrollTargetPath)
        } else {
            diffView(project: project, sections: sections, scrollTargetPath: scrollTargetPath)
        }
    }

    private func changedFilesRail(project: ProjectState, sections: [DiffSection], isVisible: Bool) -> some View {
        let dividerWidth: CGFloat = isVisible ? 1 : 0
        let railWidth: CGFloat = isVisible ? changedFilesSidebarWidth : 0

        return HStack(spacing: 0) {
            Rectangle()
                .fill(FXColors.borderSubtle)
                .frame(width: dividerWidth)

            changedFilesSidebar(project: project, sections: sections)
                .frame(width: railWidth, alignment: .leading)
                .clipped()
                .opacity(isVisible ? 1 : 0)
        }
        .frame(width: railWidth + dividerWidth, alignment: .trailing)
        .clipped()
    }

    private var changedFilesToggle: some View {
        Button(action: {
            withAnimation(FXAnimation.quick) {
                showsChangedFiles.toggle()
            }
        }) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(showsChangedFiles ? FXColors.fg : FXColors.fgTertiary)
                .frame(width: 28, height: 28)
                .background(showsChangedFiles ? FXColors.bgSelected : FXColors.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: FXRadii.sm))
        }
        .buttonStyle(.plain)
        .help(showsChangedFiles ? "Hide changed files" : "Show changed files")
    }

    private func diffView(project: ProjectState, sections: [DiffSection], scrollTargetPath: String?) -> some View {
        let allLines = sections.flatMap(\.parsedLines)
        let maxLine = max(allLines.compactMap(\.oldLine).max() ?? 0, allLines.compactMap(\.newLine).max() ?? 0)
        let numberWidth = lineNumberWidth(maxLine: maxLine)

        return ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(spacing: FXSpacing.lg) {
                    ForEach(sections) { section in
                        inlineSectionCard(
                            section,
                            selectedPath: scrollTargetPath,
                            project: project,
                            numberWidth: numberWidth
                        )
                    }
                }
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

    private func splitDiffView(project: ProjectState, sections: [DiffSection], scrollTargetPath: String?) -> some View {
        let allRows = sections.flatMap(\.splitRows)
        let maxOldLine = allRows.compactMap(\.oldLine).max() ?? 0
        let maxNewLine = allRows.compactMap(\.newLine).max() ?? 0
        let numberWidth = max(lineNumberWidth(maxLine: maxOldLine), lineNumberWidth(maxLine: maxNewLine))

        return ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(spacing: FXSpacing.lg) {
                    ForEach(sections) { section in
                        splitSectionCard(
                            section,
                            selectedPath: scrollTargetPath,
                            project: project,
                            numberWidth: numberWidth
                        )
                    }
                }
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

    private func inlineSectionCard(
        _ section: DiffSection,
        selectedPath: String?,
        project: ProjectState,
        numberWidth: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            sectionHeader(section, selectedPath: selectedPath, project: project)
                .id(section.id)

            if !isCollapsed(section) {
                ForEach(section.parsedLines) { line in
                    inlineDiffLine(line, numberWidth: numberWidth)
                }
            }
        }
        .background(FXColors.bgSurface.opacity(0.24))
        .clipShape(RoundedRectangle(cornerRadius: FXRadii.lg))
        .overlay(
            RoundedRectangle(cornerRadius: FXRadii.lg)
                .strokeBorder(FXColors.borderSubtle, lineWidth: 0.5)
        )
    }

    private func inlineDiffLine(_ line: ParsedDiffLine, numberWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            lineNumberCell(line.oldLine, width: numberWidth, emphasis: line.kind == .deletion ? .deletion : .neutral)
            lineNumberCell(line.newLine, width: numberWidth, emphasis: line.kind == .addition ? .addition : .neutral)

            Text(verbatim: line.text.isEmpty ? " " : line.text)
                .font(FXTypography.mono)
                .foregroundStyle(textColor(for: line.kind))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, FXSpacing.md)
                .padding(.vertical, 1)
        }
        .background(backgroundColor(for: line.kind))
    }

    private func splitSectionCard(
        _ section: DiffSection,
        selectedPath: String?,
        project: ProjectState,
        numberWidth: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            sectionHeader(section, selectedPath: selectedPath, project: project)
                .id(section.id)

            if !isCollapsed(section) {
                ForEach(section.splitRows) { row in
                    splitRowView(row, numberWidth: numberWidth)
                }
            }
        }
        .background(FXColors.bgSurface.opacity(0.24))
        .clipShape(RoundedRectangle(cornerRadius: FXRadii.lg))
        .overlay(
            RoundedRectangle(cornerRadius: FXRadii.lg)
                .strokeBorder(FXColors.borderSubtle, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func splitRowView(_ row: SplitDiffRow, numberWidth: CGFloat) -> some View {
        switch row.kind {
        case .meta:
            splitAnnotationRow(
                text: row.oldText,
                foreground: FXColors.fgTertiary,
                background: FXColors.bgSurface.opacity(0.35)
            )
        case .hunk:
            splitAnnotationRow(
                text: row.oldText,
                foreground: FXColors.info,
                background: FXColors.info.opacity(0.08)
            )
        case .content:
            HStack(spacing: 0) {
                splitDiffCell(
                    line: row.oldLine,
                    text: row.oldText,
                    width: numberWidth,
                    side: row.oldSide
                )

                FXDivider(.vertical)

                splitDiffCell(
                    line: row.newLine,
                    text: row.newText,
                    width: numberWidth,
                    side: row.newSide
                )
            }
        }
    }

    private func sectionHeader(_ section: DiffSection, selectedPath: String?, project: ProjectState) -> some View {
        let isSelected = selectedPath == section.path
        let isCollapsed = isCollapsed(section)

        return HStack(spacing: FXSpacing.md) {
            Button(action: {
                withAnimation(FXAnimation.quick) {
                    toggleSection(section)
                }
            }) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FXColors.fgQuaternary)
                    .frame(width: 10)
            }
            .buttonStyle(.plain)

            Image(systemName: "doc.text")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? FXColors.accent : FXColors.fgTertiary)

            Button(action: {
                if let path = section.path {
                    project.selectedInspectorPath = path
                }
            }) {
                sectionLabelStack(
                    title: section.title,
                    subtitle: section.subtitle,
                    isSelected: isSelected
                )
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            if section.additions > 0 {
                Text("+\(section.additions)")
                    .font(FXTypography.monoSmall)
                    .foregroundStyle(FXColors.success)
            }

            if section.deletions > 0 {
                Text("-\(section.deletions)")
                    .font(FXTypography.monoSmall)
                    .foregroundStyle(FXColors.error)
            }

            if let path = section.path {
                Button(action: {
                    openFile(path, in: project)
                }) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(FXColors.fgTertiary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Open in editor")
            }
        }
        .padding(.horizontal, FXSpacing.md)
        .padding(.vertical, FXSpacing.sm)
        .frame(minHeight: 44)
        .background(isSelected ? FXColors.bgSelected : FXColors.bgElevated)
        .overlay(alignment: .bottom) {
            FXDivider()
        }
    }

    private func changedFilesSidebar(project: ProjectState, sections: [DiffSection]) -> some View {
        return VStack(spacing: 0) {
            HStack {
                Text("Changed Files")
                    .font(FXTypography.captionMedium)
                    .foregroundStyle(FXColors.fgSecondary)

                Spacer()

                Text("\(sections.count)")
                    .font(FXTypography.monoSmall)
                    .foregroundStyle(FXColors.fgTertiary)
            }
            .padding(.horizontal, FXSpacing.md)
            .padding(.vertical, FXSpacing.sm)
            .background(FXColors.bgElevated)

            FXDivider()

            ScrollView {
                LazyVStack(spacing: FXSpacing.xxs) {
                    ForEach(sections) { section in
                        changedFileRow(section, project: project)
                    }
                }
                .padding(.horizontal, FXSpacing.sm)
                .padding(.vertical, FXSpacing.sm)
            }
            .background(FXColors.bg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func changedFileRow(_ section: DiffSection, project: ProjectState) -> some View {
        let isSelected = project.selectedInspectorPath == section.path

        return Button(action: {
            if let path = section.path {
                project.selectedInspectorPath = path
            }
        }) {
            HStack(spacing: FXSpacing.sm) {
                Image(systemName: isCollapsed(section) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(FXColors.fgQuaternary)
                    .frame(width: 10)

                sectionLabelStack(
                    title: section.title,
                    subtitle: section.subtitle,
                    isSelected: isSelected
                )

                Spacer(minLength: 0)

                HStack(spacing: FXSpacing.xs) {
                    if section.additions > 0 {
                        Text("+\(section.additions)")
                            .font(FXTypography.monoSmall)
                            .foregroundStyle(FXColors.success)
                    }

                    if section.deletions > 0 {
                        Text("-\(section.deletions)")
                            .font(FXTypography.monoSmall)
                            .foregroundStyle(FXColors.error)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, FXSpacing.md)
            .padding(.vertical, FXSpacing.sm)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: FXRadii.md)
                    .fill(isSelected ? FXColors.bgSelected : .clear)
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button(isCollapsed(section) ? "Expand" : "Collapse") {
                toggleSection(section)
            }
            if let path = section.path {
                Button("Open in Editor") {
                    openFile(path, in: project)
                }
            }
        }
    }

    private func sectionLabelStack(title: String, subtitle: String?, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: subtitle == nil ? 0 : FXSpacing.xxxs) {
            Text(title)
                .font(FXTypography.captionMedium)
                .foregroundStyle(isSelected ? FXColors.fg : FXColors.fgSecondary)
                .lineLimit(1)

            if let subtitle {
                Text(subtitle)
                    .font(FXTypography.caption)
                    .foregroundStyle(FXColors.fgTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: subtitle == nil ? .leading : .topLeading)
    }

    private func messageView(title: String, body: String) -> some View {
        VStack(spacing: FXSpacing.md) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 22, weight: .regular))
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
        .background(FXColors.bg)
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

    private func splitAnnotationRow(text: String, foreground: Color, background: Color) -> some View {
        Text(verbatim: text.isEmpty ? " " : text)
            .font(FXTypography.mono)
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, FXSpacing.md)
            .padding(.vertical, 1)
            .background(background)
    }

    private func splitDiffCell(
        line: Int?,
        text: String,
        width: CGFloat,
        side: SplitDiffSideKind
    ) -> some View {
        HStack(spacing: 0) {
            lineNumberCell(line, width: width, emphasis: lineNumberEmphasis(for: side))

            Text(verbatim: text.isEmpty ? " " : text)
                .font(FXTypography.mono)
                .foregroundStyle(splitTextColor(for: side))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, FXSpacing.md)
                .padding(.vertical, 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(splitBackgroundColor(for: side))
    }

    private func parseDiff(_ text: String) -> [ParsedDiffLine] {
        var lines: [ParsedDiffLine] = []
        var oldLine: Int?
        var newLine: Int?

        for rawLine in text.components(separatedBy: .newlines) {
            if rawLine.hasPrefix("@@") {
                let hunkLines = hunkLineNumbers(from: rawLine)
                oldLine = hunkLines?.0
                newLine = hunkLines?.1
                lines.append(ParsedDiffLine(kind: .hunk, text: rawLine, oldLine: nil, newLine: nil, anchorPath: nil))
                continue
            }

            if rawLine.hasPrefix("diff --git")
                || rawLine.hasPrefix("index ")
                || rawLine.hasPrefix("--- ")
                || rawLine.hasPrefix("+++ ")
                || rawLine.hasPrefix("\\ No newline") {
                lines.append(
                    ParsedDiffLine(
                        kind: .meta,
                        text: rawLine,
                        oldLine: nil,
                        newLine: nil,
                        anchorPath: diffAnchorPath(from: rawLine)
                    )
                )
                continue
            }

            if rawLine.hasPrefix("+"), !rawLine.hasPrefix("+++") {
                lines.append(ParsedDiffLine(kind: .addition, text: rawLine, oldLine: nil, newLine: newLine, anchorPath: nil))
                newLine = newLine.map { $0 + 1 }
                continue
            }

            if rawLine.hasPrefix("-"), !rawLine.hasPrefix("---") {
                lines.append(ParsedDiffLine(kind: .deletion, text: rawLine, oldLine: oldLine, newLine: nil, anchorPath: nil))
                oldLine = oldLine.map { $0 + 1 }
                continue
            }

            lines.append(ParsedDiffLine(kind: .context, text: rawLine, oldLine: oldLine, newLine: newLine, anchorPath: nil))
            oldLine = oldLine.map { $0 + 1 }
            newLine = newLine.map { $0 + 1 }
        }

        return lines.isEmpty
            ? [ParsedDiffLine(kind: .meta, text: "No diff available.", oldLine: nil, newLine: nil, anchorPath: nil)]
            : lines
    }

    private func splitRows(from parsedLines: [ParsedDiffLine]) -> [SplitDiffRow] {
        var rows: [SplitDiffRow] = []
        var index = 0

        while index < parsedLines.count {
            let line = parsedLines[index]

            switch line.kind {
            case .meta:
                rows.append(
                    SplitDiffRow(
                        kind: .meta,
                        oldLine: nil,
                        newLine: nil,
                        oldText: line.text,
                        newText: "",
                        oldSide: .context,
                        newSide: .empty,
                        anchorPath: line.anchorPath
                    )
                )
                index += 1

            case .hunk:
                rows.append(
                    SplitDiffRow(
                        kind: .hunk,
                        oldLine: nil,
                        newLine: nil,
                        oldText: line.text,
                        newText: "",
                        oldSide: .context,
                        newSide: .empty,
                        anchorPath: nil
                    )
                )
                index += 1

            case .context:
                let content = splitDisplayText(for: line)
                rows.append(
                    SplitDiffRow(
                        kind: .content,
                        oldLine: line.oldLine,
                        newLine: line.newLine,
                        oldText: content,
                        newText: content,
                        oldSide: .context,
                        newSide: .context,
                        anchorPath: nil
                    )
                )
                index += 1

            case .deletion:
                var deletions: [ParsedDiffLine] = []
                while index < parsedLines.count, parsedLines[index].kind == .deletion {
                    deletions.append(parsedLines[index])
                    index += 1
                }

                var additions: [ParsedDiffLine] = []
                let additionStart = index
                while index < parsedLines.count, parsedLines[index].kind == .addition {
                    additions.append(parsedLines[index])
                    index += 1
                }

                if additions.isEmpty {
                    index = additionStart
                }

                let pairCount = max(deletions.count, additions.count)
                for offset in 0..<pairCount {
                    let deletion = offset < deletions.count ? deletions[offset] : nil
                    let addition = offset < additions.count ? additions[offset] : nil
                    rows.append(
                        SplitDiffRow(
                            kind: .content,
                            oldLine: deletion?.oldLine,
                            newLine: addition?.newLine,
                            oldText: deletion.map(splitDisplayText(for:)) ?? "",
                            newText: addition.map(splitDisplayText(for:)) ?? "",
                            oldSide: deletion == nil ? .empty : .deletion,
                            newSide: addition == nil ? .empty : .addition,
                            anchorPath: nil
                        )
                    )
                }

            case .addition:
                rows.append(
                    SplitDiffRow(
                        kind: .content,
                        oldLine: nil,
                        newLine: line.newLine,
                        oldText: "",
                        newText: splitDisplayText(for: line),
                        oldSide: .empty,
                        newSide: .addition,
                        anchorPath: nil
                    )
                )
                index += 1
            }
        }

        return rows.isEmpty
            ? [
                SplitDiffRow(
                    kind: .meta,
                    oldLine: nil,
                    newLine: nil,
                    oldText: "No diff available.",
                    newText: "",
                    oldSide: .context,
                    newSide: .empty,
                    anchorPath: nil
                )
            ]
            : rows
    }

    private func sections(from text: String) -> [DiffSection] {
        let parsedLines = parseDiff(text)
        guard !parsedLines.isEmpty else { return [] }

        var sections: [DiffSection] = []
        var currentPath: String?
        var currentLines: [ParsedDiffLine] = []
        var index = 0

        func flushSection() {
            guard !currentLines.isEmpty else { return }
            sections.append(
                makeSection(
                    id: currentPath ?? "diff-section-\(index)",
                    path: currentPath,
                    lines: currentLines
                )
            )
            currentLines.removeAll(keepingCapacity: true)
            index += 1
        }

        for line in parsedLines {
            if let anchorPath = line.anchorPath {
                flushSection()
                currentPath = anchorPath
            }
            currentLines.append(line)
        }

        flushSection()
        return sections
    }

    private func makeSection(id: String, path: String?, lines: [ParsedDiffLine]) -> DiffSection {
        let additions = lines.filter { $0.kind == .addition }.count
        let deletions = lines.filter { $0.kind == .deletion }.count
        let title = path.map { ($0 as NSString).lastPathComponent } ?? "Project diff"
        let subtitle: String?
        if let path {
            let parent = (path as NSString).deletingLastPathComponent
            subtitle = parent == "." ? nil : parent
        } else {
            subtitle = nil
        }

        return DiffSection(
            id: id,
            path: path,
            title: title,
            subtitle: subtitle,
            additions: additions,
            deletions: deletions,
            parsedLines: lines,
            splitRows: splitRows(from: lines)
        )
    }

    private func splitDisplayText(for line: ParsedDiffLine) -> String {
        switch line.kind {
        case .addition, .deletion, .context:
            String(line.text.dropFirst())
        case .meta, .hunk:
            line.text
        }
    }

    private func hunkLineNumbers(from line: String) -> (Int, Int)? {
        let components = line.split(separator: " ")
        guard components.count >= 3,
              let oldValue = hunkComponentStart(String(components[1])),
              let newValue = hunkComponentStart(String(components[2])) else {
            return nil
        }
        return (oldValue, newValue)
    }

    private func hunkComponentStart(_ component: String) -> Int? {
        let trimmed = component.trimmingCharacters(in: CharacterSet(charactersIn: "-+"))
        let start = trimmed.split(separator: ",").first.map(String.init) ?? trimmed
        return Int(start)
    }

    private func diffAnchorPath(from line: String) -> String? {
        guard line.hasPrefix("diff --git "),
              let range = line.range(of: " b/") else {
            return nil
        }
        let path = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private func diffTaskKey(for project: ProjectState) -> DiffTaskKey {
        DiffTaskKey(
            projectID: project.id,
            mode: project.inspectorComparisonMode,
            fileSignature: visibleDiffFiles(for: project)
                .map { "\($0.path)|\($0.status)|\($0.additions)|\($0.deletions)" }
                .joined(separator: "||")
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

    private func loadProjectDiff(for project: ProjectState) async {
        let snapshot = diffTaskKey(for: project)
        let visibleFiles = visibleDiffFiles(for: project)
        activeLoadKey = snapshot

        guard project.gitInfo.isGitRepo, !visibleFiles.isEmpty else {
            projectDiffText = ""
            diffSections = []
            isLoadingDiff = false
            return
        }

        isLoadingDiff = true
        let diff = await appState.gitStatusService.projectDiff(
            projectID: project.id,
            mode: project.inspectorComparisonMode,
            files: visibleFiles
        )

        guard activeLoadKey == snapshot, diffTaskKey(for: project) == snapshot else { return }
        projectDiffText = diff
        diffSections = sections(from: diff)
        isLoadingDiff = false
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
            FXColors.success
        case .deletion:
            FXColors.error
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
            FXColors.success.opacity(0.08)
        case .deletion:
            FXColors.error.opacity(0.08)
        }
    }

    private func splitTextColor(for side: SplitDiffSideKind) -> Color {
        switch side {
        case .empty:
            FXColors.fgQuaternary.opacity(0.35)
        case .context:
            FXColors.fgSecondary
        case .addition:
            FXColors.success
        case .deletion:
            FXColors.error
        }
    }

    private func splitBackgroundColor(for side: SplitDiffSideKind) -> Color {
        switch side {
        case .empty:
            FXColors.bgSurface.opacity(0.18)
        case .context:
            .clear
        case .addition:
            FXColors.success.opacity(0.08)
        case .deletion:
            FXColors.error.opacity(0.08)
        }
    }

    private func lineNumberColor(for emphasis: LineNumberEmphasis) -> Color {
        switch emphasis {
        case .neutral:
            FXColors.fgQuaternary
        case .addition:
            FXColors.success
        case .deletion:
            FXColors.error
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
        let url = project.project.rootURL.appendingPathComponent(path)
        NSWorkspace.shared.open(url)
    }
}

private enum LineNumberEmphasis {
    case neutral
    case addition
    case deletion
}
