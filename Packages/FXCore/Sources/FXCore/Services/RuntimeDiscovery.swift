import Darwin
import Foundation
import os
import Security

public enum BinaryHealth: Sendable, Equatable {
    case checking
    case available(path: String, version: String?)
    /// The executable exists but carries a quarantine attribute and did not
    /// pass the notarization check Gatekeeper applies, so FlowX will not run it.
    case quarantined(path: String)
    case notFound

    public var isUsable: Bool {
        if case .available = self {
            return true
        }
        return false
    }

    public var path: String? {
        switch self {
        case .available(let path, _), .quarantined(let path):
            path
        case .checking, .notFound:
            nil
        }
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
        case .quarantined:
            "Quarantined"
        case .notFound:
            "Not found"
        }
    }

    /// Steps the user can take to make a found-but-unusable runtime usable.
    public var guidance: String? {
        guard case .quarantined(let path) = self else { return nil }
        let quotedPath = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "macOS quarantined this file and FlowX couldn't verify that it's notarized "
            + "(the check may need a network connection). If you trust where it came from, run "
            + "xattr -d com.apple.quarantine \(quotedPath) in Terminal, then check runtimes again."
    }
}

/// A validated executable plus the environment it should be launched with.
public struct RuntimeLaunch: Sendable, Equatable {
    public let executableURL: URL
    public let environment: [String: String]
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
    case binaryQuarantined(String, path: String)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound(let binaryID):
            "Runtime '\(binaryID)' is not installed or is not executable."
        case .binaryQuarantined(let binaryID, let path):
            "Runtime '\(binaryID)' at \(path) is quarantined by macOS and could not be verified as notarized."
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
    private let environment: [String: String]
    private let currentDirectory: URL?
    private let timeout: TimeInterval
    private let standardOutput = Pipe()
    private let standardError = Pipe()
    private let capture: ProcessCapture

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?,
        timeout: TimeInterval,
        maxStandardOutputBytes: Int,
        maxStandardErrorBytes: Int
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
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
        process.environment = environment
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
    /// Directories prepended to PATH for every runtime launch. A GUI app
    /// inherits launchd's minimal PATH, which omits the usual install roots
    /// of CLIs and of the interpreters their scripts name in `#!/usr/bin/env`.
    static let preferredSearchDirectories = [
        "\(NSHomeDirectory())/.local/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
    ]

    private struct ResolvedRuntime: Sendable, Equatable {
        /// Symlink-resolved target that passed quarantine validation.
        let executableURL: URL
        /// Directory of the matched path before symlinks were resolved. An npm
        /// or nvm install keeps `node` beside the matched link, not beside the
        /// resolved `cli.js`.
        let searchDirectory: String
    }

    private enum DiscoveryOutcome: Sendable {
        case found(ResolvedRuntime)
        case quarantined(path: String)
        case notFound
    }

    private enum ExecutableValidation: Sendable {
        case usable(URL)
        case quarantined(URL)
        case missing
    }

    private let baseEnvironment: [String: String]
    private let quarantineAssessor: @Sendable (URL) -> Bool
    private var specs: [String: BinarySpec] = [:]
    private var resolved: [String: ResolvedRuntime] = [:]
    private var healthCache: [String: BinaryHealth] = [:]
    private var versionTasks: [String: Task<Void, Never>] = [:]

    public init() {
        self.init(
            environment: ProcessInfo.processInfo.environment,
            quarantineAssessor: QuarantineAssessment.passesGatekeeperNotarization
        )
    }

    /// - Parameters:
    ///   - environment: Base environment for probes and provider launches.
    ///   - quarantineAssessor: Decides whether a quarantined executable may run.
    init(
        environment: [String: String],
        quarantineAssessor: @escaping @Sendable (URL) -> Bool
    ) {
        baseEnvironment = environment
        self.quarantineAssessor = quarantineAssessor
    }

    public func register(_ spec: BinarySpec) async {
        if let previousVersionTask = versionTasks.removeValue(forKey: spec.id) {
            previousVersionTask.cancel()
            await previousVersionTask.value
        }

        specs[spec.id] = spec
        healthCache[spec.id] = .checking

        let outcome: DiscoveryOutcome
        do {
            outcome = try await findBinary(spec)
        } catch is CancellationError {
            return
        } catch {
            outcome = .notFound
        }

        guard !Task.isCancelled else { return }
        store(outcome, for: spec.id)
        if case .found(let runtime) = outcome {
            launchVersionCheck(for: spec, runtime: runtime)
        }
    }

