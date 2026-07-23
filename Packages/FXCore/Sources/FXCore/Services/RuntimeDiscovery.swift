import Foundation
import os

public enum BinaryHealth: Sendable, Equatable {
    case checking
    case available(path: String, version: String?)
    case notFound

    public var isUsable: Bool {
        if case .available = self {
            return true
        }
        return false
    }

    public var path: String? {
        if case .available(let path, _) = self {
            return path
        }
        return nil
    }

    public var version: String? {
        if case .available(_, let version) = self {
            return version
        }
        return nil
    }

    public var statusLabel: String {
        switch self {
        case .checking:
            "Checking…"
        case .available(_, let version):
            version ?? "Installed"
        case .notFound:
            "Not found"
        }
    }
}

public struct BinarySpec: Sendable {
    public let id: String
    public let displayName: String
    public let searchPaths: [String]
    public let versionArgs: [String]
    public let shellFallbackName: String?
    public let installHint: String?

    public init(
        id: String,
        displayName: String,
        searchPaths: [String],
        versionArgs: [String] = ["--version"],
        shellFallbackName: String? = nil,
        installHint: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.searchPaths = searchPaths
        self.versionArgs = versionArgs
        self.shellFallbackName = shellFallbackName
        self.installHint = installHint
    }
}

public struct RuntimeCommandResult: Sendable, Equatable {
    public let standardOutput: Data
    public let standardError: Data
    public let terminationStatus: Int32
    public let timedOut: Bool
    public let outputWasTruncated: Bool

    public var standardOutputString: String {
        String(decoding: standardOutput, as: UTF8.self)
    }

    public var standardErrorString: String {
        String(decoding: standardError, as: UTF8.self)
    }
}

public enum RuntimeDiscoveryError: LocalizedError, Sendable {
    case binaryNotFound(String)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound(let binaryID):
            "Runtime '\(binaryID)' is not installed or is not executable."
        case .launchFailed(let message):
            message
        }
    }
}

private final class ProcessCapture: @unchecked Sendable {
    private enum Stream {
        case standardOutput
        case standardError
    }

    private struct State {
        var standardOutput = Data()
        var standardError = Data()
        var timedOut = false
        var outputWasTruncated = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let maxStandardOutputBytes: Int
    private let maxStandardErrorBytes: Int

    init(maxStandardOutputBytes: Int, maxStandardErrorBytes: Int) {
        self.maxStandardOutputBytes = maxStandardOutputBytes
        self.maxStandardErrorBytes = maxStandardErrorBytes
    }

    func appendStandardOutput(_ data: Data) {
        append(data, to: .standardOutput, limit: maxStandardOutputBytes)
    }

    func appendStandardError(_ data: Data) {
        append(data, to: .standardError, limit: maxStandardErrorBytes)
    }

    func markTimedOut() {
        state.withLock { $0.timedOut = true }
    }

    func snapshot(terminationStatus: Int32) -> RuntimeCommandResult {
        state.withLock { value in
            RuntimeCommandResult(
                standardOutput: value.standardOutput,
                standardError: value.standardError,
                terminationStatus: terminationStatus,
                timedOut: value.timedOut,
                outputWasTruncated: value.outputWasTruncated
            )
        }
    }

    private func append(_ data: Data, to stream: Stream, limit: Int) {
        guard !data.isEmpty else { return }
        state.withLock { value in
            let existingCount: Int
            switch stream {
            case .standardOutput:
                existingCount = value.standardOutput.count
            case .standardError:
                existingCount = value.standardError.count
            }

            let remaining = max(0, limit - existingCount)
            if data.count > remaining {
                value.outputWasTruncated = true
            }
            guard remaining > 0 else { return }
            switch stream {
            case .standardOutput:
                value.standardOutput.append(data.prefix(remaining))
            case .standardError:
                value.standardError.append(data.prefix(remaining))
            }
        }
    }
}

private final class RuntimeProcessExecution: @unchecked Sendable {
    private final class ProcessReference: @unchecked Sendable {
        let process: Process

        init(_ process: Process) {
            self.process = process
        }
    }

    private enum StartOutcome: Sendable {
        case launched
        case cancelled
        case launchFailed(String)
    }

    private struct Completion: @unchecked Sendable {
        let continuation: CheckedContinuation<RuntimeCommandResult, Error>?
        let wasCancelled: Bool
    }

