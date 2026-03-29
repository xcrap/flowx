import Foundation

@Observable
@MainActor
public final class GitService {
    public var branch: String = ""
    public var changedFiles: Int = 0
    public var isGitRepo: Bool = false
    public var lastError: String?

    private var rootPath: String = ""

    public init() {}

    public func configure(rootPath: String) {
        self.rootPath = rootPath
        refresh()
    }

    public func refresh() {
        guard !rootPath.isEmpty else { return }

        Task {
            let gitDir = await runGit(["rev-parse", "--git-dir"])
            isGitRepo = gitDir != nil

            guard isGitRepo else { return }

            if let branchName = await runGit(["rev-parse", "--abbrev-ref", "HEAD"]) {
                branch = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            if let status = await runGit(["status", "--porcelain"]) {
                changedFiles = status.components(separatedBy: "\n").filter { !$0.isEmpty }.count
            }
        }
    }

    public func commit(message: String) async -> Bool {
        guard await runGit(["add", "-A"]) != nil else { return false }
        guard await runGit(["commit", "-m", message]) != nil else { return false }
        refresh()
        return true
    }

    public func push() async -> Bool {
        guard await runGit(["push"]) != nil else { return false }
        refresh()
        return true
    }

    private func runGit(_ args: [String]) async -> String? {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe
        process.currentDirectoryURL = URL(fileURLWithPath: rootPath)

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                lastError = String(data: data, encoding: .utf8)
                return nil
            }

            return String(data: data, encoding: .utf8)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }
}
