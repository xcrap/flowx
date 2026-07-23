import SwiftUI

public enum FXButtonStyle {
    case primary
    case secondary
    case ghost
    case danger
}

public struct FXButton: View {
    let label: String
    let icon: String?
    let style: FXButtonStyle
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ label: String, icon: String? = nil, style: FXButtonStyle = .secondary, action: @escaping () -> Void) {
        self.label = label
        self.icon = icon
        self.style = style
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: FXSpacing.xs) {
                if let icon {
                    Image(systemName: icon)
                        .font(FXTypography.icon(.regular))
                }
                Text(label)
                    .font(FXTypography.bodyMedium)
            }
            .padding(.horizontal, FXSpacing.md)
            .padding(.vertical, FXSpacing.xs)
            .foregroundStyle(foregroundColor)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: FXRadii.sm))
            .overlay(
                RoundedRectangle(cornerRadius: FXRadii.sm)
                    .strokeBorder(borderColor, lineWidth: 0.5)
            )
            .scaleEffect(!reduceMotion && isPressed ? 0.97 : 1.0)
            .opacity(isEnabled ? 1 : 0.52)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = isEnabled && $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard isEnabled else { return }
                    if reduceMotion {
                        isPressed = true
                    } else {
                        withAnimation(FXAnimation.micro) { isPressed = true }
                    }
                }
                .onEnded { _ in
                    if reduceMotion {
                        isPressed = false
                    } else {
                        withAnimation(FXAnimation.quick) { isPressed = false }
                    }
                }
        )
        .accessibilityLabel(label)
    }

    private var foregroundColor: Color {
        switch style {
        case .primary: FXColors.onAccent
        case .secondary: FXColors.fg
        case .ghost: isHovered ? FXColors.fg : FXColors.fgSecondary
        case .danger: FXColors.error
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .primary: isHovered ? FXColors.accentHover : FXColors.accent
        case .secondary: isHovered ? FXColors.bgHover : FXColors.bgSurface
        case .ghost: isHovered ? FXColors.bgHover : .clear
        case .danger: isHovered ? FXColors.error.opacity(0.15) : FXColors.error.opacity(0.1)
        }
    }

    private var borderColor: Color {
        switch style {
        case .primary: .clear
        case .secondary: FXColors.border
        case .ghost: .clear
        case .danger: FXColors.error.opacity(0.3)
        }
    }
}
