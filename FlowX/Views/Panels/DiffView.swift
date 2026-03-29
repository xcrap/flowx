import SwiftUI
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
}

struct DiffView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let project = appState.activeProject {
            VStack(spacing: 0) {
                header(project)
                FXDivider()
                content(project)
            }
            .background(FXColors.bg)
        } else {
            messageView(
                title: "Nothing selected",
                body: "Choose a changed file or repository file to inspect it."
            )
        }
    }

    private func header(_ project: ProjectState) -> some View {
        HStack(spacing: FXSpacing.md) {
            Image(systemName: leadingIcon(for: project.selectedInspectorContentKind))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(FXColors.fgTertiary)

            VStack(alignment: .leading, spacing: FXSpacing.xxxs) {
                Text(displayTitle(for: project.selectedInspectorPath))
                    .font(FXTypography.captionMedium)
                    .foregroundStyle(FXColors.fgSecondary)
                    .lineLimit(1)

                if let subtitle = displaySubtitle(for: project.selectedInspectorPath) {
                    Text(subtitle)
                        .font(FXTypography.caption)
                        .foregroundStyle(FXColors.fgTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 0)

            if project.selectedInspectorContentKind == .diff {
                diffDisplayModePicker(project)
            }

            FXBadge(project.inspectorComparisonMode.rawValue, tone: .accent)
            FXBadge(kindTitle(for: project.selectedInspectorContentKind), tone: badgeTone(for: project.selectedInspectorContentKind))
        }
        .padding(.horizontal, FXSpacing.md)
        .padding(.vertical, FXSpacing.sm)
        .background(FXColors.bgElevated)
    }

    @ViewBuilder
    private func content(_ project: ProjectState) -> some View {
        switch project.selectedInspectorContentKind {
        case .diff:
            if project.inspectorDiffDisplayMode == .split {
                splitDiffView(text: project.selectedInspectorText)
            } else {
                diffView(text: project.selectedInspectorText)
            }
        case .file:
            fileView(text: project.selectedInspectorText)
        case .message:
            messageView(
                title: displayTitle(for: project.selectedInspectorPath),
                body: project.selectedInspectorText.isEmpty
                    ? "Choose a changed file or repository file to inspect it."
                    : project.selectedInspectorText
            )
        }
    }

    private func diffDisplayModePicker(_ project: ProjectState) -> some View {
        HStack(spacing: FXSpacing.xxs) {
            ForEach(InspectorDiffDisplayMode.allCases, id: \.self) { mode in
                Button(action: {
                    withAnimation(FXAnimation.quick) {
                        project.inspectorDiffDisplayMode = mode
                    }
                }) {
                    Text(mode.rawValue)
                        .font(FXTypography.captionMedium)
                        .foregroundStyle(project.inspectorDiffDisplayMode == mode ? FXColors.fg : FXColors.fgTertiary)
                        .padding(.horizontal, FXSpacing.sm)
                        .padding(.vertical, FXSpacing.xxxs)
                        .background(project.inspectorDiffDisplayMode == mode ? FXColors.bgSelected : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: FXRadii.xs))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func fileView(text: String) -> some View {
        let lines = text.components(separatedBy: .newlines)
        let visibleLines = lines.isEmpty ? [""] : lines
        let numberWidth = lineNumberWidth(maxLine: visibleLines.count)

        return ScrollView([.vertical, .horizontal]) {
            LazyVStack(spacing: 0) {
                ForEach(Array(visibleLines.enumerated()), id: \.offset) { index, line in
                    HStack(spacing: 0) {
                        lineNumberCell(index + 1, width: numberWidth, emphasis: .neutral)

                        Text(verbatim: line.isEmpty ? " " : line)
                            .font(FXTypography.mono)
                            .foregroundStyle(FXColors.fgSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, FXSpacing.md)
                            .padding(.vertical, 1)
                    }
                    .background(index.isMultiple(of: 2) ? FXColors.bg.opacity(0.001) : .clear)
                }
            }
            .padding(.vertical, FXSpacing.sm)
            .textSelection(.enabled)
        }
    }

    private func diffView(text: String) -> some View {
        let parsedLines = parseDiff(text)
        let maxLine = max(parsedLines.compactMap(\.oldLine).max() ?? 0, parsedLines.compactMap(\.newLine).max() ?? 0)
        let numberWidth = lineNumberWidth(maxLine: maxLine)

        return ScrollView([.vertical, .horizontal]) {
            LazyVStack(spacing: 0) {
                ForEach(parsedLines) { line in
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
            }
            .padding(.vertical, FXSpacing.sm)
            .textSelection(.enabled)
        }
    }

    private func splitDiffView(text: String) -> some View {
        let rows = splitRows(from: parseDiff(text))
        let maxOldLine = rows.compactMap(\.oldLine).max() ?? 0
        let maxNewLine = rows.compactMap(\.newLine).max() ?? 0
        let numberWidth = max(lineNumberWidth(maxLine: maxOldLine), lineNumberWidth(maxLine: maxNewLine))

        return ScrollView([.vertical, .horizontal]) {
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
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
            }
            .padding(.vertical, FXSpacing.sm)
            .textSelection(.enabled)
        }
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
                lines.append(ParsedDiffLine(kind: .hunk, text: rawLine, oldLine: nil, newLine: nil))
                continue
            }

            if rawLine.hasPrefix("diff --git")
                || rawLine.hasPrefix("index ")
                || rawLine.hasPrefix("--- ")
                || rawLine.hasPrefix("+++ ")
                || rawLine.hasPrefix("\\ No newline") {
                lines.append(ParsedDiffLine(kind: .meta, text: rawLine, oldLine: nil, newLine: nil))
                continue
            }

            if rawLine.hasPrefix("+"), !rawLine.hasPrefix("+++") {
                lines.append(ParsedDiffLine(kind: .addition, text: rawLine, oldLine: nil, newLine: newLine))
                newLine = newLine.map { $0 + 1 }
                continue
            }

            if rawLine.hasPrefix("-"), !rawLine.hasPrefix("---") {
                lines.append(ParsedDiffLine(kind: .deletion, text: rawLine, oldLine: oldLine, newLine: nil))
                oldLine = oldLine.map { $0 + 1 }
                continue
            }

            lines.append(ParsedDiffLine(kind: .context, text: rawLine, oldLine: oldLine, newLine: newLine))
            oldLine = oldLine.map { $0 + 1 }
            newLine = newLine.map { $0 + 1 }
        }

        return lines.isEmpty ? [ParsedDiffLine(kind: .meta, text: "No diff available.", oldLine: nil, newLine: nil)] : lines
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
                        newSide: .empty
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
                        newSide: .empty
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
                        newSide: .context
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
                            newSide: addition == nil ? .empty : .addition
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
                        newSide: .addition
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
                    newSide: .empty
                )
            ]
            : rows
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

    private func displayTitle(for path: String?) -> String {
        guard let path, !path.isEmpty else { return "Inspector" }
        return (path as NSString).lastPathComponent
    }

    private func displaySubtitle(for path: String?) -> String? {
        guard let path, !path.isEmpty else { return "Select a changed file or repository file to inspect it." }
        let parent = (path as NSString).deletingLastPathComponent
        return parent == "." ? path : parent
    }

    private func leadingIcon(for kind: InspectorContentKind) -> String {
        switch kind {
        case .diff:
            "arrow.left.arrow.right.square"
        case .file:
            "doc.text"
        case .message:
            "doc.text.magnifyingglass"
        }
    }

    private func kindTitle(for kind: InspectorContentKind) -> String {
        switch kind {
        case .diff:
            "Diff"
        case .file:
            "File"
        case .message:
            "Info"
        }
    }

    private func badgeTone(for kind: InspectorContentKind) -> FXBadgeTone {
        switch kind {
        case .diff:
            .info
        case .file:
            .neutral
        case .message:
            .warning
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
}

private enum LineNumberEmphasis {
    case neutral
    case addition
    case deletion
}
