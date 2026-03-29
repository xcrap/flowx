import SwiftUI
import AppKit
import FXDesign

@main
struct FlowXApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        Window("FlowX", id: "main") {
            MainLayout()
                .environment(appState)
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(.dark)
                .background(WindowAccessor())
        }
        .defaultSize(width: 1400, height: 900)
        .commands {
            FlowXCommands(appState: appState)
        }
    }
}

/// Reaches into NSWindow to make the titlebar transparent and content full-size.
/// Traffic lights float on top of our custom title bar — single row, no glass.
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private func configure(_ view: NSView) {
        guard let window = view.window else { return }

        // Full size content — our views extend behind the titlebar
        window.styleMask.insert(.fullSizeContentView)

        // Transparent titlebar — no glass, no vibrancy
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        // Solid opaque background
        window.isOpaque = true
        window.backgroundColor = NSColor(red: 0.067, green: 0.067, blue: 0.075, alpha: 1)

        // Window draggable from our custom title bar area
        window.isMovableByWindowBackground = false

        // Nuke every NSVisualEffectView
        killVibrancy(in: window.contentView?.superview)
    }

    private func killVibrancy(in view: NSView?) {
        guard let view else { return }
        if let ev = view as? NSVisualEffectView {
            ev.state = .inactive
            ev.material = .windowBackground
            ev.alphaValue = 0
        }
        for sub in view.subviews { killVibrancy(in: sub) }
    }
}
