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

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(view, coordinator: context.coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        configureAppearance(window)
        context.coordinator.attach(to: window)
    }

    private func configure(_ view: NSView, coordinator: Coordinator) {
        guard let window = view.window else { return }
        configureAppearance(window)
        coordinator.attach(to: window)
    }

    private func configureAppearance(_ window: NSWindow) {
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

    @MainActor
    final class Coordinator: NSObject {
        private weak var window: NSWindow?

        func attach(to window: NSWindow) {
            guard self.window !== window else { return }
            NotificationCenter.default.removeObserver(self)
            self.window = window

            if !MainWindowPlacementStore.restore(window) {
                MainWindowPlacementStore.save(window)
            }

            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(windowFrameChanged(_:)),
                name: NSWindow.didMoveNotification,
                object: window
            )
            center.addObserver(
                self,
                selector: #selector(windowFrameChanged(_:)),
                name: NSWindow.didResizeNotification,
                object: window
            )
            center.addObserver(
                self,
                selector: #selector(windowFrameChanged(_:)),
                name: NSWindow.didChangeScreenNotification,
                object: window
            )
            center.addObserver(
                self,
                selector: #selector(windowWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: window
            )
        }

        @objc private func windowFrameChanged(_ notification: Notification) {
            _ = notification
            NSObject.cancelPreviousPerformRequests(
                withTarget: self,
                selector: #selector(saveImmediately),
                object: nil
            )
            perform(#selector(saveImmediately), with: nil, afterDelay: 0.2)
        }

        @objc private func windowWillClose(_ notification: Notification) {
            _ = notification
            saveImmediately()
        }

        @objc private func saveImmediately() {
            NSObject.cancelPreviousPerformRequests(
                withTarget: self,
                selector: #selector(saveImmediately),
                object: nil
            )
            guard let window else { return }
            MainWindowPlacementStore.save(window)
        }

        deinit {
            NSObject.cancelPreviousPerformRequests(withTarget: self)
            NotificationCenter.default.removeObserver(self)
        }
    }
}

@MainActor
private enum MainWindowPlacementStore {
    private struct Placement: Codable {
        let displayID: UInt32?
        let absoluteX: Double
        let absoluteY: Double
        let width: Double
        let height: Double
        let offsetFromVisibleLeft: Double
        let offsetFromVisibleTop: Double
    }

    private static let defaultsKey = "FlowX.mainWindowPlacement.v1"

    static func restore(_ window: NSWindow) -> Bool {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let placement = try? JSONDecoder().decode(Placement.self, from: data) else {
            return false
        }

        let targetScreen = placement.displayID.flatMap(screen(with:))
            ?? bestScreen(for: NSRect(
                x: CGFloat(placement.absoluteX),
                y: CGFloat(placement.absoluteY),
                width: CGFloat(placement.width),
                height: CGFloat(placement.height)
            ))
        guard let targetScreen else { return false }

        let visibleFrame = targetScreen.visibleFrame
        let minimumWidth = min(window.minSize.width, visibleFrame.width)
        let minimumHeight = min(window.minSize.height, visibleFrame.height)
        let width = min(max(CGFloat(placement.width), minimumWidth), visibleFrame.width)
        let height = min(max(CGFloat(placement.height), minimumHeight), visibleFrame.height)

        let proposedX: CGFloat
        let proposedY: CGFloat
        if placement.displayID == displayID(for: targetScreen) {
            proposedX = visibleFrame.minX + CGFloat(placement.offsetFromVisibleLeft)
            proposedY = visibleFrame.maxY - CGFloat(placement.offsetFromVisibleTop) - height
        } else {
            proposedX = CGFloat(placement.absoluteX)
            proposedY = CGFloat(placement.absoluteY)
        }

        let restoredFrame = NSRect(
            x: clamp(proposedX, lower: visibleFrame.minX, upper: visibleFrame.maxX - width),
            y: clamp(proposedY, lower: visibleFrame.minY, upper: visibleFrame.maxY - height),
            width: width,
            height: height
        )
        window.setFrame(restoredFrame, display: false)
        return true
    }

    static func save(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen),
              let screen = window.screen ?? bestScreen(for: window.frame) else {
            return
        }

        let visibleFrame = screen.visibleFrame
        let frame = window.frame
        let placement = Placement(
            displayID: displayID(for: screen),
            absoluteX: Double(frame.minX),
            absoluteY: Double(frame.minY),
            width: Double(frame.width),
            height: Double(frame.height),
            offsetFromVisibleLeft: Double(frame.minX - visibleFrame.minX),
            offsetFromVisibleTop: Double(visibleFrame.maxY - frame.maxY)
        )
        guard let data = try? JSONEncoder().encode(placement) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private static func screen(with displayID: UInt32) -> NSScreen? {
        NSScreen.screens.first { self.displayID(for: $0) == displayID }
    }

    private static func displayID(for screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value
    }

    private static func bestScreen(for frame: NSRect) -> NSScreen? {
        NSScreen.screens.max { lhs, rhs in
            lhs.visibleFrame.intersection(frame).area
                < rhs.visibleFrame.intersection(frame).area
        } ?? NSScreen.main
    }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        guard upper >= lower else { return lower }
        return min(max(value, lower), upper)
    }
}

private extension NSRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }
}
