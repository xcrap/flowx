import AppKit
import SwiftUI
import FXDesign
import FXCore

struct MessageBubble: View {
    private let messageID: UUID?
    private let role: MessageRole
    private let content: [MessageContent]
    private let isStreaming: Bool

    init(message: ConversationMessage) {
        messageID = message.id
        role = message.role
        content = message.content
        isStreaming = false
    }

    init(streamingText: String) {
        messageID = nil
        role = .assistant
        content = [.text(streamingText)]
        isStreaming = true
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
        HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: 80) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: FXSpacing.xs) {
                ForEach(Array(content.enumerated()), id: \.offset) { index, item in
                    contentView(for: item, index: index)
                }
            }
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
            ForEach(Array(content.enumerated()), id: \.offset) { _, item in
                toolEventRow(for: item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func contentView(for item: MessageContent, index: Int) -> some View {
        switch item {
        case .text(let text):
            MessageTextView(
                text: text,
                cacheKey: messageID.map { "\($0.uuidString)-\(index)" },
                isStreaming: isStreaming
            )

        case .toolUse(_, let name, let input):
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

    @ViewBuilder
    private func toolEventRow(for item: MessageContent) -> some View {
        switch item {
        case .toolUse(_, let name, let input):
            compactToolEventRow(
                icon: "wrench.and.screwdriver",
                iconColor: FXColors.accentSecondary,
                title: name,
                detail: summarizedToolInput(name: name, input: input)
            )

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
        content.compactMap { item -> String? in
            switch item {
            case .text(let text):
                text
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

private struct MessageCodeBlock: View {
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

private struct MessageImageView: View {
    let data: Data
    let mimeType: String
    let cacheKey: String

    @State private var image: NSImage?
    @State private var decodeFailed = false

    var body: some View {
        Group {
            if data.isEmpty {
                imagePlaceholder(
                    title: "Image attached",
                    detail: "The image was sent with this prompt but is not retained in conversation history."
                )
            } else if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 520, maxHeight: 360)
                    .background(FXColors.bgSurface)
                    .clipShape(RoundedRectangle(cornerRadius: FXRadii.lg))
                    .overlay(
                        RoundedRectangle(cornerRadius: FXRadii.lg)
                            .strokeBorder(FXColors.borderSubtle, lineWidth: 0.5)
                    )
                    .contextMenu {
                        Button("Copy Image", systemImage: "doc.on.doc", action: copyImage)
                    }
                    .accessibilityLabel("Image attachment")
            } else if decodeFailed {
                imagePlaceholder(title: "Image unavailable", detail: "FlowX could not decode this \(mimeType) image.")
            } else {
                HStack(spacing: FXSpacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading image…")
                        .font(FXTypography.caption)
                        .foregroundStyle(FXColors.fgTertiary)
                }
                .frame(width: 180, height: 96)
                .background(FXColors.bgSurface)
                .clipShape(RoundedRectangle(cornerRadius: FXRadii.lg))
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
    }

    private func imagePlaceholder(title: String, detail: String) -> some View {
        HStack(spacing: FXSpacing.md) {
            Image(systemName: "photo")
                .font(FXTypography.icon(.large))
                .foregroundStyle(FXColors.fgTertiary)

            VStack(alignment: .leading, spacing: FXSpacing.xxxs) {
                Text(title)
                    .font(FXTypography.bodyMedium)
                    .foregroundStyle(FXColors.fgSecondary)
                Text(detail)
                    .font(FXTypography.caption)
                    .foregroundStyle(FXColors.fgTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(FXSpacing.md)
        .frame(maxWidth: 420, alignment: .leading)
        .background(FXColors.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: FXRadii.lg))
        .overlay(
            RoundedRectangle(cornerRadius: FXRadii.lg)
                .strokeBorder(FXColors.borderSubtle, lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
    }

    private func copyImage() {
        guard let image else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }
}

private struct MessageAssetImageView: View {
    let reference: ConversationImageAssetReference
    let cacheKey: String

    @State private var image: NSImage?
    @State private var assetURL: URL?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 520, maxHeight: 360)
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
                    .accessibilityLabel("Image attachment")
            } else if loadFailed {
                assetPlaceholder(
                    icon: "photo.badge.exclamationmark",
                    title: "Image unavailable",
                    detail: "The saved attachment could not be loaded."
                )
            } else {
                HStack(spacing: FXSpacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading saved image…")
                        .font(FXTypography.caption)
                        .foregroundStyle(FXColors.fgTertiary)
                }
                .frame(width: 180, height: 96)
                .background(FXColors.bgSurface)
                .clipShape(RoundedRectangle(cornerRadius: FXRadii.lg))
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
    }

    private func assetPlaceholder(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: FXSpacing.md) {
            Image(systemName: icon)
                .font(FXTypography.icon(.large))
                .foregroundStyle(FXColors.fgTertiary)

            VStack(alignment: .leading, spacing: FXSpacing.xxxs) {
                Text(title)
                    .font(FXTypography.bodyMedium)
                    .foregroundStyle(FXColors.fgSecondary)
                Text(detail)
                    .font(FXTypography.caption)
                    .foregroundStyle(FXColors.fgTertiary)
            }
        }
        .padding(FXSpacing.md)
        .frame(maxWidth: 420, alignment: .leading)
        .background(FXColors.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: FXRadii.lg))
        .overlay(
            RoundedRectangle(cornerRadius: FXRadii.lg)
                .strokeBorder(FXColors.borderSubtle, lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
    }

    private func copyImageFile() {
        guard let assetURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([assetURL as NSURL])
    }
}
