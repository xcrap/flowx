import AppKit
import SwiftUI
import FXDesign
import FXCore

struct MessageBubble: View {
    private struct HistoricalClaudeQuestionPayload {
        let questions: [HistoricalClaudeQuestion]
    }

    private struct HistoricalClaudeQuestion {
        let header: String
        let question: String
        let allowsMultiple: Bool
        let options: [HistoricalClaudeQuestionOption]
    }

    private struct HistoricalClaudeQuestionOption {
        let label: String
        let description: String
    }

    private let messageID: UUID?
    private let role: MessageRole
    private let content: [MessageContent]
    private let isStreaming: Bool
    private let historicalClaudeQuestionsByIndex: [Int: HistoricalClaudeQuestionPayload]
    private let presentedTextByIndex: [Int: String]
    private let attachmentFilenames: [String]
    private let directives: [TranscriptDirective]

    init(message: ConversationMessage) {
        messageID = message.id
        role = message.role
        content = message.content
        isStreaming = false
        historicalClaudeQuestionsByIndex = Self.parseHistoricalClaudeQuestions(in: message.content)
        let presentation = Self.presentation(for: message.content, role: message.role)
        presentedTextByIndex = presentation.textByIndex
        attachmentFilenames = presentation.attachmentFilenames
        directives = presentation.directives
    }

    init(streamingText: String) {
        messageID = nil
        role = .assistant
        content = [.text(streamingText)]
        isStreaming = true
        historicalClaudeQuestionsByIndex = [:]
        let presentation = Self.presentation(for: content, role: .assistant)
        presentedTextByIndex = presentation.textByIndex
        attachmentFilenames = []
        directives = presentation.directives
    }

    private var isUser: Bool { role == .user }
    private var isToolEventMessage: Bool {
        !content.isEmpty && content.allSatisfy { item in
            switch item {
            case .toolUse, .toolResult:
                true
            default:
                false
            }
        }
    }

    var body: some View {
        if isToolEventMessage {
            toolEventBody
        } else {
            standardBubble
        }
    }