    public func resolvedPath(for binaryID: String) -> URL? {
        revalidatedRuntime(for: binaryID)?.executableURL
    }

    /// Revalidates the discovered executable and pairs it with the launch
    /// environment providers must use so interpreter shebangs resolve.
    public func resolvedLaunch(for binaryID: String) -> RuntimeLaunch? {
        guard let runtime = revalidatedRuntime(for: binaryID) else { return nil }
        return RuntimeLaunch(
            executableURL: runtime.executableURL,
            environment: launchEnvironment(searchDirectory: runtime.searchDirectory)
        )
    }

    public func health(for binaryID: String) -> BinaryHealth {
        healthCache[binaryID] ?? .notFound
    }

    public func allHealth() -> [String: BinaryHealth] {
        healthCache
    }

    /// User-facing explanation for a runtime that cannot be launched.
    public func unavailableMessage(for binaryID: String) -> String {
        let name = specs[binaryID]?.displayName ?? binaryID
        if let health = healthCache[binaryID],
           case .quarantined(let path) = health,
           let guidance = health.guidance {
            return "\(name) was found at \(path) but can't be launched. \(guidance)"
        }
        let installHint = specs[binaryID]?.installHint.map { " Install with: \($0)" } ?? ""
        return "\(name) CLI not found.\(installHint)"
    }

    /// Waits for the inexpensive version probes launched after path discovery.
    /// Registration intentionally returns as soon as an executable is usable;
    /// callers that present version metadata can opt into this later barrier
    /// without repeating binary discovery.
    public func waitForVersionChecks() async {
        let tasks = Array(versionTasks.values)
        for task in tasks {
            await task.value
        }
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

        var discovered: [(id: String, spec: BinarySpec, runtime: ResolvedRuntime)] = []
        for (id, spec) in specs {
            healthCache[id] = .checking
            let outcome: DiscoveryOutcome
            do {
                outcome = try await findBinary(spec)
            } catch is CancellationError {
                return
            } catch {
                outcome = .notFound
            }
            guard !Task.isCancelled else { return }

            store(outcome, for: id)
            if case .found(let runtime) = outcome {
                discovered.append((id: id, spec: spec, runtime: runtime))
            }
        }

        await withTaskGroup(of: (String, ResolvedRuntime, String?).self) { group in
            for entry in discovered {
                group.addTask {
                    let version = await self.fetchVersion(of: entry.runtime, args: entry.spec.versionArgs)
                    return (entry.id, entry.runtime, version)
                }
            }

            for await (id, runtime, version) in group where !Task.isCancelled && resolved[id] == runtime {
                healthCache[id] = .available(path: runtime.executableURL.path, version: version)
            }
        }
    }

    public func run(
        binaryID: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        timeout: TimeInterval = 15
    ) async throws -> RuntimeCommandResult {
        guard let runtime = revalidatedRuntime(for: binaryID) else {
            if case .quarantined(let path)? = healthCache[binaryID] {
                throw RuntimeDiscoveryError.binaryQuarantined(binaryID, path: path)
            }
            throw RuntimeDiscoveryError.binaryNotFound(binaryID)
        }

        return try await Self.runProcess(
            executableURL: runtime.executableURL,
            arguments: arguments,
            environment: launchEnvironment(searchDirectory: runtime.searchDirectory),
            currentDirectory: currentDirectory,
            timeout: timeout
        )
    }

    /// Builds a launch environment whose PATH starts with the runtime's matched
    /// directory, then the preferred install roots, then the inherited PATH.
    /// Empty PATH entries are dropped because they mean the working directory.
    static func launchEnvironment(
        base: [String: String],
        searchDirectory: String?
    ) -> [String: String] {
        let inheritedPath = base["PATH"].flatMap(\.nilIfEmpty) ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let candidates = [searchDirectory].compactMap { $0 }
            + preferredSearchDirectories
            + inheritedPath.split(separator: ":").map(String.init)
        var seen = Set<String>()
        var environment = base
        environment["PATH"] = candidates
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
        return environment
    }

