import SwiftUI

/// A drop shadow recipe. Apply with `.fxShadow(_:)`.
public struct FXShadowStyle {
    public let color: Color
    public let radius: CGFloat
    public let x: CGFloat
    public let y: CGFloat

    public init(color: Color, radius: CGFloat, x: CGFloat = 0, y: CGFloat = 0) {
        self.color = color
        self.radius = radius
        self.x = x
        self.y = y
    }
}

/// Elevation for surfaces that float above the shell. Colors derive from
/// `FXColors.overlay`, so the depth adapts to light and dark modes.
public enum FXShadow {
    /// Dropdowns and context menus.
    public static var popover: FXShadowStyle {
        FXShadowStyle(color: FXColors.overlay.opacity(0.35), radius: 18, y: 10)
    }

    /// Centered confirmation and rename dialogs.
    public static var dialog: FXShadowStyle {
        FXShadowStyle(color: FXColors.overlay, radius: 24, y: 14)
    }

    /// The command palette, the highest floating surface.
    public static var palette: FXShadowStyle {
        FXShadowStyle(color: FXColors.overlay, radius: 28, y: 16)
    }

    /// Panels that slide over content from the trailing edge.
    public static var trailingPanel: FXShadowStyle {
        FXShadowStyle(color: FXColors.overlay.opacity(0.24), radius: 18, x: -4)
    }
}

public extension View {
    func fxShadow(_ style: FXShadowStyle) -> some View {
        shadow(color: style.color, radius: style.radius, x: style.x, y: style.y)
    }
}
