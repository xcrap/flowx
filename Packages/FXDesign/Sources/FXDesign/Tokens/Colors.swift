import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

public enum FXAppearanceMode: String, CaseIterable, Codable {
    case system
    case dark
    case light

    public var label: String {
        switch self {
        case .system:
            "System"
        case .dark:
            "Dark"
        case .light:
            "Light"
        }
    }
}

public enum FXAccentColorOption: String, CaseIterable, Codable {
    case violet
    case blue
    case emerald
    case orange
    case rose

    public var label: String {
        switch self {
        case .violet:
            "Violet"
        case .blue:
            "Blue"
        case .emerald:
            "Emerald"
        case .orange:
            "Orange"
        case .rose:
            "Rose"
        }
    }

    public var color: Color {
        switch self {
        case .violet:
            Color(red: 0.424, green: 0.361, blue: 0.906)
        case .blue:
            Color(red: 0.255, green: 0.514, blue: 0.965)
        case .emerald:
            Color(red: 0.114, green: 0.706, blue: 0.478)
        case .orange:
            Color(red: 0.929, green: 0.478, blue: 0.098)
        case .rose:
            Color(red: 0.886, green: 0.286, blue: 0.545)
        }
    }

    public var hoverColor: Color {
        switch self {
        case .violet:
            Color(red: 0.490, green: 0.430, blue: 0.940)
        case .blue:
            Color(red: 0.353, green: 0.584, blue: 0.984)
        case .emerald:
            Color(red: 0.169, green: 0.761, blue: 0.525)
        case .orange:
            Color(red: 0.969, green: 0.561, blue: 0.180)
        case .rose:
            Color(red: 0.933, green: 0.376, blue: 0.620)
        }
    }
}

public enum FXTextSizePreset: String, CaseIterable, Codable {
    case compact
    case standard
    case comfortable
    case large

    public var label: String {
        switch self {
        case .compact:
            "Compact"
        case .standard:
            "Default"
        case .comfortable:
            "Comfortable"
        case .large:
            "Large"
        }
    }

    public var scale: CGFloat {
        switch self {
        case .compact:
            0.93
        case .standard:
            1.0
        case .comfortable:
            1.08
        case .large:
            1.16
        }
    }
}

private struct FXPalette {
    let bg: Color
    let bgElevated: Color
    let bgSurface: Color
    let bgHover: Color
    let bgSelected: Color
    let bgPressed: Color
    let fg: Color
    let fgSecondary: Color
    let fgTertiary: Color
    let fgQuaternary: Color
    let border: Color
    let borderMedium: Color
    let borderSubtle: Color
    let overlay: Color
    let overlayLight: Color
    let terminalBg: Color

#if canImport(AppKit)
    let windowBackground: NSColor
#endif

    static let dark = FXPalette(
        bg: Color(red: 0.067, green: 0.067, blue: 0.075),
        bgElevated: Color(red: 0.086, green: 0.086, blue: 0.094),
        bgSurface: Color(red: 0.110, green: 0.110, blue: 0.122),
        bgHover: Color.white.opacity(0.04),
        bgSelected: Color.white.opacity(0.08),
        bgPressed: Color.white.opacity(0.06),
        fg: Color(red: 0.980, green: 0.980, blue: 0.980),
        fgSecondary: Color(red: 0.631, green: 0.631, blue: 0.651),
        fgTertiary: Color(red: 0.431, green: 0.431, blue: 0.451),
        fgQuaternary: Color.white.opacity(0.24),
        border: Color(red: 0.173, green: 0.173, blue: 0.180),
        borderMedium: Color(red: 0.227, green: 0.227, blue: 0.235),
        borderSubtle: Color.white.opacity(0.06),
        overlay: Color.black.opacity(0.5),
        overlayLight: Color.black.opacity(0.3),
        terminalBg: Color(red: 0.047, green: 0.047, blue: 0.055),
        windowBackground: NSColor(red: 0.067, green: 0.067, blue: 0.075, alpha: 1)
    )

