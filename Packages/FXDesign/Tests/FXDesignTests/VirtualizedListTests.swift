import AppKit
import SwiftUI
import Testing
@testable import FXDesign

@Test @MainActor func codeListOnlyBuildsVisibleRowsAndCanReachTheEnd() throws {
    _ = NSApplication.shared
    let start = ContinuousClock.now
    var builtRows = 0
    let list = FXVirtualizedList(
        count: 100_000, revision: 1, contentWidth: 600,
        scrollTarget: nil, scrollRequest: nil,
        rowHeight: { _ in 20 }, copyText: { "Full line \($0)" }
    ) { row in
        builtRows += 1
        return Text("Line \(row)")
    }
    // No window is shown. Exercise the real NSViewRepresentable and AppKit
    // recycling inside an offscreen hosting hierarchy.
    let host = NSHostingView(rootView: list)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()

    func findTable(_ view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap(findTable).first
    }
    let table = try #require(findTable(host))
    table.layoutSubtreeIfNeeded()
    #expect(table.numberOfRows == 100_000)
    _ = table.view(atColumn: 0, row: 0, makeIfNecessary: true)
    #expect(builtRows > 0)
    #expect(builtRows < 100)
    let firstScreenBuilds = builtRows
    let firstScreenDuration = start.duration(to: .now)
    table.scrollRowToVisible(99_999)
    table.layoutSubtreeIfNeeded()
    _ = table.view(atColumn: 0, row: 99_999, makeIfNecessary: true)
    #expect(builtRows - firstScreenBuilds < 100)
    #expect(table.rows(in: table.visibleRect).contains(99_999))
    let codeTable = try #require(table as? FXVirtualizedList<Text>.CodeTableView)
    #expect(codeTable.copyRows?(IndexSet([0, 99_999])) == "Full line 0\nFull line 99999")
    if ProcessInfo.processInfo.environment["FLOWX_BENCHMARK_DIFF"] == "1" {
        print("DIFF VIEWPORT: 100,000 rows; first viewport built \(firstScreenBuilds) rows in \(firstScreenDuration); end jump built \(builtRows - firstScreenBuilds) rows")
    }
    // A collapsed/refreshed document must replace recycled content and clamp
    // the old end-of-document offset, without retaining stale row callbacks.
    host.rootView = FXVirtualizedList(
        count: 3, revision: 2, contentWidth: 600,
        scrollTarget: nil, scrollRequest: nil,
        rowHeight: { _ in 20 }, copyText: { "Updated line \($0)" }
    ) { Text("Updated line \($0)") }
    host.layoutSubtreeIfNeeded()
    table.layoutSubtreeIfNeeded()
    #expect(table.numberOfRows == 3)
    #expect(codeTable.copyRows?(IndexSet([2])) == "Updated line 2")
    #expect(table.visibleRect.minY == 0)
    window.contentView = nil
}
