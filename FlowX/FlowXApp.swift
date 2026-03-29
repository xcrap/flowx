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
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1400, height: 900)
        .commands {
            FlowXCommands(appState: appState)
        }
    }
}

/// Invisible view injected into the titlebar container.
/// Its layout() fires every time macOS re-lays out the titlebar buttons.
private final class TrafficLightGuard: NSView {
    let barHeight: CGFloat = 44
    private var observations: [NSObjectProtocol] = []
    private var isRepositioning = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }

        let nc = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
        ]
        for name in names {
            observations.append(
                nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.repositionButtons()
                }
            )
        }
    }

    override func removeFromSuperview() {
        for obs in observations { NotificationCenter.default.removeObserver(obs) }
        observations.removeAll()
        super.removeFromSuperview()
    }

    override func layout() {
        super.layout()
        repositionButtons()
    }

    private func repositionButtons() {
        guard !isRepositioning else { return }
        isRepositioning = true
        defer { isRepositioning = false }

        guard let window,
              let close = window.standardWindowButton(.closeButton),
              let mini = window.standardWindowButton(.miniaturizeButton),
              let zoom = window.standardWindowButton(.zoomButton),
              let container = close.superview?.superview
        else { return }

        var cf = container.frame
        cf.size.height = barHeight
        cf.origin.y = window.frame.height - barHeight
        container.frame = cf

        let y = (barHeight - close.frame.height) / 2
        let spacing = mini.frame.origin.x - close.frame.origin.x

        for (i, button) in [close, mini, zoom].enumerated() {
            button.setFrameOrigin(NSPoint(x: 13 + CGFloat(i) * spacing, y: y))
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

        // Inject a layout guard into the titlebar container itself
        if let closeButton = window.standardWindowButton(.closeButton),
           let buttonContainer = closeButton.superview {
            let guard_ = TrafficLightGuard()
            guard_.frame = .zero
            buttonContainer.addSubview(guard_)
            buttonContainer.postsFrameChangedNotifications = true
        }
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
