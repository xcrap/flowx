import Foundation

/// Parses `git status --porcelain=v1 --branch -z` and `git diff --numstat -z`
/// output into repository info.
public enum GitStatusParser {
    public struct StatusLine: Equatable, Sendable {
        public let path: String
        public let stagedStatus: String
        public let unstagedStatus: String
    }

    public struct Status: Equatable, Sendable {
        public var branch: String = ""
        public var upstreamBranch: String = ""
        public var hasCommits: Bool = true
        public var aheadCount: Int = 0
        public var behindCount: Int = 0
        public var files: [StatusLine] = []
        /// Some file has unstaged edits to a tracked path (`git diff --numstat`).
        public var needsUnstagedStats = false
        /// Some file has staged changes (`git diff --cached --numstat`).
        public var needsStagedStats = false
    }

    public struct LineCounts: Equatable, Sendable {
        public let additions: Int
        public let deletions: Int
    }

    public static func parseStatus(_ output: String) -> Status {
        var snapshot = Status()
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
            snapshot.needsStagedStats = snapshot.needsStagedStats
                || (stagedStatus != " " && stagedStatus != "?")
            snapshot.needsUnstagedStats = snapshot.needsUnstagedStats
                || (unstagedStatus != " " && unstagedStatus != "?")
            snapshot.files.append(
                StatusLine(
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

    public static func parseNumstat(_ output: String) -> [String: LineCounts] {
        var result: [String: LineCounts] = [:]
        let records = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var index = 0

        while index < records.count {
            let parts = records[index].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else {
                index += 1
                continue
            }

            let counts = LineCounts(additions: Int(parts[0]) ?? 0, deletions: Int(parts[1]) ?? 0)
            if !parts[2].isEmpty {
                result[String(parts[2])] = counts
                index += 1
            } else if index + 2 < records.count {
                result[records[index + 2]] = counts
                index += 3
            } else {
                index += 1
            }
        }
        return result
    }

    /// Builds repository info for a successful status read.
    public static func makeInfo(
        status: Status,
        unstagedNumstat: [String: LineCounts],
        stagedNumstat: [String: LineCounts],
        hasRemote: Bool,
        contentRevision: UInt64
    ) -> GitRepositoryInfo {
        var info = GitRepositoryInfo()
        info.isGitRepo = true
        info.branch = status.branch
        info.upstreamBranch = status.upstreamBranch
        info.hasCommits = status.hasCommits
        info.aheadCount = status.aheadCount
        info.behindCount = status.behindCount
        info.hasRemote = hasRemote
        info.files = status.files.map { line in
            let unstaged = unstagedNumstat[line.path]
            let staged = stagedNumstat[line.path]
            return GitFileStatus(
                path: line.path,
                stagedStatus: line.stagedStatus,
                unstagedStatus: line.unstagedStatus,
                stagedAdditions: staged?.additions ?? 0,
                stagedDeletions: staged?.deletions ?? 0,
                unstagedAdditions: unstaged?.additions ?? 0,
                unstagedDeletions: unstaged?.deletions ?? 0
            )
        }
        info.stagedFileCount = info.files.filter(\.hasStagedChanges).count
        info.unstagedFileCount = info.files.filter(\.hasUnstagedChanges).count
        info.statusFileCount = info.files.count
        info.filesChanged = info.files.count
        info.additions = info.files.reduce(into: 0) { $0 += $1.additions }
        info.deletions = info.files.reduce(into: 0) { $0 += $1.deletions }
        info.contentRevision = contentRevision
        info.revision = revision(contentRevision: contentRevision, hasRemote: hasRemote)
        return info
    }

    /// Every field of a successful read derives from the git output hashed
    /// into `contentRevision`, plus remote presence. Never zero, which is the
    /// revision of the empty non-repository value.
    static func revision(contentRevision: UInt64, hasRemote: Bool) -> UInt64 {
        var hash = contentRevision ^ 0x9E37_79B9_7F4A_7C15
        hash = (hash ^ (hasRemote ? 0xA5 : 0x5A)) &* 1_099_511_628_211
        return hash == 0 ? 1 : hash
    }

    private static func parseBranchHeader(_ header: String, into snapshot: inout Status) {
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
}
