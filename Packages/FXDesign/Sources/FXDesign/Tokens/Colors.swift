import SwiftUI

public enum FXColors {
    // MARK: - Backgrounds
    public static let bg = Color(red: 0.067, green: 0.067, blue: 0.075)           // #111113
    public static let bgElevated = Color(red: 0.086, green: 0.086, blue: 0.094)   // #161618
    public static let bgSurface = Color(red: 0.110, green: 0.110, blue: 0.122)    // #1C1C1F
    public static let bgHover = Color.white.opacity(0.04)
    public static let bgSelected = Color.white.opacity(0.08)
    public static let bgPressed = Color.white.opacity(0.06)

    // MARK: - Foregrounds
    public static let fg = Color(red: 0.980, green: 0.980, blue: 0.980)           // #FAFAFA
    public static let fgSecondary = Color(red: 0.631, green: 0.631, blue: 0.651)  // #A1A1A6
    public static let fgTertiary = Color(red: 0.431, green: 0.431, blue: 0.451)   // #6E6E73
    public static let fgQuaternary = Color.white.opacity(0.24)

    // MARK: - Accents
    public static let accent = Color(red: 0.424, green: 0.361, blue: 0.906)       // #6C5CE7
    public static let accentHover = Color(red: 0.490, green: 0.430, blue: 0.940)
    public static let accentSecondary = Color(red: 0.306, green: 0.804, blue: 0.769) // #4ECDC4
    public static let accentMuted = Color(red: 0.424, green: 0.361, blue: 0.906).opacity(0.15)

    // MARK: - Semantic
    public static let success = Color(red: 0.204, green: 0.827, blue: 0.600)      // #34D399
    public static let warning = Color(red: 0.984, green: 0.749, blue: 0.141)      // #FBBF24
    public static let error = Color(red: 0.973, green: 0.443, blue: 0.443)        // #F87171
    public static let info = Color(red: 0.376, green: 0.647, blue: 0.980)         // #60A5FA

    // MARK: - Borders
    public static let border = Color(red: 0.173, green: 0.173, blue: 0.180)       // #2C2C2E
    public static let borderMedium = Color(red: 0.227, green: 0.227, blue: 0.235) // #3A3A3C
    public static let borderSubtle = Color.white.opacity(0.06)

    // MARK: - Overlays
    public static let overlay = Color.black.opacity(0.5)
    public static let overlayLight = Color.black.opacity(0.3)
}

// MARK: - Semantic Aliases (context-dependent)
public extension FXColors {
    static let sidebarBg = bgElevated
    static let contentBg = bg
    static let panelBg = bgElevated
    static let inputBg = bgSurface
    static let terminalBg = Color(red: 0.047, green: 0.047, blue: 0.055)  // slightly darker
}
