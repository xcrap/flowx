import AppKit
import SwiftUI
import FXCore
import FXDesign

struct ConversationActivitySummary: Sendable {
    let toolCallCount: Int
    let editCount: Int
    let failureCount: Int
    let durationSeconds: Int

    nonisolated init(messages: [ConversationMessage]) throws {
        var toolCallCount = 0
        var editCount = 0
        var failureCount = 0
        var firstTimestamp: Date?
        var lastTimestamp: Date?

        for (messageIndex, message) in messages.enumerated() {
            if messageIndex.isMultiple(of: 32) {
                try Task.checkCancellation()
            }
            firstTimestamp = min(firstTimestamp ?? message.timestamp, message.timestamp)
            lastTimestamp = max(lastTimestamp ?? message.timestamp, message.timestamp)
            for (contentIndex, content) in message.content.enumerated() {
                if contentIndex.isMultiple(of: 64) {
                    try Task.checkCancellation()
                }
                switch content {
                case .toolUse(_, let name, _):
                    guard name != "AskUserQuestion" else { continue }
                    toolCallCount += 1
                    if name.caseInsensitiveCompare("Edit") == .orderedSame
                        || name.caseInsensitiveCompare("Write") == .orderedSame {
                        editCount += 1
                    }
                case .toolResult(_, _, let isError):
                    if isError { failureCount += 1 }
                default:
                    continue
                }
            }
        }

        self.toolCallCount = toolCallCount
        self.editCount = editCount
        self.failureCount = failureCount
        if let firstTimestamp, let lastTimestamp {
            durationSeconds = max(0, Int(lastTimestamp.timeIntervalSince(firstTimestamp).rounded()))
        } else {
            durationSeconds = 0
        }
    }
}

/// A provider turn's intermediate commentary and tool lifecycle, folded into
/// one calm disclosure once the turn completes. This mirrors the progressive
/// disclosure used by modern agent clients while keeping every detail
/// available on demand.
struct ConversationActivityGroup: View {
    let entries: [ConversationActivityEntry]
    let isActive: Bool
    let summary: ConversationActivitySummary
    let completedToolUseIDs: Set<String>

    @State private var isExpanded: Bool

    init(
        entries: [ConversationActivityEntry],
        isActive: Bool,
        summary: ConversationActivitySummary,
        completedToolUseIDs: Set<String>
    ) {
        self.entries = entries
        self.isActive = isActive
        self.summary = summary
        self.completedToolUseIDs = completedToolUseIDs
        _isExpanded = State(initialValue: isActive)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FXSpacing.sm) {
            Button(action: toggleExpanded) {
                HStack(spacing: FXSpacing.sm) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(FXTypography.icon(.micro))
                        .foregroundStyle(FXColors.fgQuaternary)
                        .frame(width: 12)

                    if isActive {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "terminal")
                            .font(FXTypography.icon(.small))
                            .foregroundStyle(FXColors.fgTertiary)
                            .frame(width: 14)
                    }

                    Text(activityTitle)
                        .font(FXTypography.captionMedium)
                        .foregroundStyle(FXColors.fgSecondary)

                    if summary.toolCallCount > 0 {
                        Text("·")
                            .font(FXTypography.caption)
                            .foregroundStyle(FXColors.fgQuaternary)

                        Text(actionSummary)
                            .font(FXTypography.caption)
                            .foregroundStyle(FXColors.fgTertiary)
                    }

                    Spacer(minLength: 0)

                    if summary.failureCount > 0 {
                        HStack(spacing: FXSpacing.xxs) {
                            Image(systemName: "xmark.circle.fill")
                                .font(FXTypography.icon(.micro))
                            Text("\(summary.failureCount)")
                                .font(FXTypography.captionMedium)
                        }
                        .foregroundStyle(FXColors.error)
                        .help(
                            summary.failureCount == 1
                                ? "1 tool call failed"
                                : "\(summary.failureCount) tool calls failed"
                        )
                    }
                }
                .padding(.vertical, FXSpacing.xxs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityTitle)
            .accessibilityHint(isExpanded ? "Collapse work details" : "Expand work details")

