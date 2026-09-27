import SwiftUI

public enum FXIconButtonVariant {
    /// Subtle surface fill at rest; used in pane headers.
    case filled
    /// No chrome at rest, hover highlight only; selection tints the icon with
    /// the accent. Used in the window title bar.
    case ghost
}

/// A compact, flat icon control shared by toolbars and pane headers.
public struct FXIconButton: View {
    private let icon: String
    private let label: String
    private let isSelected: Bool
    private let tint: Color?
    private let size: CGFloat
    private let iconSize: FXIconSize
    private let variant: FXIconButtonVariant
    private let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    public init(
        icon: String,
        label: String,
        isSelected: Bool = false,
        tint: Color? = nil,
        size: CGFloat = 28,
        iconSize: FXIconSize = .small,
        variant: FXIconButtonVariant = .filled,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.label = label
        self.isSelected = isSelected
        self.tint = tint
        self.size = size
        self.iconSize = iconSize
        self.variant = variant
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(FXTypography.icon(iconSize))
                .foregroundStyle(foregroundColor)
                .frame(width: size, height: size)
                .background(backgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(borderColor, lineWidth: 0.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = isEnabled && $0 }
        .help(label)
        .accessibilityLabel(label)
    }

    private var cornerRadius: CGFloat {
        variant == .ghost ? FXRadii.sm : FXRadii.xs
    }

    private var foregroundColor: Color {
        guard isEnabled else { return FXColors.fgQuaternary }
        if let tint { return tint }
        if variant == .ghost {
            if isSelected { return FXColors.accent }
            return isHovered ? FXColors.fg : FXColors.fgTertiary
        }
        return isSelected || isHovered ? FXColors.fg : FXColors.fgTertiary
    }

    private var backgroundColor: Color {
        if variant == .ghost {
            return isEnabled && isHovered ? FXColors.bgHover : .clear
        }
        guard isEnabled else { return FXColors.bgSurface.opacity(0.3) }
        if isSelected { return FXColors.bgSelected }
        if isHovered { return FXColors.bgHover }
        return FXColors.bgSurface.opacity(0.55)
    }

    private var borderColor: Color {
        if variant == .ghost { return .clear }
        return isSelected ? FXColors.borderMedium : FXColors.borderSubtle.opacity(isHovered ? 1 : 0)
    }
}
