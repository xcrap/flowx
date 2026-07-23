import Darwin
import AppKit
import Foundation
import FXCore

private struct GitProcessResult: Sendable {
    var succeeded: Bool
    var output: String
    var wasTruncated: Bool
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
            return GitProcessResult(succeeded: false, output: "", wasTruncated: false)
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
            wasTruncated: wasTruncated
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

    private struct ParsedStatusLine {
        let path: String
        let stagedStatus: String
        let unstagedStatus: String
    }

    private struct ParsedStatusSnapshot {
        var branch: String = ""
        var upstreamBranch: String = ""
        var hasCommits: Bool = true
        var aheadCount: Int = 0
        var behindCount: Int = 0
        var files: [ParsedStatusLine] = []
    }

    struct CommandResult: Sendable {
        var succeeded: Bool
        var output: String
        var wasTruncated: Bool = false
    }

    struct FileStatus: Equatable, Identifiable, Sendable {
        var id: String { path }
        var path: String
        var stagedStatus: String
        var unstagedStatus: String
        var stagedAdditions: Int
        var stagedDeletions: Int
        var unstagedAdditions: Int
        var unstagedDeletions: Int

        var status: String {
            let combined = "\(stagedStatus)\(unstagedStatus)"
            let trimmed = combined.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? "?" : trimmed
        }

        var additions: Int { stagedAdditions + unstagedAdditions }
        var deletions: Int { stagedDeletions + unstagedDeletions }
        var isStaged: Bool { hasStagedChanges }
        var isUntracked: Bool { stagedStatus == "?" && unstagedStatus == "?" }
        var hasStagedChanges: Bool { stagedStatus != " " && stagedStatus != "?" }
        var hasUnstagedChanges: Bool { isUntracked || (unstagedStatus != " " && unstagedStatus != "?") }
    }

    struct GitInfo: Equatable, Sendable {
        var isGitRepo: Bool = false
        var branch: String = ""
        var upstreamBranch: String = ""
        var hasRemote: Bool = false
        var hasCommits: Bool = false
        var aheadCount: Int = 0
        var behindCount: Int = 0
        var additions: Int = 0
        var deletions: Int = 0
        var filesChanged: Int = 0
        var stagedFileCount: Int = 0
        var unstagedFileCount: Int = 0
        var statusFileCount: Int = 0
        var contentRevision: UInt64 = 0
        var files: [FileStatus] = []
        var hasChanges: Bool { statusFileCount > 0 }
        var canPush: Bool { isGitRepo && hasRemote && (aheadCount > 0 || (upstreamBranch.isEmpty && hasCommits)) }
    }

    private(set) var info: [UUID: GitInfo] = [:]
    private(set) var lastFailureMessage: [UUID: String] = [:]
    var onInfoChange: ((UUID, GitInfo) -> Void)?
    private var pollingTasks: [UUID: Task<Void, Never>] = [:]
    private var rootPaths: [UUID: String] = [:]
    private var remotePresence: [UUID: Bool] = [:]
    private var refreshingProjects: Set<UUID> = []
    private var pendingRefreshes: Set<UUID> = []
    private var forceRefreshTasks: [UUID: Task<Void, Never>] = [:]