    private var standardBubble: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: FXSpacing.sm) {
            if isUser, !userImageEntries.isEmpty {
                UserMessageAttachmentGrid(
                    entries: userImageEntries,
                    filenames: attachmentFilenames,
                    messageID: messageID
                )
            }

            HStack(alignment: .top, spacing: 0) {
                if isUser { Spacer(minLength: 80) }

                VStack(alignment: .leading, spacing: FXSpacing.xs) {
                    ForEach(displayContentEntries, id: \.offset) { entry in
                        contentView(for: entry.element, index: entry.offset)
                    }

                    if !isUser, !directives.isEmpty {
                        TranscriptActionSummaryView(directives: directives)
                    }
                }
                .frame(
                    maxWidth: isUser ? FXLayout.userMessageMaxWidth : .infinity,
                    alignment: .leading
                )
                .padding(.horizontal, isUser ? FXSpacing.xl : 0)
                .padding(.vertical, isUser ? FXSpacing.md : FXSpacing.xs)
                .background(isUser ? FXColors.accent.opacity(0.12) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: isUser ? FXRadii.xl : 0))
                .overlay(
                    RoundedRectangle(cornerRadius: isUser ? FXRadii.xl : 0)
                        .strokeBorder(isUser ? FXColors.accent.opacity(0.2) : Color.clear, lineWidth: 0.5)
                )

                if !isUser { Spacer(minLength: 80) }
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .contextMenu {
            if !copyableText.isEmpty {
                Button("Copy Message", systemImage: "doc.on.doc", action: copyMessage)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isUser ? "Your message" : "Assistant message")
    }

    private var toolEventBody: some View {
        VStack(alignment: .leading, spacing: FXSpacing.xxs) {
            ForEach(Array(content.enumerated()), id: \.offset) { index, item in
                toolEventRow(for: item, index: index)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func contentView(for item: MessageContent, index: Int) -> some View {
        switch item {
        case .text(let text):
            let visibleText = presentedTextByIndex[index] ?? text
            if !visibleText.isEmpty {
                if isUser {
                    CollapsibleUserMessageTextView(
                        text: visibleText,
                        cacheKey: messageID.map { "\($0.uuidString)-\(index)" }
                    )
                } else {
                    MessageTextView(
                        text: visibleText,
                        cacheKey: messageID.map { "\($0.uuidString)-\(index)" },
                        isStreaming: isStreaming
                    )
                }
            }

        case .toolUse(_, let name, let input):
            if let payload = historicalClaudeQuestionsByIndex[index] {
                historicalClaudeQuestionCard(payload)
            } else {
                VStack(alignment: .leading, spacing: FXSpacing.xs) {
                    Label(name, systemImage: "wrench.and.screwdriver")
                        .font(FXTypography.bodyMedium)
                        .foregroundStyle(FXColors.accentSecondary)
                    if !input.isEmpty && input != "{}" {
                        Text(input)
                            .font(FXTypography.monoSmall)
                            .foregroundStyle(FXColors.fgSecondary)
                            .textSelection(.enabled)
                    }
                }
            }

        case .toolResult(_, let output, let isError):
            VStack(alignment: .leading, spacing: FXSpacing.xs) {
                Label(isError ? "Tool Failed" : "Tool Result", systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(FXTypography.bodyMedium)
                    .foregroundStyle(isError ? FXColors.error : FXColors.success)
                Text(output)
                    .font(FXTypography.monoSmall)
                    .foregroundStyle(FXColors.fgSecondary)
                    .textSelection(.enabled)
            }

        case .code(let language, let code):
            MessageCodeBlock(language: language, code: code)

        case .image(let data, let mimeType):
            MessageImageView(
                data: data,
                mimeType: mimeType,
                cacheKey: messageID.map { "message-\($0.uuidString)-\(index)" } ?? "streaming-image-\(index)"
            )

        case .imageAsset(let reference):
            MessageAssetImageView(
                reference: reference,
                cacheKey: "asset-\(reference.projectID.uuidString)-\(reference.agentID.uuidString)-\(reference.messageID.uuidString)-\(reference.contentIndex)"
            )
        }
    }

    private var userImageEntries: [(offset: Int, element: MessageContent)] {
        guard isUser else { return [] }
        return content.enumerated().filter { entry in
            switch entry.element {
            case .image, .imageAsset:
                return true
            default:
                return false
            }
        }
    }

    private var displayContentEntries: [(offset: Int, element: MessageContent)] {
        content.enumerated().filter { entry in
            guard isUser else { return true }
            switch entry.element {
            case .image, .imageAsset:
                return false
            default:
                return true
            }
        }
    }

    private static func presentation(
        for content: [MessageContent],
        role: MessageRole
    ) -> (
        textByIndex: [Int: String],
        attachmentFilenames: [String],
        directives: [TranscriptDirective]
    ) {
        var textByIndex: [Int: String] = [:]
        var attachmentFilenames: [String] = []
        var directives: [TranscriptDirective] = []

        for (index, item) in content.enumerated() {
            guard case .text(let text) = item else { continue }
            if role == .user {
                let presentation = TranscriptPresentationParser.userMessage(text)
                textByIndex[index] = presentation.visibleText
                attachmentFilenames.append(contentsOf: presentation.attachmentFilenames)
            } else if role == .assistant {
                let presentation = TranscriptPresentationParser.assistantMessage(text)
                textByIndex[index] = presentation.visibleText
                directives.append(contentsOf: presentation.directives)
            } else {
                textByIndex[index] = text
            }
        }

        return (textByIndex, attachmentFilenames, directives)
    }

    @ViewBuilder
    private func toolEventRow(for item: MessageContent, index: Int) -> some View {
        switch item {
        case .toolUse(_, let name, let input):
            if let payload = historicalClaudeQuestionsByIndex[index] {
                historicalClaudeQuestionCard(payload)
            } else {
                compactToolEventRow(
                    icon: "wrench.and.screwdriver",
                    iconColor: FXColors.accentSecondary,
                    title: name,
                    detail: summarizedToolInput(name: name, input: input)
                )
            }

        case .toolResult(_, let output, let isError):
            compactToolEventRow(
                icon: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                iconColor: isError ? FXColors.error : FXColors.success,
                title: isError ? "Tool failed" : "Tool result",
                detail: summarizedToolResult(output, isError: isError)
            )

        default:
            EmptyView()
        }
    }

    private func historicalClaudeQuestionCard(_ payload: HistoricalClaudeQuestionPayload) -> some View {
        VStack(alignment: .leading, spacing: FXSpacing.md) {
            HStack(spacing: FXSpacing.sm) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(FXTypography.icon(.medium))
                    .foregroundStyle(FXColors.accentSecondary)

                Text("Claude asked")
                    .font(FXTypography.bodyMedium)
                    .foregroundStyle(FXColors.fg)

                Spacer(minLength: FXSpacing.sm)

                FXBadge("Transcript", tone: .neutral)
            }

            ForEach(Array(payload.questions.enumerated()), id: \.offset) { questionIndex, question in
                if questionIndex > 0 {
                    Rectangle()
                        .fill(FXColors.borderSubtle)
                        .frame(height: 0.5)
                }

                historicalClaudeQuestion(question)
            }
        }
        .padding(FXSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FXColors.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: FXRadii.lg))
        .overlay(
            RoundedRectangle(cornerRadius: FXRadii.lg)
                .strokeBorder(FXColors.borderSubtle, lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recorded Claude question in transcript")
    }

    private func historicalClaudeQuestion(_ question: HistoricalClaudeQuestion) -> some View {
        VStack(alignment: .leading, spacing: FXSpacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: FXSpacing.sm) {
                Text(question.header.uppercased())
                    .font(FXTypography.overline)
                    .foregroundStyle(FXColors.accentSecondary)

                if !question.options.isEmpty {
                    Text(question.allowsMultiple ? "Multiple answers allowed" : "One answer")
                        .font(FXTypography.caption)
                        .foregroundStyle(FXColors.fgTertiary)
                }
            }

            Text(question.question)
                .font(FXTypography.bodyMedium)
                .foregroundStyle(FXColors.fg)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if !question.options.isEmpty {
                VStack(alignment: .leading, spacing: FXSpacing.xs) {
                    ForEach(Array(question.options.enumerated()), id: \.offset) { optionIndex, option in
                        HStack(alignment: .top, spacing: FXSpacing.sm) {
                            Text("\(optionIndex + 1)")
                                .font(FXTypography.captionMedium)
                                .foregroundStyle(FXColors.fgQuaternary)
                                .frame(width: 16, alignment: .trailing)

                            VStack(alignment: .leading, spacing: FXSpacing.xxxs) {
                                Text(option.label)
                                    .font(FXTypography.body)
                                    .foregroundStyle(FXColors.fg)
                                    .fixedSize(horizontal: false, vertical: true)

                                if !option.description.isEmpty {
                                    Text(option.description)
                                        .font(FXTypography.caption)
                                        .foregroundStyle(FXColors.fgSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private static func parseHistoricalClaudeQuestions(
        in content: [MessageContent]
    ) -> [Int: HistoricalClaudeQuestionPayload] {
        Dictionary(uniqueKeysWithValues: content.enumerated().compactMap { index, item in
            guard case .toolUse(_, let name, let input) = item,
                  name == "AskUserQuestion",
                  let payload = parseHistoricalClaudeQuestionPayload(input) else {
                return nil
            }
            return (index, payload)
        })
    }

    private static func parseHistoricalClaudeQuestionPayload(
        _ input: String
    ) -> HistoricalClaudeQuestionPayload? {
        guard let data = input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawQuestions = json["questions"] as? [[String: Any]] else {
            return nil
        }

        let questions = rawQuestions.prefix(4).compactMap { raw -> HistoricalClaudeQuestion? in
            guard let question = boundedTranscriptText(raw["question"] as? String, maximum: 8_192) else {
                return nil
            }

            let header = boundedTranscriptText(raw["header"] as? String, maximum: 256) ?? "Question"
            let options = (raw["options"] as? [[String: Any]] ?? []).prefix(10).compactMap {
                rawOption -> HistoricalClaudeQuestionOption? in
                guard let label = boundedTranscriptText(rawOption["label"] as? String, maximum: 256) else {
                    return nil
                }
                let description = boundedTranscriptText(
                    rawOption["description"] as? String,
                    maximum: 2_048
                ) ?? ""
                return HistoricalClaudeQuestionOption(label: label, description: description)
            }

            return HistoricalClaudeQuestion(
                header: header,
                question: question,
                allowsMultiple: raw["multiSelect"] as? Bool ?? false,
                options: options
            )
        }

        guard !questions.isEmpty else { return nil }
        return HistoricalClaudeQuestionPayload(questions: questions)
    }

    private static func boundedTranscriptText(_ text: String?, maximum: Int) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maximum))
    }

    private func compactToolEventRow(icon: String, iconColor: Color, title: String, detail: String?) -> some View {
        HStack(spacing: FXSpacing.sm) {
            Image(systemName: icon)
                .font(FXTypography.icon(.small))
                .foregroundStyle(iconColor)
                .frame(width: 14)

            Text(title)
                .font(FXTypography.captionMedium)
                .foregroundStyle(FXColors.fgSecondary)

            if let detail, !detail.isEmpty {
                Text("·")
                    .font(FXTypography.caption)
                    .foregroundStyle(FXColors.fgQuaternary)

                Text(detail)
                    .font(FXTypography.caption)
                    .foregroundStyle(FXColors.fgTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, FXSpacing.xxxs)
        .accessibilityElement(children: .combine)
    }

    private func summarizedToolInput(name: String, input: String) -> String? {
        guard !input.isEmpty, input != "{}" else { return nil }
        guard let data = input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return summarizedSingleLine(input)
        }

        let summary: String?
        switch name {
        case "Read", "Edit", "Write":
            summary = (json["file_path"] as? String).map { path in
                let shortPath = shortPathForDisplay(path)
                var result = shortPath
                if let offset = json["offset"] as? Int {
                    result += ":\(offset)"
                }
                if let limit = json["limit"] as? Int {
                    result += " (\(limit) lines)"
                }
                return result
            }
        case "Grep":
            summary = {
                var parts: [String] = []
                if let pattern = json["pattern"] as? String {
                    parts.append("\"\(pattern)\"")
                }
                if let type = json["type"] as? String {
                    parts.append("in *.\(type)")
                } else if let glob = json["glob"] as? String {
                    parts.append("in \(glob)")
                }
                return parts.isEmpty ? nil : parts.joined(separator: " ")
            }()
        case "Glob":
            summary = json["pattern"] as? String
        case "Bash", "Command", "Shell", "commandExecution":
            summary = (json["command"] as? String).map { summarizedSingleLine($0) }
        default:
            summary = nil
        }

        return summary ?? summarizedSingleLine(input)
    }

    private func summarizedToolResult(_ output: String, isError: Bool) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return isError ? "No error details provided" : "Completed"
        }

        return summarizedSingleLine(trimmed)
    }

    private func summarizedSingleLine(_ text: String, limit: Int = 120) -> String {
        let flattened = text
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? text

        if flattened.count <= limit {
            return flattened
        }

        return String(flattened.prefix(limit - 1)) + "…"
    }

    private func shortPathForDisplay(_ path: String) -> String {
        let components = path.split(separator: "/")
        let tail = components.suffix(2)
        return tail.isEmpty ? path : tail.joined(separator: "/")
    }

    private var copyableText: String {
        content.enumerated().compactMap { index, item -> String? in
            switch item {
            case .text(let text):
                presentedTextByIndex[index] ?? text
            case .code(_, let code):
                code
            case .toolUse(_, let name, let input):
                "\(name)\n\(input)"
            case .toolResult(_, let output, _):
                output
            case .image, .imageAsset:
                nil
            }
        }
        .joined(separator: "\n\n")
    }

    private func copyMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyableText, forType: .string)
    }
}

private struct CollapsibleUserMessageTextView: View {
    private static let collapsedCharacterLimit = 600
    private static let collapsedLineLimit = 8

    let text: String
    let cacheKey: String?

    @State private var isExpanded = false

    private var canCollapse: Bool {
        text.count > Self.collapsedCharacterLimit
            || text.components(separatedBy: .newlines).count > Self.collapsedLineLimit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FXSpacing.xs) {
            MessageTextView(text: text, cacheKey: cacheKey, isStreaming: false)
                .frame(
                    maxHeight: canCollapse && !isExpanded
                        ? FXLayout.collapsedUserMessageHeight
                        : nil,
                    alignment: .top
                )
                .clipped()

            if canCollapse {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: FXSpacing.xs) {
                        Text(isExpanded ? "Show less" : "Show full message")
                            .font(FXTypography.captionMedium)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(FXTypography.icon(.micro))
                    }
                    .foregroundStyle(FXColors.fgSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse message" : "Expand full message")
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            }
        }
    }
}

private struct UserMessageAttachmentGrid: View {
    let entries: [(offset: Int, element: MessageContent)]
    let filenames: [String]
    let messageID: UUID?

    private var columns: [GridItem] {
        [
            GridItem(
                .adaptive(
                    minimum: FXLayout.userAttachmentMinimumWidth,
                    maximum: FXLayout.userAttachmentMaximumWidth
                ),
                spacing: FXSpacing.sm
            ),
        ]
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: FXSpacing.sm) {
            ForEach(Array(entries.enumerated()), id: \.offset) { position, entry in
                let filename = filenames.indices.contains(position)
                    ? filenames[position]
                    : nil

                switch entry.element {
                case .image(let data, let mimeType):
                    MessageImageView(
                        data: data,
                        mimeType: mimeType,
                        cacheKey: messageID.map {
                            "message-\($0.uuidString)-\(entry.offset)"
                        } ?? "user-image-\(entry.offset)",
                        presentation: .thumbnail,
                        accessibilityName: filename
                    )

                case .imageAsset(let reference):
                    MessageAssetImageView(
                        reference: reference,
                        cacheKey: "asset-\(reference.projectID.uuidString)-\(reference.agentID.uuidString)-\(reference.messageID.uuidString)-\(reference.contentIndex)",
                        presentation: .thumbnail,
                        accessibilityName: filename
                    )

                default:
                    EmptyView()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            entries.count == 1
                ? "1 image attachment"
                : "\(entries.count) image attachments"
        )
    }
}

private struct TranscriptActionSummaryView: View {
    let directives: [TranscriptDirective]

    private var gitDirectives: [TranscriptDirective] {
        directives.filter { $0.name.hasPrefix("git-") }
    }

    private var otherDirectives: [TranscriptDirective] {
        directives.filter { !$0.name.hasPrefix("git-") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FXSpacing.xs) {
            if !gitDirectives.isEmpty {
                receiptRow(
                    icon: "checkmark.circle.fill",
                    tone: FXColors.success,
                    title: "Git",
                    detail: gitDetail
                )
            }

            ForEach(Array(otherDirectives.enumerated()), id: \.offset) { _, directive in
                receiptRow(
                    icon: icon(for: directive),
                    tone: FXColors.accentSecondary,
                    title: title(for: directive),
                    detail: detail(for: directive)
                )
            }
        }
        .padding(.top, FXSpacing.xxs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Completed app actions")
    }

    private func receiptRow(
        icon: String,
        tone: Color,
        title: String,
        detail: String
    ) -> some View {
        HStack(spacing: FXSpacing.sm) {
            Image(systemName: icon)
                .font(FXTypography.icon(.regular))
                .foregroundStyle(tone)
                .frame(width: 18)

            Text(title)
                .font(FXTypography.captionMedium)
                .foregroundStyle(FXColors.fg)

            Text("·")
                .font(FXTypography.caption)
                .foregroundStyle(FXColors.fgQuaternary)

            Text(detail)
                .font(FXTypography.caption)
                .foregroundStyle(FXColors.fgSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, FXSpacing.md)
        .padding(.vertical, FXSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FXColors.bgElevated)
        .clipShape(RoundedRectangle(cornerRadius: FXRadii.md))
        .overlay(
            RoundedRectangle(cornerRadius: FXRadii.md)
                .strokeBorder(FXColors.borderSubtle, lineWidth: 0.5)
        )
    }

    private var gitDetail: String {
        let names = Set(gitDirectives.map(\.name))
        var parts: [String] = []

        if names.contains("git-stage") {
            parts.append("Staged")
        }
        if names.contains("git-commit") {
            parts.append("Committed")
        }
        if let branch = gitDirectives.last(where: { $0.name == "git-push" })?["branch"] {
            parts.append("Pushed \(branch)")
        } else if names.contains("git-push") {
            parts.append("Pushed")
        }
        if let branch = gitDirectives.last(where: { $0.name == "git-create-branch" })?["branch"] {
            parts.append("Created \(branch)")
        }
        if names.contains("git-create-pr") {
            parts.append("Opened pull request")
        }

        return parts.isEmpty ? "Completed repository action" : parts.joined(separator: " · ")
    }

    private func icon(for directive: TranscriptDirective) -> String {
        switch directive.name {
        case "created-thread":
            "bubble.left.and.bubble.right.fill"
        case "code-comment":
            "text.bubble.fill"
        default:
            "checkmark.circle.fill"
        }
    }

    private func title(for directive: TranscriptDirective) -> String {
        switch directive.name {
        case "created-thread":
            "Task"
        case "code-comment":
            "Review"
        default:
            directive.name
                .split(separator: "-")
                .map { $0.capitalized }
                .joined(separator: " ")
        }
    }

    private func detail(for directive: TranscriptDirective) -> String {
        switch directive.name {
        case "created-thread":
            "Created task"
        case "code-comment":
            directive["title"] ?? "Added code comment"
        default:
            "Completed"
        }
    }
}

enum MessageImagePresentation {
    case full
    case thumbnail
}

@MainActor
private enum MessageRenderCache {
    private static let maximumEntries = 48
    private static var blocksByKey: [MessageTextRenderKey: [MessageRichBlock]] = [:]
    private static var orderedKeys: [MessageTextRenderKey] = []

    static func blocks(for key: MessageTextRenderKey) -> [MessageRichBlock]? {
        guard let blocks = blocksByKey[key] else { return nil }
        orderedKeys.removeAll { $0 == key }
        orderedKeys.append(key)
        return blocks
    }

    static func store(_ blocks: [MessageRichBlock], for key: MessageTextRenderKey) {
        blocksByKey[key] = blocks
        orderedKeys.removeAll { $0 == key }
        orderedKeys.append(key)

        while orderedKeys.count > maximumEntries {
            blocksByKey.removeValue(forKey: orderedKeys.removeFirst())
        }
    }
}

private struct MessageTextRenderKey: Hashable {
    let identity: String
    let text: String
}

private struct MessageTextView: View {
    private static let renderExecutor = BoundedTaskExecutor(maxConcurrentTasks: 2)

    let text: String
    let cacheKey: String?
    let isStreaming: Bool

    @State private var blocks: [MessageRichBlock] = []
    @State private var renderedKey: MessageTextRenderKey?

    private var renderKey: MessageTextRenderKey? {
        guard !isStreaming, let cacheKey else { return nil }
        return MessageTextRenderKey(identity: cacheKey, text: text)
    }

    var body: some View {
        Group {
            if isStreaming || renderedKey != renderKey || blocks.isEmpty {
                Text(text)
                    .font(FXTypography.body)
                    .foregroundStyle(FXColors.fg)
                    .textSelection(.enabled)
                    .lineSpacing(FXSpacing.xs)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: FXSpacing.md) {
                    ForEach(blocks) { block in
                        blockView(block)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: renderKey) {
            guard !isStreaming, let renderKey else {
                renderedKey = nil
                blocks = []
                return
            }

            if let cached = MessageRenderCache.blocks(for: renderKey) {
                blocks = cached
                renderedKey = renderKey
                return
            }

            let sourceText = renderKey.text
            let parsed: [MessageRichBlock]
            do {
                parsed = try await Self.renderExecutor.run(priority: .userInitiated) {
                    MessageRichBlock.parse(sourceText)
                }
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            blocks = parsed
            renderedKey = renderKey
            MessageRenderCache.store(parsed, for: renderKey)
        }
    }

    @ViewBuilder
    private func blockView(_ block: MessageRichBlock) -> some View {
        switch block.kind {
        case .paragraph(let value):
            richText(value, font: FXTypography.body)

        case .heading(let level, let value):
            richText(
                value,
                font: level == 1 ? FXTypography.title2 : (level == 2 ? FXTypography.title3 : FXTypography.bodyMedium)
            )
            .padding(.top, level == 1 ? FXSpacing.xs : 0)

        case .bullet(let value):
            HStack(alignment: .firstTextBaseline, spacing: FXSpacing.sm) {
                Circle()
                    .fill(FXColors.fgTertiary)
                    .frame(width: 5, height: 5)
                richText(value, font: FXTypography.body)
            }

        case .numbered(let marker, let value):
            HStack(alignment: .firstTextBaseline, spacing: FXSpacing.sm) {
                Text(marker)
                    .font(FXTypography.monoSmall)
                    .foregroundStyle(FXColors.fgTertiary)
                    .frame(minWidth: 20, alignment: .trailing)
                richText(value, font: FXTypography.body)
            }

        case .quote(let value):
            HStack(alignment: .top, spacing: FXSpacing.md) {
                RoundedRectangle(cornerRadius: FXRadii.xs)
                    .fill(FXColors.borderMedium)
                    .frame(width: 3)
                richText(value, font: FXTypography.body)
                    .foregroundStyle(FXColors.fgSecondary)
            }

        case .code(let language, let code):
            MessageCodeBlock(language: language, code: code)

        case .divider:
            FXDivider()
        }
    }

    private func richText(_ value: AttributedString, font: Font) -> some View {
        Text(value)
            .font(font)
            .foregroundStyle(FXColors.fg)
            .tint(FXColors.accent)
            .textSelection(.enabled)
            .lineSpacing(FXSpacing.xs)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MessageRichBlock: Identifiable, Sendable {
    enum Kind: Sendable {
        case paragraph(AttributedString)
        case heading(level: Int, AttributedString)
        case bullet(AttributedString)
        case numbered(marker: String, AttributedString)
        case quote(AttributedString)
        case code(language: String, code: String)
        case divider
    }

    let id: Int
    let kind: Kind

    static func parse(_ source: String) -> [MessageRichBlock] {
        var result: [MessageRichBlock] = []
        var paragraphLines: [String] = []
        var codeLines: [String] = []
        var codeLanguage = ""
        var isInsideCodeFence = false
        var nextID = 0

        func append(_ kind: Kind) {
            result.append(MessageRichBlock(id: nextID, kind: kind))
            nextID += 1
        }

        func inlineMarkdown(_ value: String) -> AttributedString {
            (try? AttributedString(
                markdown: value,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(value)
        }

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            append(.paragraph(inlineMarkdown(paragraphLines.joined(separator: "\n"))))
            paragraphLines.removeAll(keepingCapacity: true)
        }

        for (index, line) in source.components(separatedBy: .newlines).enumerated() {
            if index.isMultiple(of: 64), Task.isCancelled {
                return []
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if isInsideCodeFence {
                    append(.code(language: codeLanguage, code: codeLines.joined(separator: "\n")))
                    codeLines.removeAll(keepingCapacity: true)
                    codeLanguage = ""
                    isInsideCodeFence = false
                } else {
                    flushParagraph()
                    codeLanguage = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    isInsideCodeFence = true
                }
                continue
            }

            if isInsideCodeFence {
                codeLines.append(line)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            if let heading = heading(from: trimmed) {
                flushParagraph()
                append(.heading(level: heading.level, inlineMarkdown(heading.text)))
            } else if let bullet = bulletText(from: trimmed) {
                flushParagraph()
                append(.bullet(inlineMarkdown(bullet)))
            } else if let numbered = numberedText(from: trimmed) {
                flushParagraph()
                append(.numbered(marker: numbered.marker, inlineMarkdown(numbered.text)))
            } else if trimmed.hasPrefix("> ") {
                flushParagraph()
                append(.quote(inlineMarkdown(String(trimmed.dropFirst(2)))))
            } else if ["---", "***", "___"].contains(trimmed) {
                flushParagraph()
                append(.divider)
            } else {
                paragraphLines.append(line)
            }
        }

        if isInsideCodeFence {
            append(.code(language: codeLanguage, code: codeLines.joined(separator: "\n")))
        }
        flushParagraph()

        return Task.isCancelled ? [] : result
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        let markerCount = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(markerCount), line.dropFirst(markerCount).first == " " else { return nil }
        return (markerCount, String(line.dropFirst(markerCount + 1)))
    }

    private static func bulletText(from line: String) -> String? {
        guard line.count >= 2 else { return nil }
        let prefix = line.prefix(2)
        guard prefix == "- " || prefix == "* " || prefix == "+ " else { return nil }
        return String(line.dropFirst(2))
    }

    private static func numberedText(from line: String) -> (marker: String, text: String)? {
        guard let dotIndex = line.firstIndex(of: "."), dotIndex != line.startIndex else { return nil }
        let markerDigits = line[..<dotIndex]
        guard markerDigits.allSatisfy(\.isNumber) else { return nil }
        let afterDot = line.index(after: dotIndex)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        return ("\(markerDigits).", String(line[line.index(after: afterDot)...]))
    }
}

struct MessageCodeBlock: View {
    let language: String
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: FXSpacing.sm) {
                Text(languageLabel)
                    .font(FXTypography.captionMedium)
                    .foregroundStyle(FXColors.fgTertiary)

                Spacer(minLength: 0)

                FXIconButton(icon: "doc.on.doc", label: "Copy code", size: 24, action: copyCode)
            }
            .padding(.horizontal, FXSpacing.md)
            .padding(.vertical, FXSpacing.xs)
            .background(FXColors.bgElevated)

            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(FXTypography.mono)
                    .foregroundStyle(FXColors.fgSecondary)
                    .textSelection(.enabled)
                    .padding(FXSpacing.md)
                    .fixedSize(horizontal: true, vertical: true)
            }
        }
        .background(FXColors.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: FXRadii.md))
        .overlay(
            RoundedRectangle(cornerRadius: FXRadii.md)
                .strokeBorder(FXColors.borderSubtle, lineWidth: 0.5)
        )
    }

    private var languageLabel: String {
        language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "CODE" : language.uppercased()
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }
}

struct MessageImageView: View {
    let data: Data
    let mimeType: String
    let cacheKey: String
    let presentation: MessageImagePresentation
    let accessibilityName: String?

    @State private var image: NSImage?
    @State private var decodeFailed = false
    @State private var isPreviewPresented = false

    init(
        data: Data,
        mimeType: String,
        cacheKey: String,
        presentation: MessageImagePresentation = .full,
        accessibilityName: String? = nil
    ) {
        self.data = data
        self.mimeType = mimeType
        self.cacheKey = cacheKey
        self.presentation = presentation
        self.accessibilityName = accessibilityName
    }

    var body: some View {
        Group {
            if data.isEmpty {
                imagePlaceholder(
                    title: "Image attached",
                    detail: "The image was sent with this prompt but is not retained in conversation history."
                )
            } else if let image {
                renderedImage(image)
            } else if decodeFailed {
                imagePlaceholder(title: "Image unavailable", detail: "FlowX could not decode this \(mimeType) image.")
            } else {
                loadingPlaceholder
            }
        }
        .task {
            guard !data.isEmpty, image == nil, !decodeFailed else { return }
            if let cached = AttachmentImageCache.image(for: cacheKey) {
                image = cached
                return
            }

            let sourceData = data
            let decoded = await AttachmentImageCache.loadDownsampledImage(
                from: sourceData,
                maxPixelSize: 1_280
            )
            guard !Task.isCancelled else { return }

            if let decoded {
                image = AttachmentImageCache.store(decoded, for: cacheKey)
            } else {
                decodeFailed = true
            }
        }
        .sheet(isPresented: $isPreviewPresented) {
            if let image {
                MessageImagePreviewSheet(image: image, title: accessibilityName)
            }
        }
    }

    @ViewBuilder
    private func renderedImage(_ image: NSImage) -> some View {
        Group {
            switch presentation {
            case .full:
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 520, maxHeight: 360)

            case .thumbnail:
                ZStack {
                    FXColors.bgSurface
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                    .aspectRatio(FXLayout.userAttachmentAspectRatio, contentMode: .fit)
                    .clipped()
            }
        }
        .background(FXColors.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: FXRadii.lg))
        .overlay(
            RoundedRectangle(cornerRadius: FXRadii.lg)
                .strokeBorder(FXColors.borderSubtle, lineWidth: 0.5)
        )
        .contextMenu {
            Button("Copy Image", systemImage: "doc.on.doc", action: copyImage)
        }
        .contentShape(RoundedRectangle(cornerRadius: FXRadii.lg))
        .onTapGesture {
            isPreviewPresented = true
        }
        .help("Open image")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            isPreviewPresented = true
        }
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private func imagePlaceholder(title: String, detail: String) -> some View {
        if presentation == .thumbnail {
            placeholderContent(title: title, detail: detail)
                .aspectRatio(FXLayout.userAttachmentAspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(FXColors.bgSurface)
                .clipShape(RoundedRectangle(cornerRadius: FXRadii.lg))
                .overlay(
                    RoundedRectangle(cornerRadius: FXRadii.lg)
                        .strokeBorder(FXColors.borderSubtle, lineWidth: 0.5)
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel)
        } else {
            placeholderContent(title: title, detail: detail)
                .frame(maxWidth: 420, alignment: .leading)
                .background(FXColors.bgSurface)
                .clipShape(RoundedRectangle(cornerRadius: FXRadii.lg))
                .overlay(
                    RoundedRectangle(cornerRadius: FXRadii.lg)
                        .strokeBorder(FXColors.borderSubtle, lineWidth: 0.5)
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel)
        }
    }

    private func placeholderContent(title: String, detail: String) -> some View {
        HStack(spacing: FXSpacing.md) {
            Image(systemName: "photo")
                .font(FXTypography.icon(.large))
                .foregroundStyle(FXColors.fgTertiary)

            VStack(alignment: .leading, spacing: FXSpacing.xxxs) {
                Text(accessibilityName ?? title)
                    .font(FXTypography.bodyMedium)
                    .foregroundStyle(FXColors.fgSecondary)
                    .lineLimit(1)
                Text(detail)
                    .font(FXTypography.caption)
                    .foregroundStyle(FXColors.fgTertiary)
                    .lineLimit(presentation == .thumbnail ? 2 : nil)
            }
        }
        .padding(FXSpacing.md)
    }

    @ViewBuilder
    private var loadingPlaceholder: some View {
        let content = HStack(spacing: FXSpacing.sm) {
            ProgressView()
                .controlSize(.small)
            Text("Loading image…")
                .font(FXTypography.caption)
                .foregroundStyle(FXColors.fgTertiary)
                .lineLimit(1)
        }

        if presentation == .thumbnail {
            content
                .aspectRatio(FXLayout.userAttachmentAspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(FXColors.bgSurface)
                .clipShape(RoundedRectangle(cornerRadius: FXRadii.lg))
        } else {
            content
                .frame(width: 180, height: 96)
                .background(FXColors.bgSurface)
                .clipShape(RoundedRectangle(cornerRadius: FXRadii.lg))
        }
    }

    private var accessibilityLabel: String {
        accessibilityName.map { "Image attachment: \($0)" } ?? "Image attachment"
    }

    private func copyImage() {
        guard let image else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }
}

struct MessageAssetImageView: View {
    let reference: ConversationImageAssetReference
    let cacheKey: String
    let presentation: MessageImagePresentation
    let accessibilityName: String?

    @State private var image: NSImage?
    @State private var assetURL: URL?
    @State private var loadFailed = false
    @State private var isPreviewPresented = false

    init(
        reference: ConversationImageAssetReference,
        cacheKey: String,
        presentation: MessageImagePresentation = .full,
        accessibilityName: String? = nil
    ) {
        self.reference = reference
        self.cacheKey = cacheKey
        self.presentation = presentation
        self.accessibilityName = accessibilityName
    }

    var body: some View {
        Group {
            if let image {
                renderedImage(image)
            } else if loadFailed {
                assetPlaceholder(
                    icon: "photo.badge.exclamationmark",
                    title: "Image unavailable",
                    detail: "The saved attachment could not be loaded."
                )
            } else {
                loadingPlaceholder
            }
        }
        .task(id: cacheKey) {
            guard image == nil, !loadFailed else { return }

            do {
                let url = try ConversationAssetStore.fileURL(for: reference)
                assetURL = url

                if let cached = AttachmentImageCache.image(for: cacheKey) {
                    image = cached
                    return
                }

                let decoded = await AttachmentImageCache.loadDownsampledImage(
                    from: url,
                    maxPixelSize: 1_280
                )
                guard !Task.isCancelled else { return }

                if let decoded {
                    image = AttachmentImageCache.store(decoded, for: cacheKey)
                } else {
                    loadFailed = true
                }
            } catch {
                loadFailed = true
            }
        }
        .sheet(isPresented: $isPreviewPresented) {
            if let image {
                MessageImagePreviewSheet(image: image, title: accessibilityName)
            }
        }
    }

    @ViewBuilder
    private func renderedImage(_ image: NSImage) -> some View {
        Group {
            switch presentation {
            case .full:
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 520, maxHeight: 360)

            case .thumbnail:
                ZStack {
                    FXColors.bgSurface
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                    .aspectRatio(FXLayout.userAttachmentAspectRatio, contentMode: .fit)
                    .clipped()
            }
        }
        .background(FXColors.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: FXRadii.lg))
        .overlay(
            RoundedRectangle(cornerRadius: FXRadii.lg)
                .strokeBorder(FXColors.borderSubtle, lineWidth: 0.5)
        )
        .contextMenu {
            if assetURL != nil {
                Button("Copy Image File", systemImage: "doc.on.doc", action: copyImageFile)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: FXRadii.lg))
        .onTapGesture {
            isPreviewPresented = true
        }
        .help("Open image")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            isPreviewPresented = true
        }
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private func assetPlaceholder(icon: String, title: String, detail: String) -> some View {
        if presentation == .thumbnail {
            placeholderContent(icon: icon, title: title, detail: detail)
                .aspectRatio(FXLayout.userAttachmentAspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(FXColors.bgSurface)
                .clipShape(RoundedRectangle(cornerRadius: FXRadii.lg))
                .overlay(
                    RoundedRectangle(cornerRadius: FXRadii.lg)
                        .strokeBorder(FXColors.borderSubtle, lineWidth: 0.5)
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel)
        } else {
            placeholderContent(icon: icon, title: title, detail: detail)
                .frame(maxWidth: 420, alignment: .leading)
                .background(FXColors.bgSurface)
                .clipShape(RoundedRectangle(cornerRadius: FXRadii.lg))
                .overlay(
                    RoundedRectangle(cornerRadius: FXRadii.lg)
                        .strokeBorder(FXColors.borderSubtle, lineWidth: 0.5)
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel)
        }
    }

    private func placeholderContent(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: FXSpacing.md) {
            Image(systemName: icon)
                .font(FXTypography.icon(.large))
                .foregroundStyle(FXColors.fgTertiary)

            VStack(alignment: .leading, spacing: FXSpacing.xxxs) {
                Text(accessibilityName ?? title)
                    .font(FXTypography.bodyMedium)
                    .foregroundStyle(FXColors.fgSecondary)
                    .lineLimit(1)
                Text(detail)
                    .font(FXTypography.caption)
                    .foregroundStyle(FXColors.fgTertiary)
                    .lineLimit(presentation == .thumbnail ? 2 : nil)
            }
        }
        .padding(FXSpacing.md)
    }

    @ViewBuilder
    private var loadingPlaceholder: some View {
        let content = HStack(spacing: FXSpacing.sm) {
            ProgressView()
                .controlSize(.small)
            Text("Loading saved image…")
                .font(FXTypography.caption)
                .foregroundStyle(FXColors.fgTertiary)
                .lineLimit(1)
        }

        if presentation == .thumbnail {
            content
                .aspectRatio(FXLayout.userAttachmentAspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(FXColors.bgSurface)
                .clipShape(RoundedRectangle(cornerRadius: FXRadii.lg))
        } else {
            content
                .frame(width: 180, height: 96)
                .background(FXColors.bgSurface)
                .clipShape(RoundedRectangle(cornerRadius: FXRadii.lg))
        }
    }

    private var accessibilityLabel: String {
        accessibilityName.map { "Image attachment: \($0)" } ?? "Image attachment"
    }

    private func copyImageFile() {
        guard let assetURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([assetURL as NSURL])
    }
}

private struct MessageImagePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    let image: NSImage
    let title: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: FXSpacing.md) {
                Text(resolvedTitle)
                    .font(FXTypography.bodyMedium)
                    .foregroundStyle(FXColors.fgSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)

                FXIconButton(icon: "xmark", label: "Close image preview", size: 28) {
                    dismiss()
                }
            }
            .padding(.horizontal, FXSpacing.lg)
            .frame(height: 48)

            FXDivider()

            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(FXSpacing.lg)
        }
        .frame(
            minWidth: FXLayout.imagePreviewMinimumWidth,
            minHeight: FXLayout.imagePreviewMinimumHeight
        )
        .background(FXColors.bg)
    }

    private var resolvedTitle: String {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return "Image preview"
        }
        return title
    }
}