    private nonisolated func launchEnvironment(searchDirectory: String?) -> [String: String] {
        Self.launchEnvironment(base: baseEnvironment, searchDirectory: searchDirectory)
    }

    private func store(_ outcome: DiscoveryOutcome, for binaryID: String) {
        switch outcome {
        case .found(let runtime):
            resolved[binaryID] = runtime
            healthCache[binaryID] = .available(path: runtime.executableURL.path, version: nil)
        case .quarantined(let path):
            resolved[binaryID] = nil
            healthCache[binaryID] = .quarantined(path: path)
        case .notFound:
            resolved[binaryID] = nil
            healthCache[binaryID] = .notFound
        }
    }

    /// Providers consume the cached runtime long after discovery, so every
    /// access rechecks that the target is still executable and still allowed.
    private func revalidatedRuntime(for binaryID: String) -> ResolvedRuntime? {
        guard let runtime = resolved[binaryID] else {
            if case .quarantined? = healthCache[binaryID] {
                return nil
            }
            healthCache[binaryID] = .notFound
            return nil
        }

        switch validateExecutable(at: runtime.executableURL) {
        case .usable(let executableURL):
            let current = ResolvedRuntime(
                executableURL: executableURL,
                searchDirectory: runtime.searchDirectory
            )
            resolved[binaryID] = current
            if case .available(_, let version) = healthCache[binaryID] {
                healthCache[binaryID] = .available(path: executableURL.path, version: version)
            }
            return current
        case .quarantined(let executableURL):
            store(.quarantined(path: executableURL.path), for: binaryID)
            return nil
        case .missing:
            store(.notFound, for: binaryID)
            return nil
        }
    }

    private func findBinary(_ spec: BinarySpec) async throws -> DiscoveryOutcome {
        var quarantinedPath: String?
        for pattern in spec.searchPaths {
            try Task.checkCancellation()
            let candidates = pattern.contains("*")
                ? expandGlob(pattern).sorted(by: Self.preferNewestPath)
                : [pattern]
            for candidate in candidates {
                try Task.checkCancellation()
                switch validateExecutable(atPath: candidate) {
                case .usable(let executableURL):
                    return .found(Self.resolvedRuntime(executableURL, matchedPath: candidate))
                case .quarantined(let executableURL):
                    quarantinedPath = quarantinedPath ?? executableURL.path
                case .missing:
                    continue
                }
            }
        }

        if let name = spec.shellFallbackName,
           let path = try await shellWhich(name) {
            switch validateExecutable(atPath: path) {
            case .usable(let executableURL):
                return .found(Self.resolvedRuntime(executableURL, matchedPath: path))
            case .quarantined(let executableURL):
                quarantinedPath = quarantinedPath ?? executableURL.path
            case .missing:
                break
            }
        }

        if let quarantinedPath {
            return .quarantined(path: quarantinedPath)
        }
        return .notFound
    }

