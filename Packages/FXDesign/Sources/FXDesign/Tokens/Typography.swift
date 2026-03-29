import SwiftUI

public enum FXTypography {
    // SF Pro Rounded — crisp, modern, highly readable
    public static var title1: Font { .system(size: scaled(26), weight: .semibold, design: .rounded) }
    public static var title2: Font { .system(size: scaled(20), weight: .semibold, design: .rounded) }
    public static var title3: Font { .system(size: scaled(16), weight: .medium, design: .rounded) }
    public static var body: Font { .system(size: scaled(14), weight: .regular, design: .rounded) }
    public static var bodyMedium: Font { .system(size: scaled(14), weight: .medium, design: .rounded) }
    public static var caption: Font { .system(size: scaled(12), weight: .regular, design: .rounded) }
    public static var captionMedium: Font { .system(size: scaled(12), weight: .medium, design: .rounded) }
    public static var mono: Font { .system(size: scaled(13), weight: .regular, design: .monospaced) }
    public static var monoSmall: Font { .system(size: scaled(12), weight: .regular, design: .monospaced) }

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
