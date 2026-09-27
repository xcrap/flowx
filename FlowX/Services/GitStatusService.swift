import Darwin
import AppKit
import Foundation
import FXCore

private struct GitProcessResult: Sendable {
    var succeeded: Bool
    var output: String
    var wasTruncated: Bool
    /// Cancelled or timed out: the result says nothing about the repository.
    var wasInterrupted: Bool = false
}

private final class GitCommandExecution: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false

    func run(
        arguments: [String],
        directory: String,
        includeStandardError: Bool,
        timeout: Duration,
        maximumOutputBytes: Int,
        appendsTruncationNotice: Bool = true
    ) async -> GitProcessResult {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async { [self] in
                    let result = execute(
                        arguments: arguments,
                        directory: directory,
                        includeStandardError: includeStandardError,
                        timeout: timeout,
                        maximumOutputBytes: maximumOutputBytes,
                        appendsTruncationNotice: appendsTruncationNotice
                    )
                    continuation.resume(returning: result)
                }
            }
        } onCancel: { [self] in
            cancel()
        }
    }

    private func execute(
        arguments: [String],
        directory: String,
        includeStandardError: Bool,
        timeout: Duration,
        maximumOutputBytes: Int,
        appendsTruncationNotice: Bool
    ) -> GitProcessResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        // Read-only polling must never take .git/index.lock, or concurrent
        // agent/user commands fail with "index.lock: File exists".
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GCM_INTERACTIVE"] = "Never"
        environment["SSH_ASKPASS_REQUIRE"] = "never"
        environment["GIT_ASKPASS"] = "/usr/bin/false"
        environment["LC_ALL"] = "C"
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = includeStandardError ? pipe : FileHandle.nullDevice

        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return GitProcessResult(succeeded: false, output: "", wasTruncated: false, wasInterrupted: true)
        }
        self.process = process
        lock.unlock()

        do {
            try process.run()
        } catch {
            clearProcess()
            return GitProcessResult(
                succeeded: false,
                output: error.localizedDescription,
                wasTruncated: false
            )
        }

        // Cancellation can arrive after the Process reference is published
        // but before launch has produced a running PID. Recheck immediately
        // after `run()` so that gap cannot leave git work alive until timeout.
        lock.lock()
        let cancelAfterLaunch = cancelled
        lock.unlock()
        if cancelAfterLaunch, process.isRunning {
            process.terminate()
            scheduleForceKillIfNeeded(process)
        }

        let timeoutWork = DispatchWorkItem { [weak self] in
            self?.terminateForTimeout()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout.timeInterval, execute: timeoutWork)

        var outputData = Data()
        var wasTruncated = false
        let reader = pipe.fileHandleForReading
        while let chunk = try? reader.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            let remaining = maximumOutputBytes - outputData.count
            if remaining > 0 {
                outputData.append(chunk.prefix(remaining))
            }
            if chunk.count > remaining {
                wasTruncated = true
            }
        }
        process.waitUntilExit()
        timeoutWork.cancel()

        lock.lock()
        let didTimeOut = timedOut
        let wasCancelled = cancelled
        self.process = nil
        lock.unlock()

        var output = String(decoding: outputData, as: UTF8.self)
        if wasTruncated, appendsTruncationNotice {
            output += "\n\n[Git output truncated by FlowX.]"
        }
        if didTimeOut, includeStandardError {
            output += output.isEmpty ? "Git command timed out." : "\nGit command timed out."
        }

        return GitProcessResult(
            succeeded: !didTimeOut && !wasCancelled && !wasTruncated && process.terminationStatus == 0,
            output: output,
            wasTruncated: wasTruncated,
            wasInterrupted: didTimeOut || wasCancelled
        )
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let process = process
        lock.unlock()
        if process?.isRunning == true {
            process?.terminate()
            scheduleForceKillIfNeeded(process)
        }
    }

    private func terminateForTimeout() {
        lock.lock()
        timedOut = true
        let process = process
        lock.unlock()
        if process?.isRunning == true {
            process?.terminate()
            scheduleForceKillIfNeeded(process)
        }
    }

    private func scheduleForceKillIfNeeded(_ process: Process?) {
        guard let process else { return }
        let processIdentifier = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [weak self, weak process] in
            guard let self, let process else { return }
            self.lock.lock()
            let isCurrentProcess = self.process === process
            let isRunning = process.isRunning
            self.lock.unlock()
            if isCurrentProcess, isRunning {
                Darwin.kill(processIdentifier, SIGKILL)
            }
        }
    }

    private func clearProcess() {
        lock.lock()
        process = nil
        lock.unlock()
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}

