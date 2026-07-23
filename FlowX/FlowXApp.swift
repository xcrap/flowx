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
                .id(preferences.themeVersion)
                .environment(appState)
                .environment(preferences)
                .frame(minWidth: 1040, minHeight: 640)
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
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1400, height: 900)
        .commands {
            FlowXCommands(appState: appState)
        }
    }
}

/// Bridges NSWindow configuration into SwiftUI.
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
        guard let window = nsView.window else { return }
        if window.title != title { window.title = title }
        if window.backgroundColor != backgroundColor { window.backgroundColor = backgroundColor }
        _ = themeVersion
    }

    private func configure(_ view: NSView) {
        guard let window = view.window else { return }

        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = true
        window.backgroundColor = backgroundColor
        window.isMovableByWindowBackground = false

        for buttonType: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(buttonType)?.alphaValue = 0.7
        }

        killVibrancy(in: window.contentView?.superview)
        window.title = title
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