            if isExpanded {
                ConversationActivityDetails(
                    entries: entries,
                    isActive: isActive,
                    completedToolUseIDs: completedToolUseIDs
                )
                    .padding(.leading, FXSpacing.xl)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(FXColors.borderSubtle)
                            .frame(width: 1)
                            .padding(.leading, FXSpacing.xs)
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: isActive) { _, active in
            isExpanded = active
        }
    }

    private var activityTitle: String {
        guard !isActive else { return "Working…" }
        guard let durationLabel else { return "Worked" }
        return "Worked for \(durationLabel)"
    }

    private var actionSummary: String {
        let actionLabel = summary.toolCallCount == 1 ? "1 action" : "\(summary.toolCallCount) actions"
        guard summary.editCount > 0 else { return actionLabel }
        let editLabel = summary.editCount == 1 ? "1 edit" : "\(summary.editCount) edits"
        return "\(actionLabel) · \(editLabel)"
    }

    private var durationLabel: String? {
        let seconds = summary.durationSeconds
        guard seconds > 0 else { return nil }
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 {
            let minutes = seconds / 60
            let remainder = seconds % 60
            return remainder == 0 ? "\(minutes)m" : "\(minutes)m \(remainder)s"
        }
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }

    private var accessibilityTitle: String {
        var parts = [activityTitle, actionSummary]
        if summary.failureCount > 0 {
            parts.append(
                summary.failureCount == 1
                    ? "1 failed action"
                    : "\(summary.failureCount) failed actions"
            )
        }
        return parts.joined(separator: ", ")
    }

    private func toggleExpanded() {
        isExpanded.toggle()
    }
}

struct ConversationQuestionExchange: View {
    let question: ConversationMessage
    let result: ConversationMessage?

    @State private var showsFullAnswer = false

