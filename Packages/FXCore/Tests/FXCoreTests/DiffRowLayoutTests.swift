import Testing
@testable import FXCore

@Test func diffRowsMapHeadersLinesAndCollapsedFiles() {
    let layout = DiffRowLayout(lineCounts: [3, 10, 2], collapsedSections: [1])
    #expect(layout.count == 8)
    #expect(layout.headerRow(for: 0) == 0)
    #expect(layout.headerRow(for: 1) == 4)
    #expect(layout.headerRow(for: 2) == 5)
    #expect(layout.location(at: 0)?.line == nil)
    #expect(layout.location(at: 3)?.section == 0)
    #expect(layout.location(at: 3)?.line == 2)
    #expect(layout.location(at: 4)?.section == 1)
    #expect(layout.location(at: 4)?.line == nil)
    #expect(layout.location(at: 5)?.section == 2)
    #expect(layout.location(at: 7)?.line == 1)
    #expect(layout.location(at: -1) == nil)
    #expect(layout.location(at: 8) == nil)
    #expect(layout.headerRow(for: 3) == nil)
}

@Test func diffRowsHandleEmptyDocumentsAndFiles() {
    #expect(DiffRowLayout(lineCounts: [], collapsedSections: []).count == 0)
    #expect(DiffRowLayout(lineCounts: [], collapsedSections: []).location(at: 0) == nil)
    let layout = DiffRowLayout(lineCounts: [0, 0], collapsedSections: [])
    #expect(layout.count == 2)
    #expect(layout.location(at: 1)?.section == 1)
    #expect(layout.location(at: 1)?.line == nil)
}

@Test func diffRowsScaleWithFilesAcrossHugeExpandedSections() {
    let counts = Array(repeating: 100_000, count: 100)
    let expanded = DiffRowLayout(lineCounts: counts, collapsedSections: [])
    #expect(expanded.count == 10_000_100)
    #expect(expanded.location(at: expanded.count - 1)?.section == 99)
    #expect(expanded.location(at: expanded.count - 1)?.line == 99_999)
    let collapsed = DiffRowLayout(lineCounts: counts, collapsedSections: Set(0..<99))
    #expect(collapsed.count == 100_100)
    #expect(collapsed.headerRow(for: 99) == 99)
    #expect(collapsed.location(at: 100)?.line == 0)
}