@Observable
@MainActor
final class GitStatusService {
    private static let fileReadExecutor = BoundedTaskExecutor(maxConcurrentTasks: 2)
    private static let revisionExecutor = BoundedTaskExecutor(maxConcurrentTasks: 1)

    /// Where a project folder sits in its repository. Git prints status,
    /// numstat and diff paths relative to the repository root, so every git
    /// command runs from `topLevel` and every path resolves against it, even
    /// when the project was opened at a subfolder.
    private struct RepositoryLocation: Equatable, Sendable {
        var topLevel: String
        /// Project folder relative to `topLevel` with a trailing slash, or
        /// empty when the project is the repository root.
        var prefix: String

        /// Scopes status, diff and add to the project folder. `literal`
        /// keeps folder names containing `*`, `?` or `[` from matching as
        /// globs.
        var pathspecArguments: [String] {
            prefix.isEmpty ? [] : ["--", ":(top,literal)\(prefix)"]
        }

        /// Parses `git rev-parse --show-toplevel --show-prefix`: the
        /// top-level line, then the prefix line (empty at the root).
        init?(revParseOutput output: String) {
            let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
            guard lines.count >= 2, lines[0].hasPrefix("/") else { return nil }
            topLevel = String(lines[0])
            prefix = String(lines[1])
        }
    }

    private enum RepositoryLookup {
        case found(RepositoryLocation)
        case notRepository
        case interrupted
    }

    struct CommandResult: Sendable {
        var succeeded: Bool
        var output: String
        var wasTruncated: Bool = false
        var wasInterrupted: Bool = false
    }

    typealias FileStatus = GitFileStatus
    typealias GitInfo = GitRepositoryInfo

    private(set) var info: [UUID: GitInfo] = [:]
    private(set) var lastFailureMessage: [UUID: String] = [:]
    var onInfoChange: ((UUID, GitInfo) -> Void)?
    private var pollingTasks: [UUID: Task<Void, Never>] = [:]
    private var rootPaths: [UUID: String] = [:]
    /// Resolved once per root path; a folder that is not a repository yet is
    /// looked up again on the next refresh.
    private var repositories: [UUID: RepositoryLocation] = [:]
    private var remotePresence: [UUID: Bool] = [:]
    private var refreshingProjects: Set<UUID> = []
    private var pendingRefreshes: Set<UUID> = []
    private var forceRefreshTasks: [UUID: Task<Void, Never>] = [:]

    func startPolling(projectID: UUID, rootPath: String) {
        let normalizedPath = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL.path
        if rootPaths[projectID] != normalizedPath {
            remotePresence[projectID] = nil
            repositories[projectID] = nil
        }
        rootPaths[projectID] = normalizedPath
        guard pollingTasks[projectID] == nil else { return }
        pollingTasks[projectID] = Task { [weak self] in
            while !Task.isCancelled {
                if NSApplication.shared.isActive {
                    await self?.requestRefresh(projectID: projectID)
                }
                do {
                    try await Task.sleep(
                        for: NSApplication.shared.isActive ? .seconds(5) : .seconds(15)
                    )
                } catch {
                    break
                }
            }
        }
    }

    func pollOnly(projectID: UUID, rootPath: String) {
        for existingID in Array(pollingTasks.keys) where existingID != projectID {
            stopPolling(projectID: existingID)
        }
        startPolling(projectID: projectID, rootPath: rootPath)
    }

    func stopPolling(projectID: UUID) {
        pollingTasks[projectID]?.cancel()
        pollingTasks.removeValue(forKey: projectID)
        forceRefreshTasks[projectID]?.cancel()
        forceRefreshTasks.removeValue(forKey: projectID)
        pendingRefreshes.remove(projectID)
    }

    func stopAll() {
        for task in pollingTasks.values {
            task.cancel()
        }
        for task in forceRefreshTasks.values {
            task.cancel()
        }
        pollingTasks.removeAll()
        forceRefreshTasks.removeAll()
        pendingRefreshes.removeAll()
    }

