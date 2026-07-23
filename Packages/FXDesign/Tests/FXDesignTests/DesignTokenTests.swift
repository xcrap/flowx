import Testing
@testable import FXDesign

@Suite("FlowX design tokens")
struct DesignTokenTests {
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
