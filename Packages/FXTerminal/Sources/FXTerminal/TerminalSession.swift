import AppKit
import Foundation
import FXDesign
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
    public private(set) var launchError: String?
    public private(set) var isUsingAcceleratedRenderer = false
    public var onChange: (() -> Void)?

    private let shellPath: String
    private var hasStartedShell = false
    private var terminalView: LocalProcessTerminalView?
    private var terminalGeneration = UUID()
    private let delegateBridge: DelegateBridge

    public init(
        id: UUID,
        currentDirectory: String = FileManager.default.currentDirectoryPath,
        shellPath: String? = nil
    ) {
        self.id = id
        let normalizedDirectory = Self.normalizedDirectory(currentDirectory)
        launchDirectory = normalizedDirectory
        self.currentDirectory = normalizedDirectory
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
            enableAcceleratedRendererIfPossible(on: terminalView)
            return terminalView
        }

        let view = LocalProcessTerminalView(frame: .zero)
        view.processDelegate = delegateBridge
        configure(view)
        enableAcceleratedRendererIfPossible(on: view)
        terminalView = view
        delegateBridge.activate(source: view, generation: terminalGeneration)
        return view
    }

    public func updateView(_ view: LocalProcessTerminalView) {
        if terminalView !== view {
            terminalGeneration = UUID()
            terminalView = view
            terminalView?.processDelegate = delegateBridge
        }
        delegateBridge.activate(source: view, generation: terminalGeneration)
        configure(view)
        enableAcceleratedRendererIfPossible(on: view)
    }

    public func startIfNeeded() {
        guard let terminalView, !hasStartedShell else { return }

        guard FileManager.default.isExecutableFile(atPath: shellPath) else {
            launchError = "The login shell is unavailable: \(shellPath)"
            lastExitCode = 127
            isRunning = false
            onChange?()
            return
        }

        let shellName = URL(fileURLWithPath: shellPath).lastPathComponent
        let execName = shellName.isEmpty ? nil : "-\(shellName)"
        let resolvedDirectory = resolvedLaunchDirectory()
        currentDirectory = resolvedDirectory
        launchError = resolvedDirectory == launchDirectory
            ? nil
            : "Workspace path is unavailable. The terminal opened in \(resolvedDirectory)."
        terminalView.startProcess(
            executable: shellPath,
            args: ["-il"],
            execName: execName,
            currentDirectory: resolvedDirectory
        )
        hasStartedShell = true
        isRunning = true
        lastExitCode = nil
        onChange?()
    }

    public func restart() {
        terminalGeneration = UUID()
        delegateBridge.deactivate()
        terminalView?.terminate()
        terminalView = nil
        hasStartedShell = false
        isRunning = false
        lastExitCode = nil
        currentDirectory = resolvedLaunchDirectory()
        launchError = nil
        viewIdentity = UUID()
        onChange?()
    }

    public func setLaunchDirectory(_ directory: String) {
        launchDirectory = Self.normalizedDirectory(directory)
        if !isRunning {
            currentDirectory = resolvedLaunchDirectory()
        }
    }

    public func terminate() {
        guard hasStartedShell else { return }
        terminalView?.terminate()
        isRunning = false
        onChange?()
    }

    public func shutdown() {
        guard hasStartedShell else { return }
        delegateBridge.deactivate()
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
        let targetFont = NSFont.monospacedSystemFont(
            ofSize: FXTypography.terminalPointSize,
            weight: .regular
        )
        if view.font.fontName != targetFont.fontName
            || abs(view.font.pointSize - targetFont.pointSize) > 0.01 {
            view.font = targetFont
        }

        let targetBackgroundColor = NSColor(FXColors.terminalBg)
        if !view.nativeBackgroundColor.isEqual(targetBackgroundColor) {
            view.nativeBackgroundColor = targetBackgroundColor
        }

        let targetForegroundColor = NSColor(FXColors.fg)
        if !view.nativeForegroundColor.isEqual(targetForegroundColor) {
            view.nativeForegroundColor = targetForegroundColor
        }

        if !view.optionAsMetaKey {
            view.optionAsMetaKey = true
        }
    }

    private func enableAcceleratedRendererIfPossible(on view: LocalProcessTerminalView) {
        guard view.window != nil else { return }
        if view.isUsingMetalRenderer {
            isUsingAcceleratedRenderer = true
            return
        }

        do {
            try view.setUseMetal(true)
            isUsingAcceleratedRenderer = true
        } catch {
            isUsingAcceleratedRenderer = false
        }
    }

    func handleTerminalTitle(_ title: String, generation: UUID) {
        guard generation == terminalGeneration else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        terminalTitle = trimmed.isEmpty ? nil : trimmed
        onChange?()
    }

    func handleCurrentDirectory(_ directory: String?, generation: UUID) {
        guard generation == terminalGeneration else { return }
        guard let directory = normalizedDirectory(from: directory),
              directory != currentDirectory else { return }
        currentDirectory = directory
        onChange?()
    }

    func handleProcessTerminated(_ exitCode: Int32?, generation: UUID) {
        guard generation == terminalGeneration else { return }
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
            return Self.normalizedDirectory(url.path)
        }

        return Self.normalizedDirectory(trimmed)
    }

    private func resolvedLaunchDirectory() -> String {
        let candidate = Self.normalizedDirectory(launchDirectory)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return candidate
        }
        return NSHomeDirectory()
    }

    private static func normalizedDirectory(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
    }
}

private final class DelegateBridge: LocalProcessTerminalViewDelegate {
    private struct ActiveSource {
        var identifier: ObjectIdentifier
        var generation: UUID
    }

    weak var session: TerminalSession?
    private let sourceLock = NSLock()
    private var activeSource: ActiveSource?

    func activate(source: LocalProcessTerminalView, generation: UUID) {
        sourceLock.lock()
        activeSource = ActiveSource(identifier: ObjectIdentifier(source), generation: generation)
        sourceLock.unlock()
    }

    func deactivate() {
        sourceLock.lock()
        activeSource = nil
        sourceLock.unlock()
    }

    private func activeGeneration(for source: TerminalView) -> UUID? {
        sourceLock.lock()
        defer { sourceLock.unlock() }
        guard activeSource?.identifier == ObjectIdentifier(source) else { return nil }
        return activeSource?.generation
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard let generation = activeGeneration(for: source) else { return }
        Task { @MainActor [weak session] in
            session?.handleTerminalTitle(title, generation: generation)
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let generation = activeGeneration(for: source) else { return }
        Task { @MainActor [weak session] in
            session?.handleCurrentDirectory(directory, generation: generation)
        }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard let generation = activeGeneration(for: source) else { return }
        Task { @MainActor [weak session] in
            session?.handleProcessTerminated(exitCode, generation: generation)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
