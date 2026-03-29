import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - User-facing options

public enum FXAppearanceMode: String, CaseIterable, Codable {
    case system, dark, light

    public var label: String {
        switch self {
        case .system: "System"
        case .dark: "Dark"
        case .light: "Light"
        }
    }
}

public enum FXBaseTone: String, CaseIterable, Codable {
    case slate, zinc, neutral, stone

    public var label: String { rawValue.capitalized }

    public var description: String {
        switch self {
        case .slate: "Cool blue-gray"
        case .zinc: "Near-neutral"
        case .neutral: "Pure gray"
        case .stone: "Warm gray"
        }
    }
}

public enum FXAccentColorOption: String, CaseIterable, Codable {
    case violet, blue, emerald, orange, rose

    public var label: String { rawValue.capitalized }

    public var color: Color {
        switch self {
        case .violet:  h(0x6C5CE7)
        case .blue:    h(0x4183F5)
        case .emerald: h(0x1DB47A)
        case .orange:  h(0xED7A19)
        case .rose:    h(0xE2498B)
        }
    }

    public var hoverColor: Color {
        switch self {
        case .violet:  h(0x7D6FF0)
        case .blue:    h(0x5A95F8)
        case .emerald: h(0x2BC286)
        case .orange:  h(0xF78F2E)
        case .rose:    h(0xEE609E)
        }
    }
}

public enum FXTextSizePreset: String, CaseIterable, Codable {
    case compact, standard, comfortable, large

    public var label: String {
        switch self {
        case .compact: "Compact"
        case .standard: "Default"
        case .comfortable: "Comfortable"
        case .large: "Large"
        }
    }

    public var scale: CGFloat {
        switch self {
        case .compact: 0.93
        case .standard: 1.0
        case .comfortable: 1.08
        case .large: 1.16
        }
    }
}

// MARK: - Tone Scales (Tailwind-derived, 50→950)

/// 11-step scale from lightest (50) to darkest (950).
/// Dark mode reads top-down (950→400), light mode reads bottom-up (50→600).
private struct ToneScale {
    let s: [Color] // 11 shades: [50, 100, 200, 300, 400, 500, 600, 700, 800, 900, 950]

    // Slate — desaturated cool gray, barely perceptible cool undertone
    static let slate = ToneScale(s: [
        h(0xF9F9FA), h(0xF3F3F4), h(0xE4E5E7), h(0xD1D3D6), h(0x989BA1),
        h(0x6F7279), h(0x50545B), h(0x3C4047), h(0x24272C), h(0x16181D), h(0x0A0B0E),
    ])
    static let zinc = ToneScale(s: [
        h(0xFAFAFA), h(0xF4F4F5), h(0xE4E4E7), h(0xD4D4D8), h(0x9F9FA9),
        h(0x71717B), h(0x52525C), h(0x3F3F46), h(0x27272A), h(0x18181B), h(0x09090B),
    ])
    static let neutral = ToneScale(s: [
        h(0xFAFAFA), h(0xF5F5F5), h(0xE5E5E5), h(0xD4D4D4), h(0xA1A1A1),
        h(0x737373), h(0x525252), h(0x404040), h(0x262626), h(0x171717), h(0x0A0A0A),
    ])
    static let stone = ToneScale(s: [
        h(0xFAFAF9), h(0xF5F5F4), h(0xE7E5E4), h(0xD6D3D1), h(0xA6A09B),
        h(0x79716B), h(0x57534D), h(0x44403B), h(0x292524), h(0x1C1917), h(0x0C0A09),
    ])

    static func forTone(_ tone: FXBaseTone) -> ToneScale {
        switch tone {
        case .slate: .slate
        case .zinc: .zinc
        case .neutral: .neutral
        case .stone: .stone
        }
    }
}

// MARK: - Semantic Palette

