import SwiftUI

public enum FXTypography {
    // SF Pro Rounded — crisp, modern, highly readable
    public static let title1 = Font.system(size: 26, weight: .semibold, design: .rounded)
    public static let title2 = Font.system(size: 20, weight: .semibold, design: .rounded)
    public static let title3 = Font.system(size: 16, weight: .medium, design: .rounded)
    public static let body = Font.system(size: 14, weight: .regular, design: .rounded)
    public static let bodyMedium = Font.system(size: 14, weight: .medium, design: .rounded)
    public static let caption = Font.system(size: 12, weight: .regular, design: .rounded)
    public static let captionMedium = Font.system(size: 12, weight: .medium, design: .rounded)
    public static let mono = Font.system(size: 13, weight: .regular, design: .monospaced)
    public static let monoSmall = Font.system(size: 12, weight: .regular, design: .monospaced)
}

public extension View {
    func fxTitle1() -> some View { font(FXTypography.title1).foregroundStyle(FXColors.fg) }
    func fxTitle2() -> some View { font(FXTypography.title2).foregroundStyle(FXColors.fg) }
    func fxTitle3() -> some View { font(FXTypography.title3).foregroundStyle(FXColors.fg) }
    func fxBody() -> some View { font(FXTypography.body).foregroundStyle(FXColors.fg) }
    func fxCaption() -> some View { font(FXTypography.caption).foregroundStyle(FXColors.fgSecondary) }
    func fxMono() -> some View { font(FXTypography.mono).foregroundStyle(FXColors.fg) }
}