    static let light = FXPalette(
        bg: Color(red: 0.965, green: 0.965, blue: 0.976),
        bgElevated: Color(red: 0.941, green: 0.945, blue: 0.961),
        bgSurface: Color(red: 0.918, green: 0.925, blue: 0.945),
        bgHover: Color.black.opacity(0.04),
        bgSelected: Color.black.opacity(0.08),
        bgPressed: Color.black.opacity(0.06),
        fg: Color(red: 0.110, green: 0.118, blue: 0.145),
        fgSecondary: Color(red: 0.330, green: 0.353, blue: 0.412),
        fgTertiary: Color(red: 0.505, green: 0.529, blue: 0.592),
        fgQuaternary: Color.black.opacity(0.24),
        border: Color(red: 0.812, green: 0.827, blue: 0.871),
        borderMedium: Color(red: 0.733, green: 0.753, blue: 0.812),
        borderSubtle: Color.black.opacity(0.05),
        overlay: Color.black.opacity(0.18),
        overlayLight: Color.black.opacity(0.10),
        terminalBg: Color(red: 0.900, green: 0.908, blue: 0.929),
        windowBackground: NSColor(red: 0.965, green: 0.965, blue: 0.976, alpha: 1)
    )
}

public enum FXTheme {
    nonisolated(unsafe) public static var appearanceMode: FXAppearanceMode = .dark
    nonisolated(unsafe) public static var accentColorOption: FXAccentColorOption = .violet
    nonisolated(unsafe) public static var textSizePreset: FXTextSizePreset = .standard

    public static var preferredColorScheme: ColorScheme? {
        switch appearanceMode {
        case .system:
            nil
        case .dark:
            .dark
        case .light:
            .light
        }
    }

    public static var textScale: CGFloat {
        textSizePreset.scale
    }

    public static var accentColor: Color {
        accentColorOption.color
    }

    public static var accentHoverColor: Color {
        accentColorOption.hoverColor
    }

    public static var accentMutedColor: Color {
        accentColor.opacity(isDarkAppearance ? 0.16 : 0.12)
    }

#if canImport(AppKit)
    public static var windowBackgroundColor: NSColor {
        palette.windowBackground
    }
#endif

    private static var isDarkAppearance: Bool {
        switch appearanceMode {
        case .dark:
            return true
        case .light:
            return false
        case .system:
#if canImport(AppKit)
            return MainActor.assumeIsolated {
                guard let app = NSApp else { return true }
                return app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            }
#else
            return true
#endif
        }
    }

    private static var palette: FXPalette {
        isDarkAppearance ? .dark : .light
    }

    fileprivate static var currentPalette: FXPalette {
        palette
    }
}

public enum FXColors {
    // MARK: - Backgrounds
    public static var bg: Color { FXTheme.currentPalette.bg }
    public static var bgElevated: Color { FXTheme.currentPalette.bgElevated }
    public static var bgSurface: Color { FXTheme.currentPalette.bgSurface }
    public static var bgHover: Color { FXTheme.currentPalette.bgHover }
    public static var bgSelected: Color { FXTheme.currentPalette.bgSelected }
    public static var bgPressed: Color { FXTheme.currentPalette.bgPressed }

    // MARK: - Foregrounds
    public static var fg: Color { FXTheme.currentPalette.fg }
    public static var fgSecondary: Color { FXTheme.currentPalette.fgSecondary }
    public static var fgTertiary: Color { FXTheme.currentPalette.fgTertiary }
    public static var fgQuaternary: Color { FXTheme.currentPalette.fgQuaternary }

    // MARK: - Accents
    public static var accent: Color { FXTheme.accentColor }
    public static var accentHover: Color { FXTheme.accentHoverColor }
    public static let accentSecondary = Color(red: 0.306, green: 0.804, blue: 0.769)
    public static var accentMuted: Color { FXTheme.accentMutedColor }

    // MARK: - Semantic
    public static let success = Color(red: 0.204, green: 0.827, blue: 0.600)
    public static let warning = Color(red: 0.984, green: 0.749, blue: 0.141)
    public static let error = Color(red: 0.973, green: 0.443, blue: 0.443)
    public static let info = Color(red: 0.376, green: 0.647, blue: 0.980)

    // MARK: - Borders
    public static var border: Color { FXTheme.currentPalette.border }
    public static var borderMedium: Color { FXTheme.currentPalette.borderMedium }
    public static var borderSubtle: Color { FXTheme.currentPalette.borderSubtle }

    // MARK: - Overlays
    public static var overlay: Color { FXTheme.currentPalette.overlay }
    public static var overlayLight: Color { FXTheme.currentPalette.overlayLight }
}

// MARK: - Semantic Aliases (context-dependent)
public extension FXColors {
    static var sidebarBg: Color { bgElevated }
    static var contentBg: Color { bg }
    static var panelBg: Color { bgElevated }
    static var inputBg: Color { bgSurface }
    static var terminalBg: Color { FXTheme.currentPalette.terminalBg }
}
