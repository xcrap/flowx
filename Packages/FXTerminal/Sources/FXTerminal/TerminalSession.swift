import AppKit
import Foundation
import SwiftTerm

@Observable
@MainActor
public final class TerminalSession {
    public let id: UUID
    public var viewIdentity = UUID()
    public var launchDirectory: String
    public var currentDirectory: String
    public var isRunning = false
    public var lastExitCode: Int32?
    public var terminalTitle: String?
    public var onChange: (() -> Void)?

    private let shellPath: String
    private var hasStartedShell = false
    private var terminalView: LocalProcessTerminalView?
    private let delegateBridge: DelegateBridge

    public init(
        id: UUID,
        currentDirectory: String = FileManager.default.currentDirectoryPath,
        shellPath: String? = nil
    ) {
        self.id = id
        launchDirectory = currentDirectory
        self.currentDirectory = currentDirectory
        self.shellPath = shellPath?.nilIfEmpty
            ?? Self.userLoginShell()
            ?? ProcessInfo.processInfo.environment["SHELL"]?.nilIfEmpty
            ?? "/bin/zsh"
        delegateBridge = DelegateBridge()
        delegateBridge.session = self
    }

    public func makeView() -> LocalProcessTerminalView {
        if let terminalView {
            configure(terminalView)
            return terminalView
        }

        let view = LocalProcessTerminalView(frame: .zero)
        view.processDelegate = delegateBridge
        configure(view)
        terminalView = view
        return view
    }

    public func updateView(_ view: LocalProcessTerminalView) {
        if terminalView !== view {
            terminalView = view
            terminalView?.processDelegate = delegateBridge
        }
        configure(view)
    }

    public func startIfNeeded() {
        guard let terminalView, !hasStartedShell else { return }

        let shellName = URL(fileURLWithPath: shellPath).lastPathComponent
        let execName = shellName.isEmpty ? nil : "-\(shellName)"
        currentDirectory = launchDirectory
        terminalView.startProcess(
            executable: shellPath,
            args: ["-il"],
            execName: execName,
            currentDirectory: launchDirectory
        )
        hasStartedShell = true
        isRunning = true
        lastExitCode = nil
        onChange?()
    }

    public func restart() {
        terminalView?.terminate()
        terminalView = nil
        hasStartedShell = false
        isRunning = false
        lastExitCode = nil
        currentDirectory = launchDirectory
        viewIdentity = UUID()
        onChange?()
    }

    public func setLaunchDirectory(_ directory: String) {
        launchDirectory = directory
        if !isRunning {
            currentDirectory = directory
        }
    }

    public func setPersistedTranscript(_ transcript: String?) {
        _ = transcript
    }

    public func snapshotTranscript() -> String? {
        nil
    }

    public func terminate() {
        guard hasStartedShell else { return }
        terminalView?.terminate()
        isRunning = false
        onChange?()
    }

    public func shutdown() {
        guard hasStartedShell else { return }
        terminalView?.terminate()
        hasStartedShell = false
        isRunning = false
        onChange?()
    }

    public func interrupt() {
        sendControlCharacter(3)
    }

    public func clearScreen() {
        sendControlCharacter(12)
    }

    public func focus() {
        guard let terminalView, let window = terminalView.window else { return }
        window.makeFirstResponder(terminalView)
    }

    private func sendControlCharacter(_ value: UInt8) {
        guard isRunning, let process = terminalView?.process else { return }
        process.send(data: [value][...])
    }

    private func configure(_ view: LocalProcessTerminalView) {
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.nativeBackgroundColor = NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.10, alpha: 1)
        view.nativeForegroundColor = NSColor(calibratedWhite: 0.90, alpha: 1)
        view.optionAsMetaKey = true
    }

    fileprivate func handleTerminalTitle(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        terminalTitle = trimmed.isEmpty ? nil : trimmed
        onChange?()
    }

    fileprivate func handleCurrentDirectory(_ directory: String?) {
        guard let directory = normalizedDirectory(from: directory),
              directory != currentDirectory else { return }
        currentDirectory = directory
        onChange?()
    }

    fileprivate func handleProcessTerminated(_ exitCode: Int32?) {
        isRunning = false
        lastExitCode = exitCode
        onChange?()
    }

    private static func userLoginShell() -> String? {
        guard let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell else { return nil }
        let path = String(cString: shell)
        return path.isEmpty ? nil : path
    }

    private func normalizedDirectory(from rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) {
            return url.path
        }

        return trimmed
    }
}

private final class DelegateBridge: LocalProcessTerminalViewDelegate {
    weak var session: TerminalSession?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor [weak session] in
            session?.handleTerminalTitle(title)
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        Task { @MainActor [weak session] in
            session?.handleCurrentDirectory(directory)
        }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor [weak session] in
            session?.handleProcessTerminated(exitCode)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
