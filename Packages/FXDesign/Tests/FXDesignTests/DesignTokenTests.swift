import Testing
import SwiftUI
@testable import FXDesign

@Suite("FlowX design tokens")
struct DesignTokenTests {
    @Test("Cached palettes follow tone and appearance changes")
    @MainActor func palettesFollowThemeChanges() {
        let originalTone = FXTheme.baseTone
        let originalAppearance = FXTheme.appearanceMode
        defer {
            FXTheme.baseTone = originalTone
            FXTheme.appearanceMode = originalAppearance
        }
        for tone in FXBaseTone.allCases {
            FXTheme.baseTone = tone
            FXTheme.appearanceMode = .dark
            let darkBackground = FXColors.bg
            let darkDiff = FXColors.diffAddedBg
            FXTheme.appearanceMode = .light
            #expect(FXColors.bg != darkBackground)
            #expect(FXColors.diffAddedBg != darkDiff)
            FXTheme.appearanceMode = .dark
            #expect(FXColors.bg == darkBackground)
            #expect(FXColors.diffAddedBg == darkDiff)
        }
        FXTheme.baseTone = .zinc
        let zinc = FXColors.bg
        FXTheme.baseTone = .stone
        #expect(FXColors.bg != zinc)
    }

    @Test("Text tokens keep WCAG contrast and their hierarchy in every tone and mode")
    @MainActor func textTokensMeetContrastFloors() {
        let originalTone = FXTheme.baseTone
        let originalAppearance = FXTheme.appearanceMode
        defer {
            FXTheme.baseTone = originalTone
            FXTheme.appearanceMode = originalAppearance
        }
        #expect(abs(contrast(.white, on: .black) - 21) < 0.01)

        for tone in FXBaseTone.allCases {
            for appearance in [FXAppearanceMode.light, .dark] {
                FXTheme.baseTone = tone
                FXTheme.appearanceMode = appearance
                let theme = "\(tone) \(appearance)"

                // Captions, section headers, and dropdown subtitles sit on the
                // window and panel surfaces, so every text step needs AA there.
                for (surface, background) in [("bg", FXColors.bg), ("bgElevated", FXColors.bgElevated)] {
                    let floors: [(String, Color, Double)] = [
                        ("fg", FXColors.fg, 7),
                        ("fgSecondary", FXColors.fgSecondary, 4.5),
                        ("fgTertiary", FXColors.fgTertiary, 4.5),
                        ("accentSecondary", FXColors.accentSecondary, 4.5),
                    ]
                    for (token, color, floor) in floors {
                        let ratio = contrast(color, on: background)
                        #expect(ratio >= floor, "\(theme): \(token) on \(surface) is \(ratio)")
                    }
                }

                // Menus, cards, and inputs use bgSurface. Tertiary text there is
                // secondary information, so it only has to clear 3:1.
                let surface = FXColors.bgSurface
                #expect(contrast(FXColors.fgSecondary, on: surface) >= 4.5, "\(theme): fgSecondary on bgSurface")
                #expect(contrast(FXColors.fgTertiary, on: surface) >= 3, "\(theme): fgTertiary on bgSurface")

                let ladder = [FXColors.fg, FXColors.fgSecondary, FXColors.fgTertiary, FXColors.fgQuaternary]
                    .map { contrast($0, on: FXColors.bgElevated) }
                #expect(
                    zip(ladder, ladder.dropFirst()).allSatisfy { $0 > $1 },
                    "\(theme): foreground steps are out of order \(ladder)"
                )
            }
        }
    }

    @Test("Labels on solid accent fills stay legible for every accent")
    @MainActor func onAccentStaysLegible() {
        let originalTone = FXTheme.baseTone
        let originalAppearance = FXTheme.appearanceMode
        let originalAccent = FXTheme.accentColorOption
        defer {
            FXTheme.baseTone = originalTone
            FXTheme.appearanceMode = originalAppearance
            FXTheme.accentColorOption = originalAccent
        }

        for accent in FXAccentColorOption.allCases {
            FXTheme.accentColorOption = accent
            for tone in FXBaseTone.allCases {
                for appearance in [FXAppearanceMode.light, .dark] {
                    FXTheme.baseTone = tone
                    FXTheme.appearanceMode = appearance
                    let ratio = contrast(FXColors.onAccent, on: FXColors.accent)
                    #expect(ratio >= 3, "\(accent) \(tone) \(appearance): onAccent is \(ratio)")
                }
            }
            // Dark ink is reserved for accents that cannot carry white.
            let white = contrast(.white, on: accent.color)
            #expect(accent.prefersDarkForeground == (white < 3), "\(accent): white is \(white)")
        }
    }

    @Test("Status tints adapt to the appearance mode")
    @MainActor func mutedTintsFollowAppearance() {
        let originalAppearance = FXTheme.appearanceMode
        defer { FXTheme.appearanceMode = originalAppearance }

        FXTheme.appearanceMode = .light
        let light = [FXColors.successMuted, FXColors.warningMuted, FXColors.errorMuted, FXColors.infoMuted, FXColors.accentSecondaryMuted]
        FXTheme.appearanceMode = .dark
        let dark = [FXColors.successMuted, FXColors.warningMuted, FXColors.errorMuted, FXColors.infoMuted, FXColors.accentSecondaryMuted]
        #expect(zip(light, dark).allSatisfy { $0 != $1 })
        #expect(Set(dark.map { "\($0)" }).count == dark.count)
    }

    @Test("Border widths stay ordered from hairline to strong")
    func borderWidthsAreOrdered() {
        let values = [FXBorderWidth.hairline, FXBorderWidth.regular, FXBorderWidth.strong]
        #expect(zip(values, values.dropFirst()).allSatisfy { lhs, rhs in lhs < rhs })
    }

    @Test("Spacing remains a strictly increasing shared scale")
    func spacingScaleIsOrdered() {
        let values = [
            FXSpacing.xxxs,
            FXSpacing.xxs,
            FXSpacing.xs,
            FXSpacing.sm,
            FXSpacing.md,
            FXSpacing.lg,
            FXSpacing.xl,
            FXSpacing.xxl,
            FXSpacing.xxxl,
            FXSpacing.huge,
        ]

        #expect(zip(values, values.dropFirst()).allSatisfy { lhs, rhs in lhs < rhs })
    }

    @Test("Corner radii remain ordered from compact to spacious")
    func radiusScaleIsOrdered() {
        let values = [FXRadii.xs, FXRadii.sm, FXRadii.md, FXRadii.lg, FXRadii.xl, FXRadii.xxl]
        #expect(zip(values, values.dropFirst()).allSatisfy { lhs, rhs in lhs < rhs })
    }

    @Test("Text presets increase predictably and have unique labels")
    func textPresetsAreCoherent() {
        let presets = FXTextSizePreset.allCases
        #expect(zip(presets, presets.dropFirst()).allSatisfy { lhs, rhs in lhs.scale < rhs.scale })
        #expect(Set(presets.map(\.label)).count == presets.count)
    }

    @Test("Dropdown item preserves selection and invokes its action")
    func dropdownItemSemantics() {
        var invoked = false
        let item = FXDropdownItem(
            id: "model",
            title: "Model",
            subtitle: "Dynamic catalog entry",
            isSelected: true
        ) {
            invoked = true
        }

        #expect(item.id == "model")
        #expect(item.isSelected)
        #expect(item.isEnabled)
        item.action()
        #expect(invoked)
    }
}

/// WCAG 2 contrast ratio. Translucent foregrounds are composited over the
/// (opaque) background first, the way they render.
@MainActor
private func contrast(_ foreground: Color, on background: Color) -> Double {
    let environment = EnvironmentValues()
    let front = foreground.resolve(in: environment)
    let back = background.resolve(in: environment)
    let alpha = Double(front.opacity)

    func blend(_ top: Float, _ bottom: Float) -> Double {
        Double(top) * alpha + Double(bottom) * (1 - alpha)
    }

    let lighter = relativeLuminance(blend(front.red, back.red), blend(front.green, back.green), blend(front.blue, back.blue))
    let darker = relativeLuminance(Double(back.red), Double(back.green), Double(back.blue))
    return (max(lighter, darker) + 0.05) / (min(lighter, darker) + 0.05)
}

private func relativeLuminance(_ red: Double, _ green: Double, _ blue: Double) -> Double {
    func linear(_ channel: Double) -> Double {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
}