/// The "CSS variables" backing layer. Generated from tone + dark/light.
private struct FXPalette {
    // Backgrounds
    let bg: Color
    let bgElevated: Color
    let bgSurface: Color
    let bgHover: Color
    let bgSelected: Color
    let bgPressed: Color
    // Foregrounds
    let fg: Color
    let fgSecondary: Color
    let fgTertiary: Color
    let fgQuaternary: Color
    // Borders
    let border: Color
    let borderMedium: Color
    let borderSubtle: Color
    // Overlays
    let overlay: Color
    let overlayLight: Color
    // Contextual
    let terminalBg: Color
    // Semantic (mode-adapted)
    let success: Color
    let warning: Color
    let error: Color
    let info: Color
    // Diff (proper semantic pairs, not opacity hacks)
    let diffAddedBg: Color
    let diffRemovedBg: Color
    let diffAddedFg: Color
    let diffRemovedFg: Color
    let diffContextBg: Color

    #if canImport(AppKit)
    let windowBackground: NSColor
    #endif

    static func generate(tone: FXBaseTone, dark: Bool) -> FXPalette {
        let t = ToneScale.forTone(tone)

        if dark {
            // Dark: 900=bg, 800=elevated, 700=surface, 400=fgSecondary, 50=fg
            return FXPalette(
                bg:           t.s[9],  // 900
                bgElevated:   t.s[8],  // 800
                bgSurface:    t.s[7],  // 700
                bgHover:      Color.white.opacity(0.04),
                bgSelected:   Color.white.opacity(0.08),
                bgPressed:    Color.white.opacity(0.06),
                fg:           t.s[0],  // 50
                fgSecondary:  t.s[4],  // 400
                fgTertiary:   t.s[5],  // 500
                fgQuaternary: Color.white.opacity(0.24),
                border:       t.s[6].opacity(0.6),  // 600
                borderMedium: t.s[6],  // 600
                borderSubtle: Color.white.opacity(0.06),
                overlay:      Color.black.opacity(0.5),
                overlayLight: Color.black.opacity(0.3),
                terminalBg:   t.s[9].opacity(0.85), // 900 slightly transparent
                // Semantic — brighter on dark backgrounds
                success:      h(0x34D399),
                warning:      h(0xFBBF24),
                error:        h(0xF87171),
                info:         h(0x60A5FA),
                // Diff — muted dark backgrounds (GitHub/Codex style)
                diffAddedBg:   h(0x213A2B),
                diffRemovedBg: h(0x4A221D),
                diffAddedFg:   h(0x34D399),
                diffRemovedFg: h(0xF87171),
                diffContextBg: Color.clear,
                windowBackground: NSColor(t.s[8])
            )
        } else {
            // Light: 50=bg, 100=elevated, 200=surface, 500=fgSecondary, 900=fg
            return FXPalette(
                bg:           t.s[0],  // 50
                bgElevated:   t.s[1],  // 100
                bgSurface:    t.s[2],  // 200
                bgHover:      Color.black.opacity(0.04),
                bgSelected:   Color.black.opacity(0.08),
                bgPressed:    Color.black.opacity(0.06),
                fg:           t.s[9],  // 900
                fgSecondary:  t.s[5],  // 500
                fgTertiary:   t.s[4],  // 400
                fgQuaternary: Color.black.opacity(0.24),
                border:       t.s[3],  // 300
                borderMedium: t.s[2],  // 200
                borderSubtle: Color.black.opacity(0.05),
                overlay:      Color.black.opacity(0.18),
                overlayLight: Color.black.opacity(0.10),
                terminalBg:   t.s[1],  // 100
                // Semantic — deeper on light backgrounds
                success:      h(0x059669),
                warning:      h(0xD97706),
                error:        h(0xDC2626),
                info:         h(0x2563EB),
                // Diff — pastel light backgrounds (GitHub style)
                diffAddedBg:   h(0xDCFCE7),
                diffRemovedBg: h(0xFEE2E2),
                diffAddedFg:   h(0x166534),
                diffRemovedFg: h(0x991B1B),
                diffContextBg: Color.clear,
                windowBackground: NSColor(t.s[0])
            )
        }
    }
}

// MARK: - Theme (runtime state)

