import AppKit
import SwiftUI

public extension View {
    /// FlowX's replacement for `.contextMenu`. A right-click or control-click
    /// opens the same flat panel as `FXDropdown`, at the pointer. When context
    /// menus nest, the innermost one under the pointer that has items wins,
    /// as with native menus. Pass the same sections a row's "…" dropdown uses
    /// so the two never drift apart.
    func fxContextMenu(
        sections: [FXDropdownSection],
        width: CGFloat = FXLayout.menuWidth
    ) -> some View {
        modifier(FXContextMenuModifier(sections: sections, width: width))
    }
}

private struct FXContextMenuModifier: ViewModifier {
    let sections: [FXDropdownSection]
    let width: CGFloat

    @Environment(\.fxContextMenuScope) private var parentScope
    @State private var scope = FXContextMenuScope()

    func body(content: Content) -> some View {
        content
            .environment(\.fxContextMenuScope, scope)
            .overlay(
                FXContextMenuHitArea(
                    scope: scope,
                    parent: parentScope,
                    sections: sections,
                    width: width
                )
            )
            // A pointer-only menu is out of VoiceOver's reach, so offer the
            // same actions through the accessibility actions rotor.
            .accessibilityActions {
                ForEach(sections.flatMap(\.items).filter(\.isEnabled)) { item in
                    Button(item.title, action: item.action)
                }
            }
    }
}

extension EnvironmentValues {
    @Entry var fxContextMenuScope: FXContextMenuScope? = nil
}

/// One `.fxContextMenu` region. Scopes form a tree through the environment so
/// the outermost region hit by a click can hand off to the innermost one.
@MainActor
final class FXContextMenuScope {
    fileprivate(set) var sections: [FXDropdownSection] = []
    fileprivate(set) var width: CGFloat = FXLayout.menuWidth
    fileprivate weak var view: NSView?
    private weak var parent: FXContextMenuScope?
    private let children = NSHashTable<FXContextMenuScope>.weakObjects()

    fileprivate func attach(to view: NSView, parent: FXContextMenuScope?) {
        self.view = view
        guard parent !== self.parent else { return }
        self.parent?.children.remove(self)
        parent?.children.add(self)
        self.parent = parent
    }

    fileprivate func detach() {
        parent?.children.remove(self)
        parent = nil
        view = nil
    }

    /// The innermost scope under `screenPoint` that has something to show.
    func resolve(at screenPoint: NSPoint) -> FXContextMenuScope? {
        guard contains(screenPoint) else { return nil }
        for child in children.allObjects {
            if let match = child.resolve(at: screenPoint) {
                return match
            }
        }
        return sections.contains { !$0.items.isEmpty } ? self : nil
    }

    private func contains(_ screenPoint: NSPoint) -> Bool {
        guard let view, let window = view.window, !view.isHiddenOrHasHiddenAncestor else {
            return false
        }
        let point = view.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        // `visibleRect` handles scroll clipping, but views no longer clip to
        // their own bounds by default, so it can reach past them.
        return view.bounds.intersection(view.visibleRect).contains(point)
    }
}

extension FXDropdownPresenter {
    /// Only one context menu is open at a time, across every window.
    static let contextMenu = FXDropdownPresenter()
}

private struct FXContextMenuHitArea: NSViewRepresentable {
    let scope: FXContextMenuScope
    let parent: FXContextMenuScope?
    let sections: [FXDropdownSection]
    let width: CGFloat

    func makeNSView(context: Context) -> FXContextMenuHitView {
        let view = FXContextMenuHitView()
        view.scope = scope
        return view
    }

    func updateNSView(_ view: FXContextMenuHitView, context: Context) {
        scope.sections = sections
        scope.width = width
        scope.attach(to: view, parent: parent)
    }

    static func dismantleNSView(_ view: FXContextMenuHitView, coordinator: ()) {
        view.scope?.detach()
    }
}

/// Transparent to everything except context clicks, so hover, scrolling,
/// tooltips, drags, and ordinary clicks reach the SwiftUI content below.
final class FXContextMenuHitView: NSView {
    private static let maxMenuHeight: CGFloat = 320

    /// The event AppKit is dispatching while it hit-tests. Tests substitute a
    /// synthesized event, since posting one to the app's queue is not an option.
    static var dispatchingEvent: () -> NSEvent? = { NSApp.currentEvent }

    weak var scope: FXContextMenuScope?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = Self.dispatchingEvent(),
              Self.isContextClick(event),
              target(for: event) != nil
        else { return nil }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func rightMouseDown(with event: NSEvent) {
        if !presentMenu(for: event) {
            super.rightMouseDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if !(Self.isContextClick(event) && presentMenu(for: event)) {
            super.mouseDown(with: event)
        }
    }

    private static func isContextClick(_ event: NSEvent) -> Bool {
        event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
    }

    private func target(for event: NSEvent) -> FXContextMenuScope? {
        guard let window, event.window === window else { return nil }
        return scope?.resolve(at: window.convertPoint(toScreen: event.locationInWindow))
    }

    private func presentMenu(for event: NSEvent) -> Bool {
        guard let window, let target = target(for: event) else { return false }

        let presenter = FXDropdownPresenter.contextMenu
        presenter.present(
            at: NSEvent.mouseLocation,
            in: window,
            width: target.width,
            maxHeight: Self.maxMenuHeight,
            content: AnyView(
                FXDropdownMenu(sections: target.sections, maxHeight: Self.maxMenuHeight) {
                    presenter.dismiss()
                }
            )
        )
        return true
    }
}
