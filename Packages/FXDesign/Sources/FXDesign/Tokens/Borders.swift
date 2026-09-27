import SwiftUI

/// Stroke widths for borders around cards, fields, menus, and controls.
public enum FXBorderWidth {
    /// The default FlowX edge: a half-point line that reads as a crisp
    /// single pixel on Retina displays.
    public static let hairline: CGFloat = 0.5
    /// Focused or selected fields.
    public static let regular: CGFloat = 1
    /// Active drop targets and other states that must stand out.
    public static let strong: CGFloat = 1.5
}
