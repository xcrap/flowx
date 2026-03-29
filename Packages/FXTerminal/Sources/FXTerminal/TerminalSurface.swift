import SwiftTerm
import SwiftUI

public struct TerminalSurface: NSViewRepresentable {
    private let session: TerminalSession

    public init(session: TerminalSession) {
        self.session = session
    }

    public func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = session.makeView()
        session.startIfNeeded()
        return view
    }

    public func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        session.updateView(nsView)
        session.startIfNeeded()
    }
}
