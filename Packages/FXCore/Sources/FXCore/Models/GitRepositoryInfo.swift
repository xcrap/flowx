import Foundation

public struct GitFileStatus: Equatable, Identifiable, Sendable {
    public var id: String { path }
    public var path: String
    public var stagedStatus: String
    public var unstagedStatus: String
    public var stagedAdditions: Int
    public var stagedDeletions: Int
    public var unstagedAdditions: Int
    public var unstagedDeletions: Int

    public init(
        path: String,
        stagedStatus: String,
        unstagedStatus: String,
        stagedAdditions: Int,
        stagedDeletions: Int,
        unstagedAdditions: Int,
        unstagedDeletions: Int
    ) {
        self.path = path
        self.stagedStatus = stagedStatus
        self.unstagedStatus = unstagedStatus
        self.stagedAdditions = stagedAdditions
        self.stagedDeletions = stagedDeletions
        self.unstagedAdditions = unstagedAdditions
        self.unstagedDeletions = unstagedDeletions
    }

    public var status: String {
        let combined = "\(stagedStatus)\(unstagedStatus)"
        let trimmed = combined.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "?" : trimmed
    }

    public var additions: Int { stagedAdditions + unstagedAdditions }
    public var deletions: Int { stagedDeletions + unstagedDeletions }
    public var isStaged: Bool { hasStagedChanges }
    public var isUntracked: Bool { stagedStatus == "?" && unstagedStatus == "?" }
    public var hasStagedChanges: Bool { stagedStatus != " " && stagedStatus != "?" }
    public var hasUnstagedChanges: Bool { isUntracked || (unstagedStatus != " " && unstagedStatus != "?") }
}

public struct GitRepositoryInfo: Equatable, Sendable {
    public var isGitRepo: Bool = false
    public var branch: String = ""
    public var upstreamBranch: String = ""
    public var hasRemote: Bool = false
    public var hasCommits: Bool = false
    public var aheadCount: Int = 0
    public var behindCount: Int = 0
    public var additions: Int = 0
    public var deletions: Int = 0
    public var filesChanged: Int = 0
    public var stagedFileCount: Int = 0
    public var unstagedFileCount: Int = 0
    public var statusFileCount: Int = 0
    public var contentRevision: UInt64 = 0
    /// Identity of this snapshot: equal revisions mean equal info, so an
    /// unchanged poll needs no deep comparison of `files`. Zero for the empty
    /// non-repository value.
    public var revision: UInt64 = 0
    public var files: [GitFileStatus] = []

    public init() {}

    public var hasChanges: Bool { statusFileCount > 0 }
    /// Porcelain status reports a detached HEAD as `HEAD (no branch)`.
    public var isDetachedHead: Bool { branch.hasPrefix("HEAD (") }
    public var canPush: Bool {
        isGitRepo && hasRemote && !isDetachedHead
            && (aheadCount > 0 || (upstreamBranch.isEmpty && hasCommits))
    }
}
