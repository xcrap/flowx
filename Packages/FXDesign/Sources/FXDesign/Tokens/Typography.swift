import SwiftUI

public enum FXIconSize {
    case micro
    case small
    case regular
    case control
    case medium
    case large
    case illustration
    case action
    case hero
}

public enum FXTypography {
    // SF Pro Rounded — crisp, modern, highly readable
    public static var title1: Font { .system(size: scaled(26), weight: .semibold, design: .rounded) }
    public static var title2: Font { .system(size: scaled(20), weight: .semibold, design: .rounded) }
    public static var title3: Font { .system(size: scaled(16), weight: .medium, design: .rounded) }
    public static var body: Font { .system(size: scaled(14), weight: .regular, design: .rounded) }
    public static var bodyMedium: Font { .system(size: scaled(14), weight: .medium, design: .rounded) }
    public static var caption: Font { .system(size: scaled(12), weight: .regular, design: .rounded) }
    public static var captionMedium: Font { .system(size: scaled(12), weight: .medium, design: .rounded) }
    public static var overline: Font { .system(size: scaled(11), weight: .semibold, design: .rounded) }
    public static var mono: Font { .system(size: scaled(13), weight: .regular, design: .monospaced) }
    public static var monoSmall: Font { .system(size: scaled(12), weight: .regular, design: .monospaced) }

    /// AppKit-compatible point size for native text editors.
    /// This is the same scaled measure used by the SwiftUI body token.
    public static var bodyPointSize: CGFloat { scaled(14) }

    /// AppKit-compatible point size for SwiftTerm and other native code views.
    /// This is the same scaled measure used by the SwiftUI monospace token.
    public static var terminalPointSize: CGFloat { scaled(13) }

    /// Scaled SF Symbol sizing for controls and state illustrations.
    public static func icon(_ size: FXIconSize) -> Font {
        switch size {
        case .micro:
            .system(size: scaled(9), weight: .semibold)
        case .small:
            .system(size: scaled(11), weight: .medium)
        case .regular:
            .system(size: scaled(12), weight: .medium)
        case .control:
            .system(size: scaled(13), weight: .medium)
        case .medium:
            .system(size: scaled(14), weight: .medium)
        case .large:
            .system(size: scaled(18), weight: .medium)
        case .illustration:
            .system(size: scaled(22), weight: .regular)
        case .action:
            .system(size: scaled(26), weight: .regular)
        case .hero:
            .system(size: scaled(44), weight: .ultraLight)
        }
    }

    private static func scaled(_ base: CGFloat) -> CGFloat {
        base * FXTheme.textScale
    }
}

public extension View {
    func fxTitle1() -> some View { font(FXTypography.title1).foregroundStyle(FXColors.fg) }
    func fxTitle2() -> some View { font(FXTypography.title2).foregroundStyle(FXColors.fg) }
    func fxTitle3() -> some View { font(FXTypography.title3).foregroundStyle(FXColors.fg) }
    func fxBody() -> some View { font(FXTypography.body).foregroundStyle(FXColors.fg) }
    func fxCaption() -> some View { font(FXTypography.caption).foregroundStyle(FXColors.fgSecondary) }
    func fxMono() -> some View { font(FXTypography.mono).foregroundStyle(FXColors.fg) }
}
