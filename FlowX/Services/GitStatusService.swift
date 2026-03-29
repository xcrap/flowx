import Foundation

@Observable
@MainActor
final class GitStatusService {
    struct CommandResult {
        var succeeded: Bool
        var output: String
    }

    struct FileStatus: Equatable, Identifiable {
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

    struct GitInfo: Equatable {
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
        var files: [FileStatus] = []
        var hasChanges: Bool { statusFileCount > 0 }
        var canPush: Bool { isGitRepo && hasRemote && (aheadCount > 0 || (upstreamBranch.isEmpty && hasCommits)) }
    }

    private(set) var info: [UUID: GitInfo] = [:]
    private(set) var lastFailureMessage: [UUID: String] = [:]
    private var pollingTasks: [UUID: Task<Void, Never>] = [:]
    private var rootPaths: [UUID: String] = [:]

    func startPolling(projectID: UUID, rootPath: String) {
        rootPaths[projectID] = rootPath
        guard pollingTasks[projectID] == nil else { return }
        pollingTasks[projectID] = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(projectID: projectID, rootPath: rootPath)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stopPolling(projectID: UUID) {
        pollingTasks[projectID]?.cancel()
        pollingTasks.removeValue(forKey: projectID)
    }

    func stopAll() {
        for (_, task) in pollingTasks {
            task.cancel()
        }
        pollingTasks.removeAll()
    }

    func forceRefresh(projectID: UUID) {
        guard let rootPath = rootPaths[projectID] else { return }
        Task {
            await refresh(projectID: projectID, rootPath: rootPath)
        }
    }

    func diffUnstaged(projectID: UUID, path: String) async -> String {
        guard let rootPath = rootPaths[projectID] else { return "" }
        return await runGit(["diff", "--no-ext-diff", "--no-color", "--", path], in: rootPath)
    }

    func diffStaged(projectID: UUID, path: String) async -> String {
        guard let rootPath = rootPaths[projectID] else { return "" }
        return await runGit(["diff", "--no-ext-diff", "--no-color", "--cached", "--", path], in: rootPath)
    }

    func diffAgainstHead(projectID: UUID, path: String) async -> String {
        guard let rootPath = rootPaths[projectID] else { return "" }
        return await runGit(["diff", "--no-ext-diff", "--no-color", "HEAD", "--", path], in: rootPath)
    }

    func projectDiff(projectID: UUID, mode: InspectorComparisonMode, files: [FileStatus]) async -> String {
        guard let rootPath = rootPaths[projectID] else { return "" }

        var chunks: [String] = []
        let sortedFiles = files.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        let trackedPaths = sortedFiles.filter { !($0.isUntracked && mode != .staged) }.map(\.path)
        let untrackedPaths = sortedFiles.filter { $0.isUntracked && mode != .staged }.map(\.path)

        if !trackedPaths.isEmpty {
            let args: [String]
            switch mode {
            case .unstaged:
                args = ["diff", "--no-ext-diff", "--no-color", "--"] + trackedPaths
            case .staged:
                args = ["diff", "--no-ext-diff", "--no-color", "--cached", "--"] + trackedPaths
            case .base:
                args = ["diff", "--no-ext-diff", "--no-color", "HEAD", "--"] + trackedPaths
            }

            let trackedDiff = await runGit(args, in: rootPath).trimmingCharacters(in: .whitespacesAndNewlines)
            if !trackedDiff.isEmpty {
                chunks.append(trackedDiff)
            }
        }

        for path in untrackedPaths {
            let diff = await untrackedDiff(path: path, in: rootPath)
            let trimmed = diff.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                chunks.append(trimmed)
            }
        }

        return chunks.joined(separator: "\n\n")
    }

    func fileContents(projectID: UUID, path: String) async -> String {
        guard let rootPath = rootPaths[projectID] else { return "" }
        let url = URL(fileURLWithPath: rootPath).appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text
    }

    func fileContentsAtHead(projectID: UUID, path: String) async -> String? {
        guard let rootPath = rootPaths[projectID] else { return nil }
        let result = await runGitForResult(["show", "HEAD:\(path)"], in: rootPath)
        guard result.succeeded else { return nil }
        return result.output
    }

    func fileContentsFromIndex(projectID: UUID, path: String) async -> String? {
        guard let rootPath = rootPaths[projectID] else { return nil }
        let result = await runGitForResult(["show", ":\(path)"], in: rootPath)
        guard result.succeeded else { return nil }
        return result.output
    }

