import SwiftUI
import FXDesign
import FXCore

struct MessageBubble: View {
    private let role: MessageRole
    private let content: [MessageContent]

    init(message: ConversationMessage) {
        role = message.role
        content = message.content
    }

    init(streamingText: String) {
        role = .assistant
        content = [.text(streamingText)]
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
                ForEach(Array(content.enumerated()), id: \.offset) { _, item in
                    contentView(for: item)
                }
            }
            .padding(.horizontal, FXSpacing.xl)
            .padding(.vertical, FXSpacing.lg)
            .background(isUser ? FXColors.accent.opacity(0.12) : FXColors.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: FXRadii.xl))
            .overlay(
                RoundedRectangle(cornerRadius: FXRadii.xl)
                    .strokeBorder(isUser ? FXColors.accent.opacity(0.2) : FXColors.border, lineWidth: 0.5)
            )

            if !isUser { Spacer(minLength: 80) }
        }
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
    private func contentView(for item: MessageContent) -> some View {
        switch item {
        case .text(let text):
            Text(text)
                .font(FXTypography.body)
                .foregroundStyle(FXColors.fg)
                .textSelection(.enabled)
                .lineSpacing(8)
                .fixedSize(horizontal: false, vertical: true)

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
            VStack(alignment: .leading, spacing: FXSpacing.xs) {
                Text(language.uppercased())
                    .font(FXTypography.captionMedium)
                    .foregroundStyle(FXColors.fgTertiary)
                Text(code)
                    .font(FXTypography.mono)
                    .foregroundStyle(FXColors.fgSecondary)
                    .textSelection(.enabled)
            }

        case .image:
            Label("Image attachment", systemImage: "photo")
                .font(FXTypography.body)
                .foregroundStyle(FXColors.fgSecondary)
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
                .font(.system(size: 11, weight: .medium))
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
        case "Bash":
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
}
