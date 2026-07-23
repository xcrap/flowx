import Foundation
import Testing
@testable import FXTerminal

@Suite("Terminal session")
@MainActor
struct TerminalSessionTests {
    @Test("Launch paths are standardized")
    func standardizesLaunchPath() {
        let session = TerminalSession(
            id: UUID(),
            currentDirectory: "/tmp/../tmp/"
        )

        #expect(session.launchDirectory == "/tmp")
        #expect(session.currentDirectory == "/tmp")
    }

    @Test("Missing workspace paths safely fall back to the home directory")
    func fallsBackForMissingWorkspace() {
        let session = TerminalSession(id: UUID(), currentDirectory: "/tmp")

        session.setLaunchDirectory("/flowx-tests/path-that-does-not-exist")

        #expect(session.currentDirectory == NSHomeDirectory())
    }

    @Test("Restart invalidates the hosted terminal view")
    func restartInvalidatesView() {
        let session = TerminalSession(id: UUID(), currentDirectory: "/tmp")
        let originalIdentity = session.viewIdentity

        session.restart()

        #expect(session.viewIdentity != originalIdentity)
        #expect(session.isRunning == false)
        #expect(session.lastExitCode == nil)
    }

    @Test("Late callbacks from a restarted terminal view are ignored")
    func ignoresCallbacksFromRestartedView() async {
        let session = TerminalSession(id: UUID(), currentDirectory: "/tmp")
        let oldView = session.makeView()

        session.restart()
        let replacementView = session.makeView()
        oldView.processDelegate?.setTerminalTitle(source: oldView, title: "stale")
        oldView.processDelegate?.hostCurrentDirectoryUpdate(source: oldView, directory: "/")
        oldView.processDelegate?.processTerminated(source: oldView, exitCode: 99)
        await Task.yield()

        #expect(session.terminalTitle == nil)
        #expect(session.currentDirectory == "/tmp")
        #expect(session.lastExitCode == nil)

        replacementView.processDelegate?.setTerminalTitle(source: replacementView, title: "current")
        replacementView.processDelegate?.hostCurrentDirectoryUpdate(source: replacementView, directory: "/")
        replacementView.processDelegate?.processTerminated(source: replacementView, exitCode: 0)
        await Task.yield()

        #expect(session.terminalTitle == "current")
        #expect(session.currentDirectory == "/")
        #expect(session.lastExitCode == 0)
    }
}