    private struct State: @unchecked Sendable {
        var continuation: CheckedContinuation<RuntimeCommandResult, Error>?
        var process: ProcessReference?
        var timeoutToken: UUID?
        var killToken: UUID?
        var cancellationRequested = false
        var terminationRequested = false
        var completed = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let executableURL: URL
    private let arguments: [String]
    private let currentDirectory: URL?
    private let timeout: TimeInterval
    private let standardOutput = Pipe()
    private let standardError = Pipe()
    private let capture: ProcessCapture

    init(
        executableURL: URL,
        arguments: [String],
        currentDirectory: URL?,
        timeout: TimeInterval,
        maxStandardOutputBytes: Int,
        maxStandardErrorBytes: Int
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.currentDirectory = currentDirectory
        self.timeout = timeout
        capture = ProcessCapture(
            maxStandardOutputBytes: maxStandardOutputBytes,
            maxStandardErrorBytes: maxStandardErrorBytes
        )
    }

    func run() async throws -> RuntimeCommandResult {
        try await withCheckedThrowingContinuation { continuation in
            start(continuation)
        }
    }

    func cancel() {
        let process = state.withLock { value -> ProcessReference? in
            value.cancellationRequested = true
            guard !value.completed,
                  !value.terminationRequested,
                  let process = value.process
            else {
                return nil
            }
            value.terminationRequested = true
            return process
        }

        if let process {
            terminate(process)
        }
    }

    private func start(_ continuation: CheckedContinuation<RuntimeCommandResult, Error>) {
        let process = Process()
        let processReference = ProcessReference(process)
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = standardOutput
        process.standardError = standardError

        standardOutput.fileHandleForReading.readabilityHandler = { [capture] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                capture.appendStandardOutput(data)
            }
        }
        standardError.fileHandleForReading.readabilityHandler = { [capture] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                capture.appendStandardError(data)
            }
        }
        process.terminationHandler = { [weak self, weak processReference] _ in
            guard let processReference else { return }
            self?.processDidTerminate(processReference)
        }

        let outcome = state.withLock { value -> StartOutcome in
            value.continuation = continuation
            if value.cancellationRequested {
                value.completed = true
                value.continuation = nil
                return .cancelled
            }

            value.process = processReference
            do {
                // Keep cancellation synchronized with launch. A cancellation racing
                // process.run() waits for the PID to exist, then terminates it.
                try process.run()
                return .launched
            } catch {
                value.completed = true
                value.process = nil
                value.continuation = nil
                return .launchFailed(error.localizedDescription)
            }
        }

        switch outcome {
        case .launched:
            scheduleTimeoutIfNeeded()
        case .cancelled:
            stopReading()
            process.terminationHandler = nil
            continuation.resume(throwing: CancellationError())
        case .launchFailed(let message):
            stopReading()
            process.terminationHandler = nil
            continuation.resume(throwing: RuntimeDiscoveryError.launchFailed(
                "Failed to start \(executableURL.lastPathComponent): \(message)"
            ))
        }
    }

    private func scheduleTimeoutIfNeeded() {
        guard timeout > 0 else { return }
        let token = UUID()
        let shouldSchedule = state.withLock { value -> Bool in
            guard !value.completed else { return false }
            value.timeoutToken = token
            return true
        }
        if shouldSchedule {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.timeoutDidFire(token: token)
            }
        }
    }

    private func timeoutDidFire(token: UUID) {
        let process = state.withLock { value -> ProcessReference? in
            guard !value.completed,
                  value.timeoutToken == token,
                  !value.terminationRequested,
                  let process = value.process
            else {
                return nil
            }
            value.terminationRequested = true
            return process
        }
        guard let process else { return }
        capture.markTimedOut()
        terminate(process)
    }

    private func terminate(_ process: ProcessReference) {
        let token = UUID()
        let shouldScheduleKill = state.withLock { value -> Bool in
            guard !value.completed, value.process === process else { return false }
            value.killToken = token
            return true
        }

        if process.process.isRunning {
            process.process.terminate()
        }
        if shouldScheduleKill {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.forceKillIfNeeded(token: token)
            }
        }
    }

    private func forceKillIfNeeded(token: UUID) {
        let processIdentifier = state.withLock { value -> pid_t? in
            guard !value.completed,
                  value.killToken == token,
                  let process = value.process,
                  process.process.isRunning
            else {
                return nil
            }
            return process.process.processIdentifier
        }
        if let processIdentifier, processIdentifier > 0 {
            kill(processIdentifier, SIGKILL)
        }
    }

    private func processDidTerminate(_ processReference: ProcessReference) {
        let process = processReference.process
        stopReading()
        capture.appendStandardOutput(standardOutput.fileHandleForReading.readDataToEndOfFile())
        capture.appendStandardError(standardError.fileHandleForReading.readDataToEndOfFile())
        let result = capture.snapshot(terminationStatus: process.terminationStatus)

        let completion = state.withLock { value -> Completion? in
            guard !value.completed, value.process === processReference else { return nil }
            value.completed = true
            let completion = Completion(
                continuation: value.continuation,
                wasCancelled: value.cancellationRequested
            )
            value.continuation = nil
            value.process = nil
            value.timeoutToken = nil
            value.killToken = nil
            return completion
        }
        process.terminationHandler = nil

        if completion?.wasCancelled == true {
            completion?.continuation?.resume(throwing: CancellationError())
        } else {
            completion?.continuation?.resume(returning: result)
        }
    }

    private func stopReading() {
        standardOutput.fileHandleForReading.readabilityHandler = nil
        standardError.fileHandleForReading.readabilityHandler = nil
    }
}

