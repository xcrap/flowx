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

    var body: some View {
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
}