    var body: some View {
        VStack(alignment: .leading, spacing: FXSpacing.sm) {
            MessageBubble(message: question)

            if let answer {
                VStack(alignment: .leading, spacing: FXSpacing.xs) {
                    HStack(spacing: FXSpacing.sm) {
                        Image(systemName: answer.outcome.icon)
                            .font(FXTypography.icon(.small))
                            .foregroundStyle(answer.outcome.tint)

                        Text(answer.outcome.label)
                            .font(FXTypography.captionMedium)
                            .foregroundStyle(answer.outcome == .failed ? FXColors.error : FXColors.fgSecondary)

                        Spacer(minLength: 0)
                    }

                    if !answer.summary.isEmpty {
                        Text(answer.summary)
                            .font(FXTypography.caption)
                            .foregroundStyle(FXColors.fgSecondary)
                            .lineLimit(answer.outcome == .clarification || showsFullAnswer ? nil : 4)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)

                        if answer.canShowDetails {
                            Button(showsFullAnswer ? answer.hideDetailsLabel : answer.showDetailsLabel) {
                                showsFullAnswer.toggle()
                            }
                            .buttonStyle(.plain)
                            .font(FXTypography.captionMedium)
                            .foregroundStyle(FXColors.accent)
                        }

                        if showsFullAnswer, answer.outcome == .clarification {
                            Text(answer.rawText)
                                .font(FXTypography.caption)
                                .foregroundStyle(FXColors.fgTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.leading, FXSpacing.xl)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var answer: QuestionAnswer? {
        guard let result else { return nil }
        for content in result.content {
            guard case .toolResult(_, let output, let isError) = content else { continue }
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let bounded = String(trimmed.prefix(8_192))
            let outcome = QuestionAnswerOutcome(rawText: bounded, isError: isError)
            return QuestionAnswer(
                rawText: bounded,
                outcome: outcome,
                canExpand: bounded.count > 320 || bounded.components(separatedBy: .newlines).count > 4
            )
        }
        return nil
    }
}

private struct QuestionAnswer {
    let rawText: String
    let outcome: QuestionAnswerOutcome
    let canExpand: Bool

    var summary: String {
        switch outcome {
        case .clarification:
            "You chose to add context before answering."
        case .answered, .failed:
            rawText
        }
    }

    var canShowDetails: Bool {
        outcome == .clarification ? !rawText.isEmpty : canExpand
    }

    var showDetailsLabel: String {
        outcome == .clarification ? "Show provider details" : "Show full answer"
    }

    var hideDetailsLabel: String {
        outcome == .clarification ? "Hide provider details" : "Show less"
    }
}

private enum QuestionAnswerOutcome: Equatable {
    case answered
    case clarification
    case failed

    init(rawText: String, isError: Bool) {
        let normalized = rawText.lowercased()
        if isError,
           normalized.contains("user wants to clarify")
            || normalized.contains("additional information, context or questions") {
            self = .clarification
        } else {
            self = isError ? .failed : .answered
        }
    }

    var label: String {
        switch self {
        case .answered: "Answered"
        case .clarification: "Clarification requested"
        case .failed: "Question failed"
        }
    }

    var icon: String {
        switch self {
        case .answered: "checkmark.circle.fill"
        case .clarification: "questionmark.bubble.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .answered: FXColors.success
        case .clarification: FXColors.accentSecondary
        case .failed: FXColors.error
        }
    }
}

private struct ConversationActivityDetails: View {
    let entries: [ConversationActivityEntry]
    let isActive: Bool
    let completedToolUseIDs: Set<String>

    @State private var visibleEntryCount = 20

    var body: some View {
        LazyVStack(alignment: .leading, spacing: FXSpacing.sm) {
            if hiddenEntryCount > 0 {
                Button("Show \(min(20, hiddenEntryCount)) earlier actions") {
                    visibleEntryCount = min(entries.count, visibleEntryCount + 20)
                }
                .buttonStyle(.plain)
                .font(FXTypography.captionMedium)
                .foregroundStyle(FXColors.accent)
                .accessibilityHint("\(hiddenEntryCount) earlier actions remain hidden")
            }

            ForEach(visibleEntries) { entry in
                switch entry.payload {
                case .commentary(let commentary):
                    ActivityCommentaryRow(commentary: commentary)
                case .tool(let tool):
                    ActivityToolRow(
                        tool: tool,
                        isActiveTurn: isActive,
                        isComplete: tool.isComplete || completedToolUseIDs.contains(tool.id)
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hiddenEntryCount: Int {
        max(0, entries.count - visibleEntryCount)
    }

    private var visibleEntries: ArraySlice<ConversationActivityEntry> {
        entries.suffix(visibleEntryCount)
    }
}

struct ConversationActivityEntry: Identifiable, Sendable {
    enum Payload: Sendable {
        case commentary(ActivityCommentaryRecord)
        case tool(ActivityToolRecord)
    }

    let id: String
    var payload: Payload

    nonisolated static func makeEntries(
        from messages: [ConversationMessage]
    ) throws -> [ConversationActivityEntry] {
        var entries: [ConversationActivityEntry] = []
        var toolEntryIndexByID: [String: Int] = [:]

        for (messageIndex, message) in messages.enumerated() {
            if messageIndex.isMultiple(of: 32) {
                try Task.checkCancellation()
            }
            for (contentIndex, content) in message.content.enumerated() {
                if contentIndex.isMultiple(of: 64) {
                    try Task.checkCancellation()
                }
                let entryID = "\(message.id.uuidString)-\(messageIndex)-\(contentIndex)"
                switch content {
                case .toolUse(let id, let name, let input):
                    let record = ActivityToolRecord(
                        id: id.isEmpty ? entryID : id,
                        name: name,
                        input: input,
                        output: nil,
                        isError: false,
                        isComplete: false
                    )
                    toolEntryIndexByID[record.id] = entries.count
                    entries.append(ConversationActivityEntry(id: entryID, payload: .tool(record)))

                case .toolResult(let id, let output, let isError):
                    if let existingIndex = toolEntryIndexByID[id],
                       case .tool(var record) = entries[existingIndex].payload {
                        record.output = output
                        record.isError = isError
                        record.isComplete = true
                        entries[existingIndex].payload = .tool(record)
                    } else {
                        entries.append(
                            ConversationActivityEntry(
                                id: entryID,
                                payload: .tool(
                                    ActivityToolRecord(
                                        id: id.isEmpty ? entryID : id,
                                        name: "Tool",
                                        input: "",
                                        output: output,
                                        isError: isError,
                                        isComplete: true
                                    )
                                )
                            )
                        )
                    }

                default:
                    if let commentary = ActivityCommentaryRecord(content: content, id: entryID) {
                        entries.append(
                            ConversationActivityEntry(
                                id: entryID,
                                payload: .commentary(commentary)
                            )
                        )
                    }
                }
            }
        }

        return entries
    }
}

struct ActivityCommentaryRecord: Sendable {
    struct TextPayload: Sendable {
        let full: String
        let preview: String
        let characterCount: Int

        nonisolated init?(_ source: String, preservingWhitespace: Bool = false) {
            let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let full = preservingWhitespace ? source : trimmed

            let lines = full.components(separatedBy: .newlines)
            let lineBounded = lines.prefix(16).joined(separator: "\n")
            let characterBounded = String(lineBounded.prefix(2_000))
            let isTruncated = lines.count > 16 || characterBounded.count < full.count

            self.full = full
            preview = isTruncated ? characterBounded + "\n…" : full
            characterCount = full.count
        }
    }

    enum Payload: Sendable {
        case text(TextPayload)
        case code(language: String, payload: TextPayload)
        case image(data: Data, mimeType: String, cacheKey: String)
        case imageAsset(ConversationImageAssetReference, cacheKey: String)
    }

    let payload: Payload

    nonisolated init?(content: MessageContent, id: String) {
        switch content {
        case .text(let text):
            guard let payload = TextPayload(text) else { return nil }
            self.payload = .text(payload)
        case .code(let language, let code):
            guard let payload = TextPayload(code, preservingWhitespace: true) else { return nil }
            self.payload = .code(
                language: language.trimmingCharacters(in: .whitespacesAndNewlines),
                payload: payload
            )
        case .image(let data, let mimeType):
            payload = .image(data: data, mimeType: mimeType, cacheKey: "activity-\(id)")
        case .imageAsset(let reference):
            payload = .imageAsset(reference, cacheKey: "activity-asset-\(id)")
        case .toolUse, .toolResult:
            return nil
        }
    }
}

private struct ActivityCommentaryRow: View {
    let commentary: ActivityCommentaryRecord

    @State private var revealedCharacterLimit = 0

    var body: some View {
        HStack(alignment: .top, spacing: FXSpacing.sm) {
            Image(systemName: iconName)
                .font(FXTypography.icon(.micro))
                .foregroundStyle(FXColors.fgQuaternary)
                .frame(width: 14)

            commentaryBody
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var iconName: String {
        switch commentary.payload {
        case .text:
            "text.bubble"
        case .code:
            "chevron.left.forwardslash.chevron.right"
        case .image, .imageAsset:
            "photo"
        }
    }

    @ViewBuilder
    private var commentaryBody: some View {
        switch commentary.payload {
        case .text(let payload):
            pagedText(payload, isCode: false, language: "")
        case .code(let language, let payload):
            pagedText(payload, isCode: true, language: language)
        case .image(let data, let mimeType, let cacheKey):
            MessageImageView(data: data, mimeType: mimeType, cacheKey: cacheKey)
        case .imageAsset(let reference, let cacheKey):
            MessageAssetImageView(reference: reference, cacheKey: cacheKey)
        }
    }

    @ViewBuilder
    private func pagedText(
        _ payload: ActivityCommentaryRecord.TextPayload,
        isCode: Bool,
        language: String
    ) -> some View {
        let isInitiallyBounded = payload.preview != payload.full
        let displayedText = revealedCharacterLimit == 0
            ? payload.preview
            : String(payload.full.prefix(revealedCharacterLimit))
        let isFullyRevealed = revealedCharacterLimit >= payload.characterCount

        VStack(alignment: .leading, spacing: FXSpacing.xs) {
            if isCode, !language.isEmpty {
                Text(language.uppercased())
                    .font(FXTypography.overline)
                    .foregroundStyle(FXColors.fgTertiary)
            }

            Group {
                if isCode {
                    ScrollView(.horizontal) {
                        Text(displayedText)
                            .font(FXTypography.monoSmall)
                            .fixedSize(horizontal: true, vertical: true)
                    }
                    .padding(FXSpacing.sm)
                    .background(FXColors.bgSurface)
                    .clipShape(RoundedRectangle(cornerRadius: FXRadii.md))
                    .overlay(
                        RoundedRectangle(cornerRadius: FXRadii.md)
                            .strokeBorder(FXColors.borderSubtle, lineWidth: 0.5)
                    )
                } else {
                    Text(displayedText)
                        .font(FXTypography.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(FXColors.fgSecondary)
            .textSelection(.enabled)

            if isInitiallyBounded {
                Button(isFullyRevealed ? "Show less" : "Show more") {
                    if isFullyRevealed {
                        revealedCharacterLimit = 0
                    } else {
                        revealedCharacterLimit = min(
                            payload.characterCount,
                            max(8_000, revealedCharacterLimit + 8_000)
                        )
                    }
                }
                .buttonStyle(.plain)
                .font(FXTypography.captionMedium)
                .foregroundStyle(FXColors.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ActivityToolRecord: Sendable {
    let id: String
    let name: String
    let input: String
    let filePath: String?
    let pattern: String?
    let command: String?
    let writeCode: String?
    let editDiff: ActivityEditDiff?
    var output: String?
    var isError: Bool
    var isComplete: Bool

    nonisolated init(
        id: String,
        name: String,
        input: String,
        output: String?,
        isError: Bool,
        isComplete: Bool
    ) {
        self.id = id
        self.name = name
        self.input = input
        self.output = output
        self.isError = isError
        self.isComplete = isComplete

        let object: [String: Any]?
        if let data = input.data(using: .utf8) {
            object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } else {
            object = nil
        }
        filePath = object?["file_path"] as? String
        pattern = object?["pattern"] as? String
        command = object?["command"] as? String
        writeCode = name.caseInsensitiveCompare("Write") == .orderedSame
            ? object?["content"] as? String
            : nil
        editDiff = name.caseInsensitiveCompare("Edit") == .orderedSame
            ? ActivityEditDiff(input: input)
            : nil
    }

    var isEdit: Bool {
        name.caseInsensitiveCompare("Edit") == .orderedSame
    }

    var isWrite: Bool {
        name.caseInsensitiveCompare("Write") == .orderedSame
    }

    var isCodeChange: Bool {
        isEdit || isWrite
    }
}

private struct ActivityToolRow: View {
    let tool: ActivityToolRecord
    let isActiveTurn: Bool
    let isComplete: Bool

    @State private var isExpanded: Bool

    init(tool: ActivityToolRecord, isActiveTurn: Bool, isComplete: Bool) {
        self.tool = tool
        self.isActiveTurn = isActiveTurn
        self.isComplete = isComplete
        _isExpanded = State(initialValue: false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FXSpacing.xs) {
            Button(action: toggleExpanded) {
                HStack(spacing: FXSpacing.sm) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(FXTypography.icon(.micro))
                        .foregroundStyle(FXColors.fgQuaternary)
                        .frame(width: 12)

                    Image(systemName: toolIcon)
                        .font(FXTypography.icon(.small))
                        .foregroundStyle(tool.isError ? FXColors.error : FXColors.fgTertiary)
                        .frame(width: 14)

                    Text(toolTitle)
                        .font(FXTypography.captionMedium)
                        .foregroundStyle(FXColors.fgSecondary)

                    if let toolDetail {
                        Text("·")
                            .font(FXTypography.caption)
                            .foregroundStyle(FXColors.fgQuaternary)

                        Text(toolDetail)
                            .font(FXTypography.caption)
                            .foregroundStyle(FXColors.fgTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 0)
                    statusView
                }
                .padding(.vertical, FXSpacing.xxxs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(toolAccessibilityLabel)
            .accessibilityHint(isExpanded ? "Collapse tool details" : "Expand tool details")

            if isExpanded {
                toolDetails
                    .padding(.leading, FXSpacing.xl)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var statusView: some View {
        if tool.isError {
            Image(systemName: "xmark.circle.fill")
                .font(FXTypography.icon(.small))
                .foregroundStyle(FXColors.error)
                .help("Tool call failed")
        } else if !isComplete, isActiveTurn {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: "checkmark")
                .font(FXTypography.icon(.micro))
                .foregroundStyle(FXColors.success)
                .help("Tool call completed")
        }
    }

    @ViewBuilder
    private var toolDetails: some View {
        VStack(alignment: .leading, spacing: FXSpacing.sm) {
            if let diff = tool.editDiff, !diff.lines.isEmpty {
                ActivityEditDiffView(diff: diff)
            } else if let code = tool.writeCode {
                ActivityCodePreview(
                    label: fileName,
                    code: code
                )
            } else {
                if !tool.input.isEmpty, tool.input != "{}" {
                    ActivityCodePreview(label: "Input", code: boundedDetail(tool.input))
                }
            }

            if let output = meaningfulOutput,
               tool.isError || !hasSpecializedPreview {
                ActivityCodePreview(
                    label: tool.isError ? "Failure" : "Output",
                    code: boundedDetail(output),
                    tone: tool.isError ? .error : .standard
                )
            }
        }
    }

    private var hasSpecializedPreview: Bool {
        if let diff = tool.editDiff, !diff.lines.isEmpty {
            return true
        }
        return tool.writeCode != nil
    }

    private var fileName: String {
        guard let path = tool.filePath else { return "Code" }
        return shortPath(path)
    }

    private var toolTitle: String {
        switch tool.name.lowercased() {
        case "read":
            return "Read"
        case "edit":
            return "Edited"
        case "write":
            return "Wrote"
        case "grep":
            return "Searched"
        case "glob":
            return "Matched files"
        case "bash", "command", "shell", "commandexecution":
            return "Ran command"
        case "tool":
            return tool.isError ? "Tool failed" : "Tool result"
        default:
            return tool.name
        }
    }

    private var toolIcon: String {
        switch tool.name.lowercased() {
        case "read":
            return "doc.text"
        case "edit", "write":
            return "pencil.line"
        case "grep", "glob":
            return "magnifyingglass"
        case "bash", "command", "shell", "commandexecution":
            return "terminal"
        default:
            return "wrench.and.screwdriver"
        }
    }

    private var toolDetail: String? {
        guard tool.filePath != nil || tool.pattern != nil || tool.command != nil else {
            return summarizedSingleLine(tool.input)
        }
        switch tool.name.lowercased() {
        case "read", "edit", "write":
            return tool.filePath.map(shortPath)
        case "grep", "glob":
            return tool.pattern
        case "bash", "command", "shell", "commandexecution":
            guard let command = tool.command else { return nil }
            return summarizedSingleLine(command)
        default:
            return nil
        }
    }

    private var meaningfulOutput: String? {
        guard let output = tool.output?.trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty,
              output.caseInsensitiveCompare("completed") != .orderedSame,
              output.caseInsensitiveCompare("updated") != .orderedSame else {
            return nil
        }
        return output
    }

    private var toolAccessibilityLabel: String {
        var parts = [toolTitle]
        if let toolDetail { parts.append(toolDetail) }
        if tool.isError {
            parts.append("failed")
        } else if !isComplete, isActiveTurn {
            parts.append("working")
        } else {
            parts.append("completed")
        }
        return parts.joined(separator: ", ")
    }

    private func toggleExpanded() {
        isExpanded.toggle()
    }

    private func summarizedSingleLine(_ value: String) -> String? {
        let summary = value
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !summary.isEmpty else { return nil }
        return summary.count <= 100 ? summary : String(summary.prefix(99)) + "…"
    }

    private func shortPath(_ value: String) -> String {
        let parts = value.split(separator: "/")
        let tail = parts.suffix(2)
        return tail.isEmpty ? value : tail.joined(separator: "/")
    }

    private func boundedDetail(_ value: String) -> String {
        let lines = value.components(separatedBy: .newlines)
        let visible = lines.prefix(80).joined(separator: "\n")
        let bounded = String(visible.prefix(12_000))
        if lines.count > 80 || visible.count > 12_000 {
            return bounded + "\n… activity detail truncated"
        }
        return bounded
    }
}

private enum ActivityCodePreviewTone {
    case standard
    case error
}

private struct ActivityCodePreview: View {
    let label: String
    let code: String
    var tone: ActivityCodePreviewTone = .standard

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(FXTypography.captionMedium)
                .foregroundStyle(tone == .error ? FXColors.error : FXColors.fgTertiary)
                .padding(.horizontal, FXSpacing.md)
                .padding(.vertical, FXSpacing.xs)

            FXDivider()

            ScrollView(.horizontal) {
                Text(code)
                    .font(FXTypography.monoSmall)
                    .foregroundStyle(tone == .error ? FXColors.error : FXColors.fgSecondary)
                    .padding(FXSpacing.md)
                    .fixedSize(horizontal: true, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .background(FXColors.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: FXRadii.sm))
        .overlay {
            RoundedRectangle(cornerRadius: FXRadii.sm)
                .strokeBorder(FXColors.borderSubtle, lineWidth: 0.5)
        }
    }
}

struct ActivityEditDiff: Sendable {
    enum LineKind: Sendable {
        case hunk
        case context
        case addition
        case deletion
    }

    struct Line: Identifiable, Sendable {
        let id: Int
        let kind: LineKind
        let text: String
        let oldLine: Int?
        let newLine: Int?
    }

    let path: String
    let lines: [Line]
    let additions: Int
    let deletions: Int

    init?(input: String) {
        guard let data = input.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        path = object["file_path"] as? String ?? "Edited file"
        let parsedLines: [Line]
        if let patches = object["_flowxStructuredPatch"] as? [[String: Any]], !patches.isEmpty {
            parsedLines = Self.lines(from: patches)
        } else if let oldSource = object["old_string"] as? String,
                  let newSource = object["new_string"] as? String {
            parsedLines = Self.fallbackLines(oldSource: oldSource, newSource: newSource)
        } else {
            return nil
        }

        lines = parsedLines
        additions = parsedLines.reduce(into: 0) { count, line in
            if line.kind == .addition { count += 1 }
        }
        deletions = parsedLines.reduce(into: 0) { count, line in
            if line.kind == .deletion { count += 1 }
        }
    }

    private static func lines(from patches: [[String: Any]]) -> [Line] {
        var result: [Line] = []
        var nextID = 0

        for patch in patches {
            var oldLine = integer(patch["oldStart"]) ?? 1
            var newLine = integer(patch["newStart"]) ?? 1
            let oldCount = integer(patch["oldLines"]) ?? 0
            let newCount = integer(patch["newLines"]) ?? 0
            result.append(
                Line(
                    id: nextID,
                    kind: .hunk,
                    text: "@@ -\(oldLine),\(oldCount) +\(newLine),\(newCount) @@",
                    oldLine: nil,
                    newLine: nil
                )
            )
            nextID += 1

            for rawLine in patch["lines"] as? [String] ?? [] {
                let prefix = rawLine.first
                let kind: LineKind
                let oldValue: Int?
                let newValue: Int?
                switch prefix {
                case "+":
                    kind = .addition
                    oldValue = nil
                    newValue = newLine
                    newLine += 1
                case "-":
                    kind = .deletion
                    oldValue = oldLine
                    newValue = nil
                    oldLine += 1
                default:
                    kind = .context
                    oldValue = oldLine
                    newValue = newLine
                    oldLine += 1
                    newLine += 1
                }
                result.append(
                    Line(
                        id: nextID,
                        kind: kind,
                        text: rawLine,
                        oldLine: oldValue,
                        newLine: newValue
                    )
                )
                nextID += 1
            }
        }

        return result
    }

    private static func fallbackLines(oldSource: String, newSource: String) -> [Line] {
        let oldLines = oldSource.components(separatedBy: .newlines)
        let newLines = newSource.components(separatedBy: .newlines)
        var prefixCount = 0
        while prefixCount < min(oldLines.count, newLines.count),
              oldLines[prefixCount] == newLines[prefixCount] {
            prefixCount += 1
        }

        var suffixCount = 0
        while suffixCount < min(oldLines.count - prefixCount, newLines.count - prefixCount),
              oldLines[oldLines.count - suffixCount - 1] == newLines[newLines.count - suffixCount - 1] {
            suffixCount += 1
        }

        var result: [Line] = []
        var nextID = 0
        let contextStart = max(0, prefixCount - 3)
        for line in oldLines[contextStart..<prefixCount] {
            result.append(Line(id: nextID, kind: .context, text: " \(line)", oldLine: nil, newLine: nil))
            nextID += 1
        }

        let oldEnd = max(prefixCount, oldLines.count - suffixCount)
        for line in oldLines[prefixCount..<oldEnd] {
            result.append(Line(id: nextID, kind: .deletion, text: "-\(line)", oldLine: nil, newLine: nil))
            nextID += 1
        }

        let newEnd = max(prefixCount, newLines.count - suffixCount)
        for line in newLines[prefixCount..<newEnd] {
            result.append(Line(id: nextID, kind: .addition, text: "+\(line)", oldLine: nil, newLine: nil))
            nextID += 1
        }

        let contextEnd = min(oldLines.count, oldLines.count - suffixCount + 3)
        if oldLines.count - suffixCount < contextEnd {
            for line in oldLines[(oldLines.count - suffixCount)..<contextEnd] {
                result.append(Line(id: nextID, kind: .context, text: " \(line)", oldLine: nil, newLine: nil))
                nextID += 1
            }
        }
        return result
    }

    private static func integer(_ value: Any?) -> Int? {
        if let integer = value as? Int { return integer }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }
}

private struct ActivityEditDiffView: View {
    let diff: ActivityEditDiff

    @State private var visibleLineLimit = 140
    @State private var viewportWidth: CGFloat = 0

    private let pageSize = 140
    private let maximumVisibleLines = 560

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: FXSpacing.sm) {
                Text(shortPath(diff.path))
                    .font(FXTypography.captionMedium)
                    .foregroundStyle(FXColors.fgSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)

                if diff.additions > 0 {
                    Text("+\(diff.additions)")
                        .font(FXTypography.monoSmall)
                        .foregroundStyle(FXColors.diffAddedFg)
                }
                if diff.deletions > 0 {
                    Text("-\(diff.deletions)")
                        .font(FXTypography.monoSmall)
                        .foregroundStyle(FXColors.diffRemovedFg)
                }
            }
            .padding(.horizontal, FXSpacing.md)
            .padding(.vertical, FXSpacing.xs)
            .background(FXColors.bgElevated)

            ScrollView(.horizontal) {
                LazyVStack(spacing: 0) {
                    ForEach(visibleLines) { line in
                        diffLine(line)
                    }
                }
                .frame(minWidth: viewportWidth, alignment: .leading)
            }
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ActivityDiffViewportWidthKey.self,
                        value: proxy.size.width
                    )
                }
            }
            .onPreferenceChange(ActivityDiffViewportWidthKey.self) { width in
                viewportWidth = max(0, width)
            }

            if remainingPageLineCount > 0 {
                FXDivider()
                Button("Show \(remainingPageLineCount) more lines") {
                    visibleLineLimit = min(
                        maximumVisibleLines,
                        visibleLineLimit + pageSize
                    )
                }
                .buttonStyle(.plain)
                .font(FXTypography.captionMedium)
                .foregroundStyle(FXColors.accent)
                .padding(.horizontal, FXSpacing.md)
                .padding(.vertical, FXSpacing.sm)
            } else if cappedHiddenLineCount > 0 {
                FXDivider()
                Text("Showing the first \(maximumVisibleLines) of \(diff.lines.count) lines")
                    .font(FXTypography.caption)
                    .foregroundStyle(FXColors.fgTertiary)
                    .padding(.horizontal, FXSpacing.md)
                    .padding(.vertical, FXSpacing.sm)
            }
        }
        .background(FXColors.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: FXRadii.sm))
        .overlay {
            RoundedRectangle(cornerRadius: FXRadii.sm)
                .strokeBorder(FXColors.borderSubtle, lineWidth: 0.5)
        }
    }

    private var visibleLines: ArraySlice<ActivityEditDiff.Line> {
        diff.lines.prefix(min(visibleLineLimit, maximumVisibleLines))
    }

    private var remainingPageLineCount: Int {
        let renderedCount = visibleLines.count
        let safeRemaining = max(0, min(diff.lines.count, maximumVisibleLines) - renderedCount)
        return min(pageSize, safeRemaining)
    }

    private var cappedHiddenLineCount: Int {
        max(0, diff.lines.count - maximumVisibleLines)
    }

    private func diffLine(_ line: ActivityEditDiff.Line) -> some View {
        HStack(spacing: 0) {
            lineNumber(line.oldLine)
            lineNumber(line.newLine)

            Text(verbatim: line.text.isEmpty ? " " : line.text)
                .font(FXTypography.monoSmall)
                .foregroundStyle(foreground(for: line.kind))
                .padding(.horizontal, FXSpacing.sm)
                .padding(.vertical, 1)
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 0)
        }
        .frame(minWidth: viewportWidth, alignment: .leading)
        .background(background(for: line.kind))
    }

    private func lineNumber(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .font(FXTypography.monoSmall)
            .foregroundStyle(FXColors.fgQuaternary)
            .frame(width: 42, alignment: .trailing)
            .padding(.horizontal, FXSpacing.xs)
            .padding(.vertical, 1)
            .background(FXColors.bgElevated.opacity(0.6))
    }

    private func foreground(for kind: ActivityEditDiff.LineKind) -> Color {
        switch kind {
        case .addition:
            FXColors.diffAddedFg
        case .deletion:
            FXColors.diffRemovedFg
        case .hunk:
            FXColors.info
        case .context:
            FXColors.fgSecondary
        }
    }

    private func background(for kind: ActivityEditDiff.LineKind) -> Color {
        switch kind {
        case .addition:
            FXColors.diffAddedBg
        case .deletion:
            FXColors.diffRemovedBg
        case .hunk:
            FXColors.info.opacity(0.08)
        case .context:
            .clear
        }
    }

    private func shortPath(_ value: String) -> String {
        let parts = value.split(separator: "/")
        let tail = parts.suffix(3)
        return tail.isEmpty ? value : tail.joined(separator: "/")
    }
}

private struct ActivityDiffViewportWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
