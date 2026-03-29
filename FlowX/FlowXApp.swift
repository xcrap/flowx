import SwiftUI
import AppKit
import FXDesign

@main
struct FlowXApp: App {
    @State private var preferences: AppPreferences
    @State private var appState: AppState

    init() {
        let preferences = AppPreferences()
        _preferences = State(initialValue: preferences)
        _appState = State(initialValue: AppState(preferences: preferences))
    }

    var body: some Scene {
        Window("FlowX", id: "main") {
            MainLayout()
                .environment(appState)
                .environment(preferences)
                .frame(minWidth: 900, minHeight: 600)
                .tint(FXColors.accent)
                .preferredColorScheme(preferences.preferredColorScheme)
                .background(
                    WindowAccessor(
                        title: appState.windowTitle,
                        backgroundColor: preferences.windowBackgroundColor,
                        themeVersion: preferences.themeVersion
                    )
                )
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
    let title: String
    let backgroundColor: NSColor
    let themeVersion: Int

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            updateWindow(for: nsView)
        }
    }

    private func configure(_ view: NSView) {
        guard let window = view.window else { return }

        // Full size content — our views extend behind the titlebar
        window.styleMask.insert(.fullSizeContentView)

        // Transparent titlebar — no glass, no vibrancy
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        // Solid opaque background
        window.isOpaque = true
        window.backgroundColor = backgroundColor

        // Window draggable from our custom title bar area
        window.isMovableByWindowBackground = false

        // Nuke every NSVisualEffectView
        killVibrancy(in: window.contentView?.superview)
        window.title = title
    }

    private func updateWindow(for view: NSView) {
        guard let window = view.window else { return }
        if window.title != title {
            window.title = title
        }
        if window.backgroundColor != backgroundColor {
            window.backgroundColor = backgroundColor
        }
        _ = themeVersion
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
