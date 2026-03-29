import SwiftUI

public enum FXBadgeTone {
    case neutral
    case accent
    case success
    case warning
    case error
    case info
}

public struct FXBadge: View {
    let text: String
    let tone: FXBadgeTone
    let showDot: Bool

    public init(_ text: String, tone: FXBadgeTone = .neutral, showDot: Bool = false) {
        self.text = text
        self.tone = tone
        self.showDot = showDot
    }

    public var body: some View {
        HStack(spacing: FXSpacing.xxs) {
            if showDot {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
            }
            Text(text)
                .font(FXTypography.captionMedium)
                .foregroundStyle(textColor)
        }
        .padding(.horizontal, FXSpacing.sm)
        .padding(.vertical, FXSpacing.xxxs)
        .background(bgColor)
        .clipShape(Capsule())
    }

    private var dotColor: Color {
        switch tone {
        case .neutral: FXColors.fgTertiary
        case .accent: FXColors.accent
        case .success: FXColors.success
        case .warning: FXColors.warning
        case .error: FXColors.error
        case .info: FXColors.info
        }
    }

    private var textColor: Color {
        switch tone {
        case .neutral: FXColors.fgSecondary
        case .accent: FXColors.accent
        case .success: FXColors.success
        case .warning: FXColors.warning
        case .error: FXColors.error
        case .info: FXColors.info
        }
    }

    private var bgColor: Color {
        dotColor.opacity(0.12)
    }
}