    func removeProject(projectID: UUID) {
        stopPolling(projectID: projectID)
        rootPaths[projectID] = nil
        repositories[projectID] = nil
        remotePresence[projectID] = nil
        refreshingProjects.remove(projectID)
        info[projectID] = nil
        lastFailureMessage[projectID] = nil
    }

    func forceRefresh(projectID: UUID) {
        guard rootPaths[projectID] != nil else { return }
        pendingRefreshes.insert(projectID)
        guard forceRefreshTasks[projectID] == nil else { return }
        forceRefreshTasks[projectID] = Task { [weak self] in
            await self?.requestRefresh(projectID: projectID)
            self?.forceRefreshTasks[projectID] = nil
        }
    }

    func diffUnstaged(projectID: UUID, path: String) async -> String {
        guard let path = validatedRelativePath(path),
              let repository = await repository(for: projectID) else { return "" }
        return await runGit(["-c", "core.quotePath=false", "diff", "--no-ext-diff", "--no-color", "--", path], in: repository.topLevel)
    }

    func diffStaged(projectID: UUID, path: String) async -> String {
        guard let path = validatedRelativePath(path),
              let repository = await repository(for: projectID) else { return "" }
        return await runGit(["-c", "core.quotePath=false", "diff", "--no-ext-diff", "--no-color", "--cached", "--", path], in: repository.topLevel)
    }

    func diffAgainstHead(projectID: UUID, path: String) async -> String {
        guard let path = validatedRelativePath(path),
              let repository = await repository(for: projectID) else { return "" }
        return await runGit(["-c", "core.quotePath=false", "diff", "--no-ext-diff", "--no-color", "HEAD", "--", path], in: repository.topLevel)
    }

    func projectDiff(projectID: UUID, mode: InspectorComparisonMode, files: [FileStatus]) async -> String {
        guard let repository = await repository(for: projectID) else { return "" }
        let repositoryRoot = repository.topLevel

        var budget = ProjectDiffBudgetPolicy()
        let sortedFiles = files.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        // Default status collapses a new folder to `dir/`, which
        // `diff --no-index` cannot read. Expand folders to their files so
        // agent-scaffolded code shows up.
        var untrackedPaths: [String] = []
        for path in sortedFiles
            .filter({ $0.isUntracked && mode != .staged })
            .compactMap({ validatedRelativePath($0.path) }) {
            guard untrackedPaths.count < Self.maximumUntrackedDiffFiles else { break }
            if path.hasSuffix("/") {
                let remaining = Self.maximumUntrackedDiffFiles - untrackedPaths.count
                untrackedPaths += await untrackedFiles(inDirectory: path, rootPath: repositoryRoot, limit: remaining)
            } else {
                untrackedPaths.append(path)
            }
        }

        if sortedFiles.contains(where: { !($0.isUntracked && mode != .staged) }) {
            let args: [String]
            switch mode {
            case .unstaged:
                args = ["-c", "core.quotePath=false", "diff", "--no-ext-diff", "--no-color"]
            case .staged:
                args = ["-c", "core.quotePath=false", "diff", "--no-ext-diff", "--no-color", "--cached"]
            case .base:
                args = ["-c", "core.quotePath=false", "diff", "--no-ext-diff", "--no-color", "HEAD"]
            }

            let trackedResult = await runGitForResult(
                args + repository.pathspecArguments,
                in: repositoryRoot,
                maximumOutputBytes: budget.remainingFragmentBytes,
                appendsTruncationNotice: false,
                includesStandardError: false
            )
            let trackedDiff = trackedResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trackedDiff.isEmpty {
                _ = budget.append(
                    trackedDiff,
                    sourceWasTruncated: trackedResult.wasTruncated
                )
            } else if trackedResult.wasTruncated {
                budget.markTruncated()
            }
            if budget.wasTruncated {
                return budget.output
            }
        }

        for path in untrackedPaths {
            guard !Task.isCancelled else { break }
            guard budget.remainingFragmentBytes > 0 else {
                budget.markTruncated()
                break
            }
            let result = await untrackedDiff(
                path: path,
                in: repositoryRoot,
                maximumOutputBytes: budget.remainingFragmentBytes
            )
            let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                _ = budget.append(trimmed, sourceWasTruncated: result.wasTruncated)
            } else if result.wasTruncated {
                budget.markTruncated()
            }
            if budget.wasTruncated {
                break
            }
        }

