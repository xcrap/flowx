import SwiftUI

/// A quiet, space-efficient action used for progressively disclosed controls.
public struct FXCompactActionButton: View {
    private let label: String
    private let icon: String?
    private let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    public init(
        _ label: String,
        icon: String? = nil,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.icon = icon
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: FXSpacing.xxs) {
                if let icon {
                    Image(systemName: icon)
                        .font(FXTypography.icon(.micro))
                }

                Text(label)
                    .font(FXTypography.captionMedium)
                    .lineLimit(1)
            }
            .foregroundStyle(isEnabled ? FXColors.fgSecondary : FXColors.fgQuaternary)
            .padding(.horizontal, FXSpacing.sm)
            .frame(height: 24)
            .background(isHovered ? FXColors.bgHover : FXColors.bgElevated)
            .clipShape(RoundedRectangle(cornerRadius: FXRadii.sm))
            .overlay(
                RoundedRectangle(cornerRadius: FXRadii.sm)
                    .strokeBorder(FXColors.borderSubtle, lineWidth: FXBorderWidth.hairline)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = isEnabled && $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}
