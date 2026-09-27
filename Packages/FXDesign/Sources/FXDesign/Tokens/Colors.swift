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

public enum FXBaseTone: String, CaseIterable, Codable, Sendable {
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

    /// Emerald and orange are too light for white labels (2.67:1 and 2.84:1),
    /// so solid fills in those accents carry the base tone's darkest ink instead.
    public var prefersDarkForeground: Bool {
        switch self {
        case .violet, .blue, .rose: false
        case .emerald, .orange: true
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
/// Dark mode reads top-down (950→300), light mode reads bottom-up (50→600).
private struct ToneScale {
    let hex: [Int] // 11 shades: [50, 100, 200, 300, 400, 500, 600, 700, 800, 900, 950]
    let s: [Color]

    init(s hex: [Int]) {
        self.hex = hex
        self.s = hex.map(h)
    }

    /// A step between two stops, for tokens that must clear a contrast floor
    /// the nearest stop just misses. `amount` 0 is `from`, 1 is `to`.
    func mix(_ from: Int, _ to: Int, _ amount: Double) -> Color {
        let a = hex[from], b = hex[to]
        func channel(_ shift: Int) -> Int {
            let lhs = Double((a >> shift) & 0xFF), rhs = Double((b >> shift) & 0xFF)
            return Int((lhs + (rhs - lhs) * amount).rounded())
        }
        return h((channel(16) << 16) | (channel(8) << 8) | channel(0))
    }

    // Slate — desaturated cool gray, barely perceptible cool undertone
    static let slate = ToneScale(s: [
        0xF9F9FA, 0xF3F3F4, 0xE4E5E7, 0xD1D3D6, 0x989BA1,
        0x6F7279, 0x50545B, 0x3C4047, 0x24272C, 0x16181D, 0x0A0B0E,
    ])
    static let zinc = ToneScale(s: [
        0xFAFAFA, 0xF4F4F5, 0xE4E4E7, 0xD4D4D8, 0x9F9FA9,
        0x71717B, 0x52525C, 0x3F3F46, 0x27272A, 0x18181B, 0x09090B,
    ])
    static let neutral = ToneScale(s: [
        0xFAFAFA, 0xF5F5F5, 0xE5E5E5, 0xD4D4D4, 0xA1A1A1,
        0x737373, 0x525252, 0x404040, 0x262626, 0x171717, 0x0A0A0A,
    ])
    static let stone = ToneScale(s: [
        0xFAFAF9, 0xF5F5F4, 0xE7E5E4, 0xD6D3D1, 0xA6A09B,
        0x79716B, 0x57534D, 0x44403B, 0x292524, 0x1C1917, 0x0C0A09,
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
private struct FXPalette: Sendable {
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
    // Accents (mode-adapted; the primary accent is user-chosen and fixed)
    let accentSecondary: Color
    let accentSecondaryMuted: Color
    let onAccentDark: Color
    // Semantic (mode-adapted)
    let success: Color
    let warning: Color
    let error: Color
    let info: Color
    let successMuted: Color
    let warningMuted: Color
    let errorMuted: Color
    let infoMuted: Color
    // Diff (proper semantic pairs, not opacity hacks)
    let diffAddedBg: Color
    let diffRemovedBg: Color
    let diffAddedFg: Color
    let diffRemovedFg: Color
    let diffContextBg: Color

    #if canImport(AppKit)
    let windowBackground: NSColor
    #endif

    // There are only eight tone/appearance combinations. Generate each once,
    // instead of rebuilding every semantic color and bridging an NSColor for
    // every FXColors token read throughout a view's body.
    private static let palettes: [FXBaseTone: (light: FXPalette, dark: FXPalette)] =
        Dictionary(uniqueKeysWithValues: FXBaseTone.allCases.map { tone in
            (tone, (light: generate(tone: tone, dark: false), dark: generate(tone: tone, dark: true)))
        })

    static func cached(tone: FXBaseTone, dark: Bool) -> FXPalette {
        let pair = palettes[tone]!
        return dark ? pair.dark : pair.light
    }

    static func generate(tone: FXBaseTone, dark: Bool) -> FXPalette {
        let t = ToneScale.forTone(tone)

        // Semantic hues — brighter on dark backgrounds, deeper on light ones.
        let success = dark ? h(0x34D399) : h(0x059669)
        let warning = dark ? h(0xFBBF24) : h(0xD97706)
        let error = dark ? h(0xF87171) : h(0xDC2626)
        let info = dark ? h(0x60A5FA) : h(0x2563EB)
        // Teal secondary accent; the light value is teal-700 so it stays
        // readable as text (#4ECDC4 is 1.76:1 on a light surface).
        let accentSecondary = dark ? h(0x4ECDC4) : h(0x0F766E)
        // Tinted backgrounds under same-hue text or icons. Dark surfaces
        // absorb more of the tint, so they get a little more alpha.
        let statusTint = dark ? 0.14 : 0.10
        let accentTint = dark ? 0.16 : 0.12

        if dark {
            // Dark: 900=bg, 800=elevated, 700=surface, 50=fg, 300=fgSecondary, 400=fgTertiary
            return FXPalette(
                bg:           t.s[9],  // 900
                bgElevated:   t.s[8],  // 800
                bgSurface:    t.s[7],  // 700
                bgHover:      Color.white.opacity(0.04),
                bgSelected:   Color.white.opacity(0.08),
                bgPressed:    Color.white.opacity(0.06),
                fg:           t.s[0],  // 50
                fgSecondary:  t.s[3],  // 300
                fgTertiary:   t.s[4],  // 400
                fgQuaternary: Color.white.opacity(0.24),
                border:       t.s[6].opacity(0.6),  // 600
                borderMedium: t.s[6],  // 600
                borderSubtle: Color.white.opacity(0.06),
                overlay:      Color.black.opacity(0.5),
                overlayLight: Color.black.opacity(0.3),
                terminalBg:   t.s[9].opacity(0.85), // 900 slightly transparent
                accentSecondary:      accentSecondary,
                accentSecondaryMuted: accentSecondary.opacity(accentTint),
                onAccentDark:         t.s[10], // 950
                success:      success,
                warning:      warning,
                error:        error,
                info:         info,
                successMuted: success.opacity(statusTint),
                warningMuted: warning.opacity(statusTint),
                errorMuted:   error.opacity(statusTint),
                infoMuted:    info.opacity(statusTint),
                // Diff — muted dark backgrounds (GitHub/Codex style)
                diffAddedBg:   h(0x213A2B),
                diffRemovedBg: h(0x4A221D),
                diffAddedFg:   h(0x34D399),
                diffRemovedFg: h(0xF87171),
                diffContextBg: Color.clear,
                windowBackground: NSColor(t.s[8])
            )
        } else {
            // Light: 50=bg, 100=elevated, 200=surface, 900=fg, 600=fgSecondary, ~500=fgTertiary
            return FXPalette(
                bg:           t.s[0],  // 50
                bgElevated:   t.s[1],  // 100
                bgSurface:    t.s[2],  // 200
                bgHover:      Color.black.opacity(0.04),
                bgSelected:   Color.black.opacity(0.08),
                bgPressed:    Color.black.opacity(0.06),
                fg:           t.s[9],  // 900
                fgSecondary:  t.s[6],  // 600
                // 500 alone lands at ~4.35:1 on elevated; a touch of 600 clears AA.
                fgTertiary:   t.mix(5, 6, 0.15),
                fgQuaternary: Color.black.opacity(0.24),
                border:       t.s[3],  // 300
                borderMedium: t.s[2],  // 200
                borderSubtle: Color.black.opacity(0.05),
                overlay:      Color.black.opacity(0.18),
                overlayLight: Color.black.opacity(0.10),
                terminalBg:   t.s[1],  // 100
                accentSecondary:      accentSecondary,
                accentSecondaryMuted: accentSecondary.opacity(accentTint),
                onAccentDark:         t.s[10], // 950
                success:      success,
                warning:      warning,
                error:        error,
                info:         info,
                successMuted: success.opacity(statusTint),
                warningMuted: warning.opacity(statusTint),
                errorMuted:   error.opacity(statusTint),
                infoMuted:    info.opacity(statusTint),
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
        .cached(tone: baseTone, dark: isDarkAppearance)
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

    // Foregrounds — each step keeps AA (4.5:1) text contrast on `bg` and
    // `bgElevated`; `fgTertiary` still clears 3:1 on `bgSurface`.
    public static var fg: Color { FXTheme.currentPalette.fg }
    public static var fgSecondary: Color { FXTheme.currentPalette.fgSecondary }
    public static var fgTertiary: Color { FXTheme.currentPalette.fgTertiary }
    /// Disabled states and purely decorative glyphs only (~2:1). Never use it
    /// for text or for the only icon inside a control; use `fgTertiary`.
    public static var fgQuaternary: Color { FXTheme.currentPalette.fgQuaternary }

    // Accents
    public static var accent: Color { FXTheme.accentColor }
    public static var accentHover: Color { FXTheme.accentHoverColor }
    /// Foreground used on a solid accent fill: white, or the base tone's
    /// darkest ink for accents too light to carry white text.
    public static var onAccent: Color {
        FXTheme.accentColorOption.prefersDarkForeground ? FXTheme.currentPalette.onAccentDark : Color.white
    }
    public static var accentSecondary: Color { FXTheme.currentPalette.accentSecondary }
    public static var accentMuted: Color { FXTheme.accentMutedColor }
    public static var accentSecondaryMuted: Color { FXTheme.currentPalette.accentSecondaryMuted }

    // Semantic (mode-adapted)
    public static var success: Color { FXTheme.currentPalette.success }
    public static var warning: Color { FXTheme.currentPalette.warning }
    public static var error: Color { FXTheme.currentPalette.error }
    public static var info: Color { FXTheme.currentPalette.info }

    // Semantic tints for banners, badges, and highlighted rows. Use these
    // instead of `warning.opacity(…)` and friends.
    public static var successMuted: Color { FXTheme.currentPalette.successMuted }
    public static var warningMuted: Color { FXTheme.currentPalette.warningMuted }
    public static var errorMuted: Color { FXTheme.currentPalette.errorMuted }
    public static var infoMuted: Color { FXTheme.currentPalette.infoMuted }

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
