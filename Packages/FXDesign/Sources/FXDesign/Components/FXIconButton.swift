import SwiftUI

/// A compact, flat icon control shared by toolbars and pane headers.
public struct FXIconButton: View {
    private let icon: String
    private let label: String
    private let isSelected: Bool
    private let tint: Color?
    private let size: CGFloat
    private let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    public init(
        icon: String,
        label: String,
        isSelected: Bool = false,
        tint: Color? = nil,
        size: CGFloat = 28,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.label = label
        self.isSelected = isSelected
        self.tint = tint
        self.size = size
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(FXTypography.icon(.small))
                .foregroundStyle(foregroundColor)
                .frame(width: size, height: size)
                .background(backgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: FXRadii.xs))
                .overlay(
                    RoundedRectangle(cornerRadius: FXRadii.xs)
                        .strokeBorder(isSelected ? FXColors.borderMedium : FXColors.borderSubtle.opacity(isHovered ? 1 : 0), lineWidth: 0.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = isEnabled && $0 }
        .help(label)
        .accessibilityLabel(label)
    }

    private var foregroundColor: Color {
        guard isEnabled else { return FXColors.fgQuaternary }
        if let tint { return tint }
        return isSelected || isHovered ? FXColors.fg : FXColors.fgTertiary
    }

    private var backgroundColor: Color {
        guard isEnabled else { return FXColors.bgSurface.opacity(0.3) }
        if isSelected { return FXColors.bgSelected }
        if isHovered { return FXColors.bgHover }
        return FXColors.bgSurface.opacity(0.55)
    }
}
