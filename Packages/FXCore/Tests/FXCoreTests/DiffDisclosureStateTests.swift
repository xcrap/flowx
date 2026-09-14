import Testing
@testable import FXCore

@Test func bulkDiffDisclosureAppliesToCurrentAndNewFiles() {
    var state = DiffDisclosureState()
    #expect(!state.isCollapsed("a.swift"))
    state.setAllCollapsed(true)
    #expect(state.isCollapsed("a.swift"))
    #expect(state.isCollapsed("new-file.swift"))
    state.setAllCollapsed(false)
    #expect(!state.isCollapsed("a.swift"))
    #expect(!state.isCollapsed("new-file.swift"))
}

@Test func navigatingFromCollapsedOverviewOpensOnlyTheChosenFile() {
    var state = DiffDisclosureState()
    state.setAllCollapsed(true)
    state.setCollapsed(false, for: "chosen.swift")
    #expect(!state.isCollapsed("chosen.swift"))
    #expect(state.isCollapsed("other.swift"))
    state.toggle("chosen.swift")
    #expect(state.isCollapsed("chosen.swift"))
    state.setAllCollapsed(false)
    state.toggle("other.swift")
    #expect(state.isCollapsed("other.swift"))
    state.setAllCollapsed(false)
    #expect(!state.isCollapsed("other.swift"))
}

@Test func bulkDisclosureProducesOnlyHeaderRowsUntilANavigatorSelection() {
    var state = DiffDisclosureState()
    let ids = ["a.swift", "b.swift", "c.swift"]
    state.setAllCollapsed(true)
    func layout() -> DiffRowLayout {
        DiffRowLayout(lineCounts: [100_000, 100_000, 100_000],
                      collapsedSections: Set(ids.indices.filter { state.isCollapsed(ids[$0]) }))
    }
    #expect(layout().count == 3)
    state.setCollapsed(false, for: "b.swift")
    #expect(layout().count == 100_003)
    #expect(layout().headerRow(for: 1) == 1)
    #expect(layout().headerRow(for: 2) == 100_002)
}
