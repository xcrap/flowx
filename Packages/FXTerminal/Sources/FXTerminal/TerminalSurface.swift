import SwiftTerm
import SwiftUI
import FXDesign

/// Keeps SwiftTerm's layer-backed drawing inside the pane SwiftUI allocated.
/// Returning the terminal view directly from NSViewRepresentable can promote
/// its backing surface above sibling SwiftUI content on macOS, visually
/// covering the transcript even though both views have correct frames.
public final class TerminalClippingHostView: NSView {
    public let terminalView: LocalProcessTerminalView
    var onAttachedToWindow: ((LocalProcessTerminalView) -> Void)?
    private weak var activatedWindow: NSWindow?

    public override var isFlipped: Bool { true }

    init(terminalView: LocalProcessTerminalView) {
        self.terminalView = terminalView
        super.init(frame: .zero)

        wantsLayer = true
        clipsToBounds = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(FXColors.terminalBg).cgColor
        terminalView.removeFromSuperview()
        terminalView.autoresizingMask = [.width, .height]
        addSubview(terminalView)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func layout() {
        super.layout()
        if terminalView.frame != bounds {
            terminalView.frame = bounds
        }
        activateIfAttached()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            activatedWindow = nil
        }
        activateIfAttached()
    }

    fileprivate func activateIfAttached() {
        guard let window,
              terminalView.window === window,
              bounds.width > 0,
              bounds.height > 0,
              activatedWindow !== window else { return }
        activatedWindow = window
        onAttachedToWindow?(terminalView)
    }

    func detachTerminal() {
        guard terminalView.superview === self else { return }
        terminalView.removeFromSuperview()
    }
}

public struct TerminalSurface: NSViewRepresentable {
    private let session: TerminalSession

    public final class Coordinator {}

    public init(session: TerminalSession) {
        self.session = session
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeNSView(context: Context) -> TerminalClippingHostView {
        let view = session.makeView()
        let host = TerminalClippingHostView(terminalView: view)
        connect(host)
        return host
    }

    public func updateNSView(_ nsView: TerminalClippingHostView, context: Context) {
        connect(nsView)
        session.updateView(nsView.terminalView)
        nsView.activateIfAttached()
    }

    public static func dismantleNSView(
        _ nsView: TerminalClippingHostView,
        coordinator: Coordinator
    ) {
        nsView.onAttachedToWindow = nil
        nsView.detachTerminal()
    }

    private func connect(_ host: TerminalClippingHostView) {
        let session = session
        host.onAttachedToWindow = { [weak session] view in
            guard let session else { return }
            session.updateView(view)
            session.startIfNeeded()
        }
    }
}