    private static func resolvedRuntime(_ executableURL: URL, matchedPath: String) -> ResolvedRuntime {
        ResolvedRuntime(
            executableURL: executableURL,
            searchDirectory: URL(fileURLWithPath: matchedPath)
                .deletingLastPathComponent()
                .standardizedFileURL
                .path
        )
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
                environment: launchEnvironment(searchDirectory: nil),
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

    private func launchVersionCheck(for spec: BinarySpec, runtime: ResolvedRuntime) {
        versionTasks[spec.id] = Task { [weak self] in
            guard let self else { return }
            await self.fetchAndStoreVersion(for: spec, runtime: runtime)
        }
    }

    private func fetchAndStoreVersion(for spec: BinarySpec, runtime: ResolvedRuntime) async {
        let version = await fetchVersion(of: runtime, args: spec.versionArgs)
        guard !Task.isCancelled, resolved[spec.id] == runtime else { return }
        guard let current = revalidatedRuntime(for: spec.id) else { return }
        healthCache[spec.id] = .available(path: current.executableURL.path, version: version)
    }

    private nonisolated func fetchVersion(of runtime: ResolvedRuntime, args: [String]) async -> String? {
        guard case .usable(let executableURL) = validateExecutable(at: runtime.executableURL),
              let result = try? await Self.runProcess(
            executableURL: executableURL,
            arguments: args,
            environment: launchEnvironment(searchDirectory: runtime.searchDirectory),
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

    /// Resolves indirection before applying Gatekeeper policy so a benign
    /// symlink cannot hide quarantine metadata on its executable target.
    /// Quarantine is intentionally never removed or bypassed by FlowX: a
    /// quarantined target is usable only when the assessor accepts it.
    private nonisolated func validateExecutable(atPath path: String) -> ExecutableValidation {
        validateExecutable(at: URL(fileURLWithPath: path))
    }

    private nonisolated func validateExecutable(at url: URL) -> ExecutableValidation {
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: resolvedURL.path) else {
            return .missing
        }
        guard Self.hasQuarantineAttribute(at: resolvedURL) else {
            return .usable(resolvedURL)
        }
        return quarantineAssessor(resolvedURL) ? .usable(resolvedURL) : .quarantined(resolvedURL)
    }

    private static func hasQuarantineAttribute(at url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { fileSystemPath in
            guard let fileSystemPath else { return true }
            let result = getxattr(
                fileSystemPath,
                "com.apple.quarantine",
                nil,
                0,
                0,
                0
            )
            if result >= 0 {
                return true
            }
            // Fail closed for unreadable metadata. ENOATTR is the only result
            // that establishes the executable has no quarantine attribute.
            return errno != ENOATTR
        }
    }

    private static func runProcess(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?,
        timeout: TimeInterval,
        maxStandardOutputBytes: Int = 32 * 1_024 * 1_024,
        maxStandardErrorBytes: Int = 1 * 1_024 * 1_024
    ) async throws -> RuntimeCommandResult {
        let execution = RuntimeProcessExecution(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
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

/// Applies the bar Gatekeeper sets for quarantined code to a runtime FlowX is
/// about to launch: Apple-signed, or Developer ID-signed and notarized. This
/// never removes or bypasses quarantine; anything else stays unusable.
enum QuarantineAssessment {
    static let requirement = "anchor apple or (anchor apple generic"
        + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
        + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        + " and notarized)"

    private struct FileIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modified: timespec
        let changed: timespec

        init?(_ url: URL) {
            var info = stat()
            guard stat(url.path, &info) == 0 else { return nil }
            device = info.st_dev
            inode = info.st_ino
            size = info.st_size
            modified = info.st_mtimespec
            changed = info.st_ctimespec
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.device == rhs.device
                && lhs.inode == rhs.inode
                && lhs.size == rhs.size
                && lhs.modified.tv_sec == rhs.modified.tv_sec
                && lhs.modified.tv_nsec == rhs.modified.tv_nsec
                && lhs.changed.tv_sec == rhs.changed.tv_sec
                && lhs.changed.tv_nsec == rhs.changed.tv_nsec
        }
    }

    /// Full validation hashes every page of the executable (~0.5 s for the
    /// Codex CLI), and providers revalidate on each launch. Approvals are
    /// remembered per file identity; any rewrite, replacement, or metadata
    /// change (ctime) forces a fresh check. Failures are never cached, so a
    /// refresh can succeed once the notarization ticket becomes reachable.
    private static let approvals = OSAllocatedUnfairLock<[String: FileIdentity]>(initialState: [:])

    static func passesGatekeeperNotarization(_ url: URL) -> Bool {
        guard let identity = FileIdentity(url) else { return false }
        if approvals.withLock({ $0[url.path] == identity }) {
            return true
        }
        guard checkValidity(of: url), FileIdentity(url) == identity else {
            return false
        }
        approvals.withLock { $0[url.path] = identity }
        return true
    }

    private static func checkValidity(of url: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return false
        }
        var secRequirement: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &secRequirement) == errSecSuccess,
              let secRequirement else {
            return false
        }
        let flags = SecCSFlags(rawValue:
            kSecCSStrictValidate
                | kSecCSCheckAllArchitectures
                | kSecCSCheckNestedCode
                | kSecCSRestrictSidebandData
        )
        return SecStaticCodeCheckValidity(staticCode, flags, secRequirement) == errSecSuccess
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