public enum FXTheme {
    nonisolated(unsafe) public static var appearanceMode: FXAppearanceMode = .dark
    nonisolated(unsafe) public static var baseTone: FXBaseTone = .zinc
    nonisolated(unsafe) public static var accentColorOption: FXAccentColorOption = .violet
    nonisolated(unsafe) public static var textSizePreset: FXTextSizePreset = .standard

    public static var preferredColorScheme: ColorScheme? {
        switch appearanceMode {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }

    public static var textScale: CGFloat { textSizePreset.scale }
    public static var accentColor: Color { accentColorOption.color }
    public static var accentHoverColor: Color { accentColorOption.hoverColor }

    public static var accentMutedColor: Color {
        accentColor.opacity(isDarkAppearance ? 0.16 : 0.12)
    }

    #if canImport(AppKit)
    public static var windowBackgroundColor: NSColor {
        currentPalette.windowBackground
    }
    #endif

    private static var isDarkAppearance: Bool {
        switch appearanceMode {
        case .dark: return true
        case .light: return false
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

    fileprivate static var currentPalette: FXPalette {
        .generate(tone: baseTone, dark: isDarkAppearance)
    }
}

// MARK: - Public Semantic Tokens

/// Every view uses these. Change tone/mode/accent → everything updates.
public enum FXColors {
    // Backgrounds
    public static var bg: Color { FXTheme.currentPalette.bg }
    public static var bgElevated: Color { FXTheme.currentPalette.bgElevated }
    public static var bgSurface: Color { FXTheme.currentPalette.bgSurface }
    public static var bgHover: Color { FXTheme.currentPalette.bgHover }
    public static var bgSelected: Color { FXTheme.currentPalette.bgSelected }
    public static var bgPressed: Color { FXTheme.currentPalette.bgPressed }

    // Foregrounds
    public static var fg: Color { FXTheme.currentPalette.fg }
    public static var fgSecondary: Color { FXTheme.currentPalette.fgSecondary }
    public static var fgTertiary: Color { FXTheme.currentPalette.fgTertiary }
    public static var fgQuaternary: Color { FXTheme.currentPalette.fgQuaternary }

    // Accents
    public static var accent: Color { FXTheme.accentColor }
    public static var accentHover: Color { FXTheme.accentHoverColor }
    public static var accentSecondary: Color { h(0x4ECDC4) }
    public static var accentMuted: Color { FXTheme.accentMutedColor }

    // Semantic (mode-adapted)
    public static var success: Color { FXTheme.currentPalette.success }
    public static var warning: Color { FXTheme.currentPalette.warning }
    public static var error: Color { FXTheme.currentPalette.error }
    public static var info: Color { FXTheme.currentPalette.info }

    // Diff (proper semantic tokens)
    public static var diffAddedBg: Color { FXTheme.currentPalette.diffAddedBg }
    public static var diffRemovedBg: Color { FXTheme.currentPalette.diffRemovedBg }
    public static var diffAddedFg: Color { FXTheme.currentPalette.diffAddedFg }
    public static var diffRemovedFg: Color { FXTheme.currentPalette.diffRemovedFg }
    public static var diffContextBg: Color { FXTheme.currentPalette.diffContextBg }

    // Borders
    public static var border: Color { FXTheme.currentPalette.border }
    public static var borderMedium: Color { FXTheme.currentPalette.borderMedium }
    public static var borderSubtle: Color { FXTheme.currentPalette.borderSubtle }

    // Overlays
    public static var overlay: Color { FXTheme.currentPalette.overlay }
    public static var overlayLight: Color { FXTheme.currentPalette.overlayLight }
}

// MARK: - Semantic Aliases

public extension FXColors {
    static var sidebarBg: Color { bgElevated }
    static var contentBg: Color { bgElevated }
    static var panelBg: Color { bgElevated }
    static var inputBg: Color { bgSurface }
    static var terminalBg: Color { FXTheme.currentPalette.terminalBg }
}

// MARK: - Hex helper

private func h(_ hex: Int) -> Color {
    Color(
        red: Double((hex >> 16) & 0xFF) / 255,
        green: Double((hex >> 8) & 0xFF) / 255,
        blue: Double(hex & 0xFF) / 255
    )
}