public actor RuntimeDiscovery {
    private var specs: [String: BinarySpec] = [:]
    private var resolved: [String: URL] = [:]
    private var healthCache: [String: BinaryHealth] = [:]
    private var versionTasks: [String: Task<Void, Never>] = [:]

    public init() {}

    public func register(_ spec: BinarySpec) async {
        if let previousVersionTask = versionTasks.removeValue(forKey: spec.id) {
            previousVersionTask.cancel()
            await previousVersionTask.value
        }

        specs[spec.id] = spec
        healthCache[spec.id] = .checking

        let discoveredURL: URL?
        do {
            discoveredURL = try await findBinary(spec)
        } catch is CancellationError {
            return
        } catch {
            discoveredURL = nil
        }

        guard !Task.isCancelled else { return }
        if let url = discoveredURL {
            resolved[spec.id] = url
            healthCache[spec.id] = .available(path: url.path, version: nil)
            launchVersionCheck(for: spec, at: url)
        } else {
            healthCache[spec.id] = .notFound
        }
    }

    public func resolvedPath(for binaryID: String) -> URL? {
        resolved[binaryID]
    }

    public func health(for binaryID: String) -> BinaryHealth {
        healthCache[binaryID] ?? .notFound
    }

    public func allHealth() -> [String: BinaryHealth] {
        healthCache
    }

    public func spec(for binaryID: String) -> BinarySpec? {
        specs[binaryID]
    }

    public func allSpecs() -> [BinarySpec] {
        Array(specs.values)
    }

    public func refreshAll() async {
        let previousVersionTasks = Array(versionTasks.values)
        versionTasks.removeAll()
        for task in previousVersionTasks {
            task.cancel()
        }
        for task in previousVersionTasks {
            await task.value
        }
        guard !Task.isCancelled else { return }

        var discovered: [(id: String, spec: BinarySpec, url: URL)] = []
        for (id, spec) in specs {
            healthCache[id] = .checking
            let discoveredURL: URL?
            do {
                discoveredURL = try await findBinary(spec)
            } catch is CancellationError {
                return
            } catch {
                discoveredURL = nil
            }
            guard !Task.isCancelled else { return }

            if let url = discoveredURL {
                resolved[id] = url
                healthCache[id] = .available(path: url.path, version: nil)
                discovered.append((id: id, spec: spec, url: url))
            } else {
                resolved[id] = nil
                healthCache[id] = .notFound
            }
        }

        await withTaskGroup(of: (String, URL, String?).self) { group in
            for entry in discovered {
                group.addTask {
                    let version = await Self.fetchVersion(at: entry.url, args: entry.spec.versionArgs)
                    return (entry.id, entry.url, version)
                }
            }

            for await (id, url, version) in group where !Task.isCancelled && resolved[id] == url {
                healthCache[id] = .available(path: url.path, version: version)
            }
        }
    }

    public func run(
        binaryID: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        timeout: TimeInterval = 15
    ) async throws -> RuntimeCommandResult {
        guard let executableURL = resolved[binaryID] else {
            throw RuntimeDiscoveryError.binaryNotFound(binaryID)
        }

        return try await Self.runProcess(
            executableURL: executableURL,
            arguments: arguments,
            currentDirectory: currentDirectory,
            timeout: timeout
        )
    }

    private func findBinary(_ spec: BinarySpec) async throws -> URL? {
        for pattern in spec.searchPaths {
            try Task.checkCancellation()
            if pattern.contains("*") {
                for expanded in expandGlob(pattern).sorted(by: Self.preferNewestPath) {
                    try Task.checkCancellation()
                    if FileManager.default.isExecutableFile(atPath: expanded) {
                        return URL(fileURLWithPath: expanded)
                    }
                }
            } else if FileManager.default.isExecutableFile(atPath: pattern) {
                return URL(fileURLWithPath: pattern)
            }
        }

        if let name = spec.shellFallbackName, let path = try await shellWhich(name) {
            return URL(fileURLWithPath: path)
        }

        return nil
    }

    private func expandGlob(_ pattern: String) -> [String] {
        let components = (pattern as NSString).pathComponents
        guard let starIndex = components.firstIndex(where: { $0.contains("*") }) else {
            return [pattern]
        }

        let baseComponents = Array(components[..<starIndex])
        let globSegment = components[starIndex]
        let suffixComponents = Array(components.dropFirst(starIndex + 1))

        let baseDir = NSString.path(withComponents: baseComponents)
        let suffix = suffixComponents.isEmpty ? "" : NSString.path(withComponents: suffixComponents)

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: baseDir) else {
            return []
        }

        var results: [String] = []
        for entry in entries {
            if globSegment == "*" || matchesGlob(entry, pattern: globSegment) {
                var candidate = (baseDir as NSString).appendingPathComponent(entry)
                if !suffix.isEmpty {
                    candidate = (candidate as NSString).appendingPathComponent(suffix)
                }
                results.append(candidate)
            }
        }
        return results
    }

    private func matchesGlob(_ string: String, pattern: String) -> Bool {
        let predicate = NSPredicate(format: "SELF LIKE %@", pattern)
        return predicate.evaluate(with: string)
    }

    private func shellWhich(_ name: String) async throws -> String? {
        guard !name.isEmpty,
              name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_" )).contains($0) }) else {
            return nil
        }

        let result: RuntimeCommandResult
        do {
            result = try await Self.runProcess(
                executableURL: URL(fileURLWithPath: "/bin/zsh"),
                arguments: ["-l", "-c", "command -v -- \(name)"],
                currentDirectory: nil,
                timeout: 5,
                maxStandardOutputBytes: 16 * 1_024,
                maxStandardErrorBytes: 4 * 1_024
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
        guard result.terminationStatus == 0, !result.timedOut else { return nil }

        let candidates = String(
            decoding: result.standardOutput,
            as: UTF8.self
        )
        .split(whereSeparator: \.isNewline)
        .map(String.init)
        .filter { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }

        return candidates.last
    }

    private func launchVersionCheck(for spec: BinarySpec, at url: URL) {
        versionTasks[spec.id] = Task { [weak self] in
            guard let self else { return }
            await self.fetchAndStoreVersion(for: spec, at: url)
        }
    }

    private func fetchAndStoreVersion(for spec: BinarySpec, at url: URL) async {
        let version = await Self.fetchVersion(at: url, args: spec.versionArgs)
        if !Task.isCancelled {
            healthCache[spec.id] = .available(path: url.path, version: version)
        }
    }

    private static func fetchVersion(at url: URL, args: [String]) async -> String? {
        guard let result = try? await runProcess(
            executableURL: url,
            arguments: args,
            currentDirectory: nil,
            timeout: 5,
            maxStandardOutputBytes: 64 * 1_024,
            maxStandardErrorBytes: 16 * 1_024
        ),
        result.terminationStatus == 0,
        !result.timedOut else {
            return nil
        }

        return result.standardOutputString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private static func preferNewestPath(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedDescending
    }

    private static func runProcess(
        executableURL: URL,
        arguments: [String],
        currentDirectory: URL?,
        timeout: TimeInterval,
        maxStandardOutputBytes: Int = 32 * 1_024 * 1_024,
        maxStandardErrorBytes: Int = 1 * 1_024 * 1_024
    ) async throws -> RuntimeCommandResult {
        let execution = RuntimeProcessExecution(
            executableURL: executableURL,
            arguments: arguments,
            currentDirectory: currentDirectory,
            timeout: timeout,
            maxStandardOutputBytes: maxStandardOutputBytes,
            maxStandardErrorBytes: maxStandardErrorBytes
        )
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await execution.run()
        } onCancel: {
            execution.cancel()
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