    func startPolling(projectID: UUID, rootPath: String) {
        let normalizedPath = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL.path
        if rootPaths[projectID] != normalizedPath {
            remotePresence[projectID] = nil
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
        guard let rootPath = rootPaths[projectID], let path = validatedRelativePath(path) else { return "" }
        return await runGit(["-c", "core.quotePath=false", "diff", "--no-ext-diff", "--no-color", "--", path], in: rootPath)
    }

    func diffStaged(projectID: UUID, path: String) async -> String {
        guard let rootPath = rootPaths[projectID], let path = validatedRelativePath(path) else { return "" }
        return await runGit(["-c", "core.quotePath=false", "diff", "--no-ext-diff", "--no-color", "--cached", "--", path], in: rootPath)
    }

    func diffAgainstHead(projectID: UUID, path: String) async -> String {
        guard let rootPath = rootPaths[projectID], let path = validatedRelativePath(path) else { return "" }
        return await runGit(["-c", "core.quotePath=false", "diff", "--no-ext-diff", "--no-color", "HEAD", "--", path], in: rootPath)
    }

    func projectDiff(projectID: UUID, mode: InspectorComparisonMode, files: [FileStatus]) async -> String {
        guard let rootPath = rootPaths[projectID] else { return "" }

        var budget = ProjectDiffBudgetPolicy()
        let sortedFiles = files.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        let untrackedPaths = sortedFiles
            .filter { $0.isUntracked && mode != .staged }
            .compactMap { validatedRelativePath($0.path) }

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
                args,
                in: rootPath,
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
                in: rootPath,
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

    func fileContents(projectID: UUID, path: String) async -> String {
        guard let rootPath = rootPaths[projectID],
              let url = safeFileURL(path: path, rootPath: rootPath) else {
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
        guard let rootPath = rootPaths[projectID], let path = validatedRelativePath(path) else { return nil }
        let result = await runGitForResult(["show", "HEAD:\(path)"], in: rootPath)
        guard result.succeeded else { return nil }
        return result.output
    }

    func fileContentsFromIndex(projectID: UUID, path: String) async -> String? {
        guard let rootPath = rootPaths[projectID], let path = validatedRelativePath(path) else { return nil }
        let result = await runGitForResult(["show", ":\(path)"], in: rootPath)
        guard result.succeeded else { return nil }
        return result.output
    }

    func commit(projectID: UUID, message: String, includeUntracked: Bool) async -> Bool {
        guard let rootPath = rootPaths[projectID] else { return false }

        let addResult = await runGitForResult(
            includeUntracked ? ["add", "-A"] : ["add", "-u"],
            in: rootPath
        )
        guard addResult.succeeded else {
            lastFailureMessage[projectID] = normalizedFailureMessage(addResult.output, fallback: "Unable to stage changes.")
            pendingRefreshes.insert(projectID)
            await requestRefresh(projectID: projectID)
            return false
        }

        let commitResult = await runGitForResult(["commit", "-m", message], in: rootPath, timeout: .seconds(120))
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
        guard let rootPath = rootPaths[projectID] else { return false }
        let result = await runGitForResult(["push"], in: rootPath, timeout: .seconds(120))
        if !result.succeeded {
            lastFailureMessage[projectID] = normalizedFailureMessage(result.output, fallback: "Push failed.")
        } else {
            lastFailureMessage[projectID] = nil
        }
        pendingRefreshes.insert(projectID)
        await requestRefresh(projectID: projectID)
        return result.succeeded
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

        var gitInfo = GitInfo()
        let statusResult = await runGitForResult(
            ["status", "--porcelain=v1", "--branch", "-z"],
            in: rootPath,
            timeout: .seconds(15)
        )
        guard statusResult.succeeded, rootPaths[projectID] == rootPath, !Task.isCancelled else {
            if rootPaths[projectID] == rootPath, info[projectID] != gitInfo {
                info[projectID] = gitInfo
                onInfoChange?(projectID, gitInfo)
            }
            return
        }
        gitInfo.isGitRepo = true

        let parsedStatus = parseStatusOutput(statusResult.output)
        gitInfo.branch = parsedStatus.branch
        gitInfo.upstreamBranch = parsedStatus.upstreamBranch
        gitInfo.hasCommits = parsedStatus.hasCommits
        gitInfo.aheadCount = parsedStatus.aheadCount
        gitInfo.behindCount = parsedStatus.behindCount

        if let cachedRemote = remotePresence[projectID] {
            gitInfo.hasRemote = cachedRemote || !gitInfo.upstreamBranch.isEmpty
        } else {
            let remoteOutput = await runGit(["remote"], in: rootPath, timeout: .seconds(10))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let hasRemote = !remoteOutput.isEmpty
            remotePresence[projectID] = hasRemote
            gitInfo.hasRemote = hasRemote || !gitInfo.upstreamBranch.isEmpty
        }

        let needsUnstagedStats = parsedStatus.files.contains {
            $0.unstagedStatus != " " && $0.unstagedStatus != "?"
        }
        let needsStagedStats = parsedStatus.files.contains {
            $0.stagedStatus != " " && $0.stagedStatus != "?"
        }

        let unstagedOutput: String
        let stagedOutput: String
        if needsUnstagedStats && needsStagedStats {
            async let unstaged = runGit(["diff", "--numstat", "-z"], in: rootPath, timeout: .seconds(15))
            async let staged = runGit(["diff", "--cached", "--numstat", "-z"], in: rootPath, timeout: .seconds(15))
            (unstagedOutput, stagedOutput) = await (unstaged, staged)
        } else if needsUnstagedStats {
            unstagedOutput = await runGit(["diff", "--numstat", "-z"], in: rootPath, timeout: .seconds(15))
            stagedOutput = ""
        } else if needsStagedStats {
            unstagedOutput = ""
            stagedOutput = await runGit(["diff", "--cached", "--numstat", "-z"], in: rootPath, timeout: .seconds(15))
        } else {
            unstagedOutput = ""
            stagedOutput = ""
        }

        let unstagedNumstatMap = parseNumstat(unstagedOutput)
        let stagedNumstatMap = parseNumstat(stagedOutput)
        gitInfo.files = parsedStatus.files.map { line in
            let unstagedCounts = unstagedNumstatMap[line.path] ?? (0, 0)
            let stagedCounts = stagedNumstatMap[line.path] ?? (0, 0)
            return FileStatus(
                path: line.path,
                stagedStatus: line.stagedStatus,
                unstagedStatus: line.unstagedStatus,
                stagedAdditions: stagedCounts.0,
                stagedDeletions: stagedCounts.1,
                unstagedAdditions: unstagedCounts.0,
                unstagedDeletions: unstagedCounts.1
            )
        }
        gitInfo.stagedFileCount = gitInfo.files.filter(\.hasStagedChanges).count
        gitInfo.unstagedFileCount = gitInfo.files.filter(\.hasUnstagedChanges).count
        gitInfo.statusFileCount = gitInfo.files.count
        gitInfo.filesChanged = gitInfo.files.count
        gitInfo.additions = gitInfo.files.reduce(into: 0) { $0 += $1.additions }
        gitInfo.deletions = gitInfo.files.reduce(into: 0) { $0 += $1.deletions }

        let paths = gitInfo.files.map(\.path)
        do {
            gitInfo.contentRevision = try await Self.revisionExecutor.run(priority: .utility) {
                try Self.contentRevision(
                    statusOutput: statusResult.output,
                    unstagedOutput: unstagedOutput,
                    stagedOutput: stagedOutput,
                    rootPath: rootPath,
                    paths: paths
                )
            }
        } catch {
            return
        }

        guard rootPaths[projectID] == rootPath, !Task.isCancelled, info[projectID] != gitInfo else { return }
        info[projectID] = gitInfo
        onInfoChange?(projectID, gitInfo)
    }

    private func parseNumstat(_ output: String) -> [String: (Int, Int)] {
        var result: [String: (Int, Int)] = [:]
        let records = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var index = 0

        while index < records.count {
            let parts = records[index].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else {
                index += 1
                continue
            }

            let additions = Int(parts[0]) ?? 0
            let deletions = Int(parts[1]) ?? 0
            if !parts[2].isEmpty {
                result[String(parts[2])] = (additions, deletions)
                index += 1
            } else if index + 2 < records.count {
                result[records[index + 2]] = (additions, deletions)
                index += 3
            } else {
                index += 1
            }
        }
        return result
    }

    private func untrackedDiff(
        path: String,
        in directory: String,
        maximumOutputBytes: Int
    ) async -> CommandResult {
        await runGitForResult(
            ["-c", "core.quotePath=false", "diff", "--no-ext-diff", "--no-color", "--no-index", "--", "/dev/null", path],
            in: directory,
            timeout: .seconds(15),
            maximumOutputBytes: maximumOutputBytes,
            appendsTruncationNotice: false
        )
    }

    private func parseStatusOutput(_ output: String) -> ParsedStatusSnapshot {
        var snapshot = ParsedStatusSnapshot()
        let records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var index = 0

        while index < records.count {
            let rawLine = records[index]
            if rawLine.hasPrefix("## ") {
                parseBranchHeader(String(rawLine.dropFirst(3)), into: &snapshot)
                index += 1
                continue
            }

            guard rawLine.count >= 3 else {
                index += 1
                continue
            }
            let stagedStatus = String(rawLine.prefix(1))
            let unstagedStatus = String(rawLine.dropFirst(1).prefix(1))
            snapshot.files.append(
                ParsedStatusLine(
                    path: String(rawLine.dropFirst(3)),
                    stagedStatus: stagedStatus,
                    unstagedStatus: unstagedStatus
                )
            )

            if stagedStatus == "R" || stagedStatus == "C" || unstagedStatus == "R" || unstagedStatus == "C" {
                index += 2
            } else {
                index += 1
            }
        }
        return snapshot
    }

    private func parseBranchHeader(_ header: String, into snapshot: inout ParsedStatusSnapshot) {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("No commits yet on ") {
            snapshot.branch = String(trimmed.dropFirst("No commits yet on ".count))
            snapshot.hasCommits = false
            return
        }
        if trimmed.hasPrefix("Initial commit on ") {
            snapshot.branch = String(trimmed.dropFirst("Initial commit on ".count))
            snapshot.hasCommits = false
            return
        }

        snapshot.hasCommits = true
        let statusComponents = trimmed.components(separatedBy: " [")
        let branchComponent = statusComponents[0]
        if let upstreamRange = branchComponent.range(of: "...") {
            snapshot.branch = String(branchComponent[..<upstreamRange.lowerBound])
            snapshot.upstreamBranch = String(branchComponent[upstreamRange.upperBound...])
        } else {
            snapshot.branch = branchComponent
        }

        guard statusComponents.count > 1 else { return }
        let summary = statusComponents[1].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        for part in summary.components(separatedBy: ", ") {
            if part.hasPrefix("ahead "), let count = Int(part.dropFirst("ahead ".count)) {
                snapshot.aheadCount = count
            } else if part.hasPrefix("behind "), let count = Int(part.dropFirst("behind ".count)) {
                snapshot.behindCount = count
            }
        }
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
            wasTruncated: result.wasTruncated
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
