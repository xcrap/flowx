import Foundation

@Observable
@MainActor
final class GitStatusService {
    struct FileStatus: Equatable, Identifiable {
        var id: String { path }
        var path: String
        var status: String
        var additions: Int
        var deletions: Int
        var isStaged: Bool
        var isUntracked: Bool { status == "??" }
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
        var statusFileCount: Int = 0
        var files: [FileStatus] = []
        var hasChanges: Bool { statusFileCount > 0 }
        var canPush: Bool { isGitRepo && hasRemote && (aheadCount > 0 || (upstreamBranch.isEmpty && hasCommits)) }
    }

    private(set) var info: [UUID: GitInfo] = [:]
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

    func diff(projectID: UUID, path: String) async -> String {
        guard let rootPath = rootPaths[projectID] else { return "" }
        return await runGit(["diff", "--", path], in: rootPath)
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

    func commit(projectID: UUID, message: String, includeUntracked: Bool) async -> Bool {
        guard let rootPath = rootPaths[projectID] else { return false }
        if includeUntracked {
            _ = await runGit(["add", "-A"], in: rootPath)
        } else {
            _ = await runGit(["add", "-u"], in: rootPath)
        }
        let success = await runGitWithStatus(["commit", "-m", message], in: rootPath)
        await refresh(projectID: projectID, rootPath: rootPath)
        return success
    }

    func push(projectID: UUID) async -> Bool {
        guard let rootPath = rootPaths[projectID] else { return false }
        let success = await runGitWithStatus(["push"], in: rootPath)
        await refresh(projectID: projectID, rootPath: rootPath)
        return success
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

        let diffStat = await runGit(["diff", "--shortstat"], in: rootPath)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !diffStat.isEmpty {
            for part in diffStat.components(separatedBy: ",") {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if trimmed.contains("file") {
                    gitInfo.filesChanged = Int(trimmed.components(separatedBy: " ").first ?? "") ?? 0
                } else if trimmed.contains("insertion") {
                    gitInfo.additions = Int(trimmed.components(separatedBy: " ").first ?? "") ?? 0
                } else if trimmed.contains("deletion") {
                    gitInfo.deletions = Int(trimmed.components(separatedBy: " ").first ?? "") ?? 0
                }
            }
        }

        let numstatOutput = await runGit(["diff", "--numstat"], in: rootPath)
        let numstatMap = parseNumstat(numstatOutput)

        let statusOutput = await runGit(["status", "--porcelain"], in: rootPath)
        let statusLines = statusOutput.components(separatedBy: "\n").filter { !$0.isEmpty }
        gitInfo.files = statusLines.compactMap { line in
            guard line.count >= 3 else { return nil }

            let x = String(line.prefix(1))
            let status = String(line.prefix(2)).trimmingCharacters(in: .whitespaces)
            let rawPath = String(line.dropFirst(3))
            let path = rawPath.components(separatedBy: " -> ").last ?? rawPath
            let counts = numstatMap[path] ?? (0, 0)

            return FileStatus(
                path: path,
                status: status.isEmpty ? "?" : status,
                additions: counts.0,
                deletions: counts.1,
                isStaged: x != " " && x != "?"
            )
        }
        gitInfo.statusFileCount = gitInfo.files.count

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

    private func runGitWithStatus(_ args: [String], in directory: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus == 0)
            } catch {
                continuation.resume(returning: false)
            }
        }
    }
}