    func commit(projectID: UUID, message: String, includeUntracked: Bool) async -> Bool {
        guard let rootPath = rootPaths[projectID] else { return false }

        let addResult: CommandResult
        if includeUntracked {
            addResult = await runGitForResult(["add", "-A"], in: rootPath)
        } else {
            addResult = await runGitForResult(["add", "-u"], in: rootPath)
        }
        guard addResult.succeeded else {
            lastFailureMessage[projectID] = normalizedFailureMessage(addResult.output, fallback: "Unable to stage changes.")
            await refresh(projectID: projectID, rootPath: rootPath)
            return false
        }

        let commitResult = await runGitForResult(["commit", "-m", message], in: rootPath)
        if !commitResult.succeeded {
            lastFailureMessage[projectID] = normalizedFailureMessage(commitResult.output, fallback: "Commit failed.")
        } else {
            lastFailureMessage[projectID] = nil
        }

        await refresh(projectID: projectID, rootPath: rootPath)
        return commitResult.succeeded
    }

    func push(projectID: UUID) async -> Bool {
        guard let rootPath = rootPaths[projectID] else { return false }
        let result = await runGitForResult(["push"], in: rootPath)
        if !result.succeeded {
            lastFailureMessage[projectID] = normalizedFailureMessage(result.output, fallback: "Push failed.")
        } else {
            lastFailureMessage[projectID] = nil
        }
        await refresh(projectID: projectID, rootPath: rootPath)
        return result.succeeded
    }

    private func refresh(projectID: UUID, rootPath: String) async {
        rootPaths[projectID] = rootPath

        let gitDir = await runGit(["rev-parse", "--git-dir"], in: rootPath)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var gitInfo = GitInfo()
        gitInfo.isGitRepo = !gitDir.isEmpty

        guard gitInfo.isGitRepo else {
            info[projectID] = gitInfo
            return
        }

        gitInfo.branch = await runGit(["rev-parse", "--abbrev-ref", "HEAD"], in: rootPath)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let remoteOutput = await runGit(["remote"], in: rootPath)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        gitInfo.hasRemote = !remoteOutput.isEmpty

        let commitCountOutput = await runGit(["rev-list", "--count", "HEAD"], in: rootPath)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        gitInfo.hasCommits = (Int(commitCountOutput) ?? 0) > 0

        gitInfo.upstreamBranch = await runGit(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
            in: rootPath
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)

        if !gitInfo.upstreamBranch.isEmpty {
            let aheadBehindOutput = await runGit(
                ["rev-list", "--left-right", "--count", "HEAD...@{upstream}"],
                in: rootPath
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

            let counts = aheadBehindOutput
                .split(whereSeparator: \.isWhitespace)
                .compactMap { Int($0) }
            if counts.count >= 2 {
                gitInfo.aheadCount = counts[0]
                gitInfo.behindCount = counts[1]
            }
        }

        let unstagedNumstatMap = parseNumstat(await runGit(["diff", "--numstat"], in: rootPath))
        let stagedNumstatMap = parseNumstat(await runGit(["diff", "--cached", "--numstat"], in: rootPath))

        let statusOutput = await runGit(["status", "--porcelain"], in: rootPath)
        let statusLines = statusOutput.components(separatedBy: "\n").filter { !$0.isEmpty }
        gitInfo.files = statusLines.compactMap { line in
            guard line.count >= 3 else { return nil }

            let x = String(line.prefix(1))
            let y = String(line.dropFirst(1).prefix(1))
            let rawPath = String(line.dropFirst(3))
            let path = rawPath.components(separatedBy: " -> ").last ?? rawPath
            let unstagedCounts = unstagedNumstatMap[path] ?? (0, 0)
            let stagedCounts = stagedNumstatMap[path] ?? (0, 0)

            return FileStatus(
                path: path,
                stagedStatus: x,
                unstagedStatus: y,
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

        info[projectID] = gitInfo
    }

    private func parseNumstat(_ output: String) -> [String: (Int, Int)] {
        var result: [String: (Int, Int)] = [:]
        for line in output.components(separatedBy: "\n") where !line.isEmpty {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3 else { continue }
            let additions = Int(parts[0]) ?? 0
            let deletions = Int(parts[1]) ?? 0
            result[parts[2]] = (additions, deletions)
        }
        return result
    }

    private func untrackedDiff(path: String, in directory: String) async -> String {
        let result = await runGitForResult(
            ["diff", "--no-ext-diff", "--no-color", "--no-index", "--", "/dev/null", path],
            in: directory
        )
        return result.output
    }

    private func runGit(_ args: [String], in directory: String) async -> String {
        await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            } catch {
                continuation.resume(returning: "")
            }
        }
    }

    private func runGitForResult(_ args: [String], in directory: String) async -> CommandResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: CommandResult(succeeded: process.terminationStatus == 0, output: output))
            } catch {
                continuation.resume(returning: CommandResult(succeeded: false, output: error.localizedDescription))
            }
        }
    }

    private func normalizedFailureMessage(_ output: String, fallback: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
