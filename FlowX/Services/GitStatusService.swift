import Foundation

@Observable
@MainActor
final class GitStatusService {
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
    var onInfoChange: ((UUID, GitInfo) -> Void)?
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
        let untrackedPaths = sortedFiles.filter { $0.isUntracked && mode != .staged }.map(\.path)

        if sortedFiles.contains(where: { !($0.isUntracked && mode != .staged) }) {
            let args: [String]
            switch mode {
            case .unstaged:
                args = ["diff", "--no-ext-diff", "--no-color"]
            case .staged:
                args = ["diff", "--no-ext-diff", "--no-color", "--cached"]
            case .base:
                args = ["diff", "--no-ext-diff", "--no-color", "HEAD"]
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

        var gitInfo = GitInfo()
        let statusResult = await runGitForResult(["status", "--porcelain", "--branch"], in: rootPath)
        guard statusResult.succeeded else {
            if info[projectID] != gitInfo {
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

        let remoteOutput = await runGit(["remote"], in: rootPath)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        gitInfo.hasRemote = !remoteOutput.isEmpty || !gitInfo.upstreamBranch.isEmpty

        let unstagedNumstatMap = parseNumstat(await runGit(["diff", "--numstat"], in: rootPath))
        let stagedNumstatMap = parseNumstat(await runGit(["diff", "--cached", "--numstat"], in: rootPath))
        gitInfo.files = parsedStatus.files.map { line in
            let path = line.path
            let unstagedCounts = unstagedNumstatMap[path] ?? (0, 0)
            let stagedCounts = stagedNumstatMap[path] ?? (0, 0)

            return FileStatus(
                path: path,
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

        guard info[projectID] != gitInfo else { return }
        info[projectID] = gitInfo
        onInfoChange?(projectID, gitInfo)
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

    private func parseStatusOutput(_ output: String) -> ParsedStatusSnapshot {
        var snapshot = ParsedStatusSnapshot()

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let rawLine = String(line)
            if rawLine.hasPrefix("## ") {
                parseBranchHeader(String(rawLine.dropFirst(3)), into: &snapshot)
                continue
            }

            guard rawLine.count >= 3 else { continue }
            snapshot.files.append(
                ParsedStatusLine(
                    path: normalizedStatusPath(from: String(rawLine.dropFirst(3))),
                    stagedStatus: String(rawLine.prefix(1)),
                    unstagedStatus: String(rawLine.dropFirst(1).prefix(1))
                )
            )
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
            if part.hasPrefix("ahead "),
               let count = Int(part.dropFirst("ahead ".count)) {
                snapshot.aheadCount = count
            } else if part.hasPrefix("behind "),
                      let count = Int(part.dropFirst("behind ".count)) {
                snapshot.behindCount = count
            }
        }
    }

    private func normalizedStatusPath(from rawPath: String) -> String {
        rawPath.components(separatedBy: " -> ").last ?? rawPath
    }

    private func runGit(_ args: [String], in directory: String) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = args
                process.currentDirectoryURL = URL(fileURLWithPath: directory)
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
                } catch {
                    continuation.resume(returning: "")
                }
            }
        }
    }

    private func runGitForResult(_ args: [String], in directory: String) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = args
                process.currentDirectoryURL = URL(fileURLWithPath: directory)
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(returning: CommandResult(succeeded: process.terminationStatus == 0, output: output))
                } catch {
                    continuation.resume(returning: CommandResult(succeeded: false, output: error.localizedDescription))
                }
            }
        }
    }

    private func normalizedFailureMessage(_ output: String, fallback: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