        return budget.output
    }

    /// Absolute location of a path from `GitInfo.files` or a diff header.
    /// Git reports those relative to the repository root, not the project
    /// folder, so resolving them against the project root breaks for
    /// projects opened at a subfolder.
    func workingTreeURL(projectID: UUID, path: String) -> URL? {
        guard let topLevel = repositories[projectID]?.topLevel,
              let path = validatedRelativePath(path) else { return nil }
        return URL(fileURLWithPath: topLevel, isDirectory: true).appendingPathComponent(path)
    }

    func fileContents(projectID: UUID, path: String) async -> String {
        guard let repository = await repository(for: projectID),
              let url = safeFileURL(path: path, rootPath: repository.topLevel) else {
            return ""
        }

        do {
            let contents = try await Self.fileReadExecutor.run(priority: .userInitiated) {
                try Task.checkCancellation()
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                      values.isRegularFile == true,
                      let fileSize = values.fileSize,
                      fileSize <= 16 * 1_024 * 1_024,
                      let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                    return ""
                }
                try Task.checkCancellation()
                let decoded = String(data: data, encoding: .utf8) ?? ""
                try Task.checkCancellation()
                return decoded
            }
            guard !Task.isCancelled else {
                return ""
            }
            return contents
        } catch {
            return ""
        }
    }

    func fileContentsAtHead(projectID: UUID, path: String) async -> String? {
        guard let path = validatedRelativePath(path),
              let repository = await repository(for: projectID) else { return nil }
        let result = await runGitForResult(["show", "HEAD:\(path)"], in: repository.topLevel)
        guard result.succeeded else { return nil }
        return result.output
    }

    func fileContentsFromIndex(projectID: UUID, path: String) async -> String? {
        guard let path = validatedRelativePath(path),
              let repository = await repository(for: projectID) else { return nil }
        let result = await runGitForResult(["show", ":\(path)"], in: repository.topLevel)
        guard result.succeeded else { return nil }
        return result.output
    }

    /// `stagedOnly` commits the index as the user built it (e.g. with
    /// `git add -p`). Otherwise the project folder is staged first, scoped
    /// to it so a subfolder project never stages the rest of the repository.
    func commit(projectID: UUID, message: String, includeUntracked: Bool, stagedOnly: Bool) async -> Bool {
        guard let repository = await repository(for: projectID) else { return false }

        if !stagedOnly {
            let addResult = await runGitForResult(
                (includeUntracked ? ["add", "-A"] : ["add", "-u"]) + repository.pathspecArguments,
                in: repository.topLevel
            )
            guard addResult.succeeded else {
                lastFailureMessage[projectID] = normalizedFailureMessage(addResult.output, fallback: "Unable to stage changes.")
                pendingRefreshes.insert(projectID)
                await requestRefresh(projectID: projectID)
                return false
            }
        }

        let commitResult = await runGitForResult(["commit", "-m", message], in: repository.topLevel, timeout: .seconds(120))
        if !commitResult.succeeded {
            lastFailureMessage[projectID] = normalizedFailureMessage(commitResult.output, fallback: "Commit failed.")
        } else {
            lastFailureMessage[projectID] = nil
        }

        pendingRefreshes.insert(projectID)
        await requestRefresh(projectID: projectID)
        return commitResult.succeeded
    }

    func push(projectID: UUID) async -> Bool {
        guard let repository = await repository(for: projectID) else { return false }
        let result: CommandResult
        switch await pushPlan(in: repository.topLevel) {
        case .run(let arguments):
            result = await runGitForResult(arguments, in: repository.topLevel, timeout: .seconds(120))
        case .fail(let message):
            result = CommandResult(succeeded: false, output: message)
        }
        if !result.succeeded {
            lastFailureMessage[projectID] = normalizedFailureMessage(result.output, fallback: "Push failed.")
        } else {
            lastFailureMessage[projectID] = nil
        }
        pendingRefreshes.insert(projectID)
        await requestRefresh(projectID: projectID)
        return result.succeeded
    }

    private enum PushPlan {
        case run([String])
        case fail(String)
    }

    /// A bare `git push` fails with "has no upstream branch" unless
    /// `push.autoSetupRemote` is set, so a branch without an upstream is
    /// published explicitly and starts tracking the pushed branch.
    private func pushPlan(in directory: String) async -> PushPlan {
        let branchResult = await runGitForResult(
            ["symbolic-ref", "--quiet", "--short", "HEAD"],
            in: directory,
            timeout: .seconds(10),
            includesStandardError: false
        )
        let branch = branchResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard branchResult.succeeded, !branch.isEmpty else {
            return .fail(branchResult.wasInterrupted ? "Push failed." : "Check out a branch before pushing.")
        }

        // The configured merge ref is what status reports as the upstream,
        // and unlike `@{upstream}` it still resolves once the remote branch
        // is gone.
        let mergeRef = await runGit(["config", "--get", "branch.\(branch).merge"], in: directory, timeout: .seconds(10))
        if !mergeRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .run(["push"])
        }

        let remote = await pushRemote(forBranch: branch, in: directory)
        return .run(["push", "--set-upstream", remote, "HEAD"])
    }

    /// The branch's push remote, then `remote.pushDefault`, then the only
    /// remote, then `origin`.
    private func pushRemote(forBranch branch: String, in directory: String) async -> String {
        for key in ["branch.\(branch).pushRemote", "remote.pushDefault"] {
            let value = await runGit(["config", "--get", key], in: directory, timeout: .seconds(10))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }
        let remotes = await runGit(["remote"], in: directory, timeout: .seconds(10))
            .split(whereSeparator: \.isNewline)
        return remotes.count == 1 ? String(remotes[0]) : "origin"
    }

    /// Resolves the project's repository once per root path and caches it.
    private func lookUpRepository(projectID: UUID, rootPath: String) async -> RepositoryLookup {
        if let location = repositories[projectID] {
            return .found(location)
        }
        let result = await runGitForResult(
            ["rev-parse", "--show-toplevel", "--show-prefix"],
            in: rootPath,
            timeout: .seconds(10),
            includesStandardError: false
        )
        if result.wasInterrupted || Task.isCancelled {
            return .interrupted
        }
        guard result.succeeded, let location = RepositoryLocation(revParseOutput: result.output) else {
            return .notRepository
        }
        if rootPaths[projectID] == rootPath {
            repositories[projectID] = location
        }
        return .found(location)
    }

    private func repository(for projectID: UUID) async -> RepositoryLocation? {
        guard let rootPath = rootPaths[projectID],
              case .found(let location) = await lookUpRepository(projectID: projectID, rootPath: rootPath),
              rootPaths[projectID] == rootPath else {
            return nil
        }
        return location
    }

    private func requestRefresh(projectID: UUID) async {
        guard rootPaths[projectID] != nil else { return }
        if refreshingProjects.contains(projectID) {
            pendingRefreshes.insert(projectID)
            return
        }

        refreshingProjects.insert(projectID)
        repeat {
            pendingRefreshes.remove(projectID)
            await refreshOnce(projectID: projectID)
        } while pendingRefreshes.contains(projectID) && rootPaths[projectID] != nil && !Task.isCancelled
        refreshingProjects.remove(projectID)
    }

    private func refreshOnce(projectID: UUID) async {
        guard let rootPath = rootPaths[projectID] else { return }

        let repository: RepositoryLocation
        switch await lookUpRepository(projectID: projectID, rootPath: rootPath) {
        case .found(let location):
            repository = location
        case .interrupted:
            // Like an interrupted status below: keep the last known info.
            return
        case .notRepository:
            let gitInfo = GitInfo()
            if rootPaths[projectID] == rootPath, !Task.isCancelled,
               info[projectID]?.revision != gitInfo.revision {
                info[projectID] = gitInfo
                onInfoChange?(projectID, gitInfo)
            }
            return
        }
        let repositoryRoot = repository.topLevel

        let statusResult = await runGitForResult(
            ["status", "--porcelain=v1", "--branch", "-z"] + repository.pathspecArguments,
            in: repositoryRoot,
            timeout: .seconds(15)
        )
        guard statusResult.succeeded, rootPaths[projectID] == rootPath, !Task.isCancelled else {
            // A cancelled, timed-out or truncated status (e.g. switching
            // projects mid-refresh) says nothing about the repository. Keep
            // the last known info rather than flashing "not a git repo",
            // which would also clear the commit draft and close the panel.
            if statusResult.wasInterrupted || statusResult.wasTruncated || Task.isCancelled {
                return
            }
            if rootPaths[projectID] == rootPath {
                // The repository may have been removed or moved; look it up
                // again on the next refresh.
                repositories[projectID] = nil
                let gitInfo = GitInfo()
                if info[projectID]?.revision != gitInfo.revision {
                    info[projectID] = gitInfo
                    onInfoChange?(projectID, gitInfo)
                }
            }
            return
        }

        // Parsing, building and fingerprinting the snapshot scale with the
        // number of changed files; keep them off the main actor.
        let statusOutput = statusResult.output
        let parsedStatus: GitStatusParser.Status
        do {
            parsedStatus = try await Self.revisionExecutor.run(priority: .utility) {
                GitStatusParser.parseStatus(statusOutput)
            }
        } catch {
            return
        }
        guard rootPaths[projectID] == rootPath, !Task.isCancelled else { return }

        let hasRemote: Bool
        if let cachedRemote = remotePresence[projectID] {
            hasRemote = cachedRemote || !parsedStatus.upstreamBranch.isEmpty
        } else {
            let remoteOutput = await runGit(["remote"], in: repositoryRoot, timeout: .seconds(10))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            remotePresence[projectID] = !remoteOutput.isEmpty
            hasRemote = !remoteOutput.isEmpty || !parsedStatus.upstreamBranch.isEmpty
        }

        let unstagedArguments = ["diff", "--numstat", "-z"] + repository.pathspecArguments
        let stagedArguments = ["diff", "--cached", "--numstat", "-z"] + repository.pathspecArguments
        let unstagedOutput: String
        let stagedOutput: String
        switch (parsedStatus.needsUnstagedStats, parsedStatus.needsStagedStats) {
        case (true, true):
            async let unstaged = runGit(unstagedArguments, in: repositoryRoot, timeout: .seconds(15))
            async let staged = runGit(stagedArguments, in: repositoryRoot, timeout: .seconds(15))
            (unstagedOutput, stagedOutput) = await (unstaged, staged)
        case (true, false):
            unstagedOutput = await runGit(unstagedArguments, in: repositoryRoot, timeout: .seconds(15))
            stagedOutput = ""
        case (false, true):
            unstagedOutput = ""
            stagedOutput = await runGit(stagedArguments, in: repositoryRoot, timeout: .seconds(15))
        case (false, false):
            unstagedOutput = ""
            stagedOutput = ""
        }

        let gitInfo: GitInfo
        do {
            gitInfo = try await Self.revisionExecutor.run(priority: .utility) {
                try Self.makeGitInfo(
                    status: parsedStatus,
                    statusOutput: statusOutput,
                    unstagedOutput: unstagedOutput,
                    stagedOutput: stagedOutput,
                    rootPath: repositoryRoot,
                    hasRemote: hasRemote
                )
            }
        } catch {
            return
        }

        // Equal revisions mean equal snapshots; skip the deep `files` compare.
        guard rootPaths[projectID] == rootPath,
              !Task.isCancelled,
              info[projectID]?.revision != gitInfo.revision else { return }
        info[projectID] = gitInfo
        onInfoChange?(projectID, gitInfo)
    }

    nonisolated private static func makeGitInfo(
        status: GitStatusParser.Status,
        statusOutput: String,
        unstagedOutput: String,
        stagedOutput: String,
        rootPath: String,
        hasRemote: Bool
    ) throws -> GitInfo {
        let contentRevision = try contentRevision(
            statusOutput: statusOutput,
            unstagedOutput: unstagedOutput,
            stagedOutput: stagedOutput,
            rootPath: rootPath,
            paths: status.files.map(\.path)
        )
        try Task.checkCancellation()
        return GitStatusParser.makeInfo(
            status: status,
            unstagedNumstat: GitStatusParser.parseNumstat(unstagedOutput),
            stagedNumstat: GitStatusParser.parseNumstat(stagedOutput),
            hasRemote: hasRemote,
            contentRevision: contentRevision
        )
    }

    private static let maximumUntrackedDiffFiles = 200

    private func untrackedFiles(inDirectory directory: String, rootPath: String, limit: Int) async -> [String] {
        guard limit > 0 else { return [] }
        let result = await runGitForResult(
            ["-c", "core.quotePath=false", "ls-files", "--others", "--exclude-standard", "-z", "--", directory],
            in: rootPath,
            timeout: .seconds(10),
            maximumOutputBytes: 1_024 * 1_024,
            appendsTruncationNotice: false,
            includesStandardError: false
        )
        let paths = result.output
            .split(separator: "\0", omittingEmptySubsequences: true)
            .lazy
            .map(String.init)
            .filter { !$0.hasSuffix("/") }
            .compactMap { self.validatedRelativePath($0) }
            .prefix(limit)
        return Array(paths)
    }

    private func untrackedDiff(
        path: String,
        in directory: String,
        maximumOutputBytes: Int
    ) async -> CommandResult {
        // Stderr (e.g. an unreadable path) must not be appended to the
        // previous file's diff as if it were content.
        await runGitForResult(
            ["-c", "core.quotePath=false", "diff", "--no-ext-diff", "--no-color", "--no-index", "--", "/dev/null", path],
            in: directory,
            timeout: .seconds(15),
            maximumOutputBytes: maximumOutputBytes,
            appendsTruncationNotice: false,
            includesStandardError: false
        )
    }

    private func validatedRelativePath(_ path: String) -> String? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { return nil }
        let components = NSString(string: path).pathComponents
        guard !components.contains("..") else { return nil }
        return path
    }

    private func safeFileURL(path: String, rootPath: String) -> URL? {
        guard let path = validatedRelativePath(path) else { return nil }
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let fileURL = rootURL
            .appendingPathComponent(path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard fileURL.path.hasPrefix(rootPrefix) else { return nil }
        return fileURL
    }

    private func runGit(_ args: [String], in directory: String, timeout: Duration = .seconds(30)) async -> String {
        let result = await GitCommandExecution().run(
            arguments: args,
            directory: directory,
            includeStandardError: false,
            timeout: timeout,
            maximumOutputBytes: 16 * 1_024 * 1_024
        )
        return result.output
    }

    private func runGitForResult(
        _ args: [String],
        in directory: String,
        timeout: Duration = .seconds(30),
        maximumOutputBytes: Int = 16 * 1_024 * 1_024,
        appendsTruncationNotice: Bool = true,
        includesStandardError: Bool = true
    ) async -> CommandResult {
        let result = await GitCommandExecution().run(
            arguments: args,
            directory: directory,
            includeStandardError: includesStandardError,
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes,
            appendsTruncationNotice: appendsTruncationNotice
        )
        return CommandResult(
            succeeded: result.succeeded,
            output: result.output,
            wasTruncated: result.wasTruncated,
            wasInterrupted: result.wasInterrupted
        )
    }

    private func normalizedFailureMessage(_ output: String, fallback: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    nonisolated private static func contentRevision(
        statusOutput: String,
        unstagedOutput: String,
        stagedOutput: String,
        rootPath: String,
        paths: [String]
    ) throws -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037

        func combine(_ value: String) throws {
            for (index, byte) in value.utf8.enumerated() {
                if index.isMultiple(of: 4_096) {
                    try Task.checkCancellation()
                }
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
        }

        try combine(statusOutput)
        try combine(unstagedOutput)
        try combine(stagedOutput)

        let manager = FileManager.default
        for path in paths.sorted() {
            try Task.checkCancellation()
            try combine(path)
            let absolutePath = URL(fileURLWithPath: rootPath, isDirectory: true)
                .appendingPathComponent(path).path
            if let attributes = try? manager.attributesOfItem(atPath: absolutePath) {
                try combine(String(describing: attributes[.size] ?? 0))
                try combine(String(describing: attributes[.modificationDate] ?? ""))
            }
        }

        try Task.checkCancellation()
        if let indexURL = gitIndexURL(rootPath: rootPath),
           let attributes = try? manager.attributesOfItem(atPath: indexURL.path) {
            try combine(String(describing: attributes[.size] ?? 0))
            try combine(String(describing: attributes[.modificationDate] ?? ""))
        }
        try Task.checkCancellation()
        return hash
    }

    nonisolated private static func gitIndexURL(rootPath: String) -> URL? {
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        let dotGitURL = rootURL.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: dotGitURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return dotGitURL.appendingPathComponent("index")
        }

        guard let data = try? Data(contentsOf: dotGitURL),
              let pointer = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              pointer.hasPrefix("gitdir:") else {
            return nil
        }
        let rawPath = String(pointer.dropFirst("gitdir:".count)).trimmingCharacters(in: .whitespaces)
        let gitDirectory = URL(fileURLWithPath: rawPath, relativeTo: rootURL).standardizedFileURL
        return gitDirectory.appendingPathComponent("index")
    }
}
