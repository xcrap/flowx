import AppKit
import SwiftUI
import Testing
@testable import FXDesign

/// Hosts nested `.fxContextMenu` regions in an offscreen window and hit-tests
/// synthesized events, so no menu is ever presented on screen.
@Suite("FlowX context menus", .serialized)
@MainActor
struct ContextMenuTests {
    @Test("A right-click resolves to the innermost region under the pointer")
    func innermostRegionWins() throws {
        let harness = try MenuHarness.reset()
        #expect(try harness.menuWidth(for: .rightMouseDown, atTop: NSPoint(x: 50, y: 30)) == 180)
        #expect(try harness.menuWidth(for: .rightMouseDown, atTop: NSPoint(x: 250, y: 150)) == 240)
    }

    @Test("A region with no items defers to the one around it")
    func emptyRegionFallsBackToParent() throws {
        let harness = try MenuHarness.reset()
        #expect(try harness.menuWidth(for: .rightMouseDown, atTop: NSPoint(x: 50, y: 90)) == 240)
    }

    @Test("Control-click opens the menu like a right-click")
    func controlClickCounts() throws {
        let harness = try MenuHarness.reset()
        #expect(try harness.menuWidth(for: .leftMouseDown, atTop: NSPoint(x: 50, y: 30), flags: .control) == 180)
    }

    @Test("Plain clicks and hover pass through to the content")
    func otherEventsPassThrough() throws {
        let harness = try MenuHarness.reset()
        #expect(try harness.menuWidth(for: .leftMouseDown, atTop: NSPoint(x: 50, y: 30)) == nil)
        #expect(try harness.menuWidth(for: .mouseMoved, atTop: NSPoint(x: 50, y: 30)) == nil)
    }

    @Test("Content layered above a region blocks its menu")
    func occludingContentWins() throws {
        let harness = try MenuHarness.reset()
        #expect(try harness.menuWidth(for: .rightMouseDown, atTop: NSPoint(x: 350, y: 250)) == nil)
    }

    @Test("Regions follow their content when it scrolls")
    func scrolledRegionsMove() throws {
        let harness = try MenuHarness.reset()
        try harness.scrollContent(to: 100)
        #expect(try harness.menuWidth(for: .rightMouseDown, atTop: NSPoint(x: 50, y: 30)) == 240)
    }
}

@MainActor
private final class MenuHarness {
    private static let shared = MenuHarness()

    private let window: NSWindow

    /// The shared harness with its content scrolled back to the top.
    static func reset() throws -> MenuHarness {
        try shared.scrollContent(to: 0)
        return shared
    }

    private init() {
        window = NSWindow(
            contentRect: NSRect(x: -6_000, y: -6_000, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: NestedMenus())
        window.orderFrontRegardless()
        settle()
    }

    /// The width of the menu a click would open, or nil when the click does
    /// not reach a context-menu region. Widths identify regions below.
    func menuWidth(
        for kind: NSEvent.EventType,
        atTop point: NSPoint,
        flags: NSEvent.ModifierFlags = []
    ) throws -> CGFloat? {
        let location = NSPoint(x: point.x, y: window.frame.height - point.y)
        let event = try #require(NSEvent.mouseEvent(
            with: kind,
            location: location,
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        // Posting to NSApp's queue ends the test host's run loop, so hand the
        // event straight to hit-testing, as AppKit does while dispatching.
        let dispatchingEvent = FXContextMenuHitView.dispatchingEvent
        FXContextMenuHitView.dispatchingEvent = { event }
        defer { FXContextMenuHitView.dispatchingEvent = dispatchingEvent }

        let frameView = try #require(window.contentView?.superview)
        guard let hit = frameView.hitTest(location) as? FXContextMenuHitView else {
            return nil
        }
        return hit.scope?.resolve(at: window.convertPoint(toScreen: location))?.width
    }

    func scrollContent(to offset: CGFloat) throws {
        let hostingView = try #require(window.contentView)
        let scrollView = try #require(firstScrollView(in: hostingView))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        settle()
    }

    private func settle() {
        for _ in 0..<2 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        return view.subviews.lazy.compactMap(firstScrollView(in:)).first
    }
}

private struct NestedMenus: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.green
                        .frame(width: 200, height: 60)
                        .fxContextMenu(sections: sections("inner"), width: 180)
                    Color.yellow
                        .frame(width: 200, height: 60)
                        .fxContextMenu(sections: [], width: 200)
                    Color.clear
                        .frame(width: 400, height: 600)
                }
            }
            .frame(width: 400, height: 300)
            .fxContextMenu(sections: sections("outer"), width: 240)

            Color.blue
                .frame(width: 100, height: 100)
                .contentShape(Rectangle())
                .onTapGesture {}
                .offset(x: 300, y: 200)
        }
        .frame(width: 400, height: 300)
    }

    private func sections(_ id: String) -> [FXDropdownSection] {
        [FXDropdownSection(id: id, items: [FXDropdownItem(id: id, title: id) {}])]
    }
}
