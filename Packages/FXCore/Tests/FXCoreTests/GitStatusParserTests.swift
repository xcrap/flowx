import Foundation
import Testing
@testable import FXCore

@Test func gitStatusParserReadsBranchRenamesAndUntrackedFiles() {
    let output = [
        "## main...origin/main [ahead 2, behind 1]",
        " M Sources/App.swift",
        "R  New Name.swift",
        "Old Name.swift",
        "?? notes.txt",
        "MM both.swift",
    ].joined(separator: "\0") + "\0"
    let status = GitStatusParser.parseStatus(output)
    #expect(status.branch == "main")
    #expect(status.upstreamBranch == "origin/main")
    #expect(status.hasCommits)
    #expect(status.aheadCount == 2)
    #expect(status.behindCount == 1)
    #expect(status.files.map(\.path) == ["Sources/App.swift", "New Name.swift", "notes.txt", "both.swift"])
    #expect(status.needsUnstagedStats)
    #expect(status.needsStagedStats)

    let unstaged = GitStatusParser.parseNumstat("3\t1\tSources/App.swift\0" + "1\t1\tboth.swift\0")
    let staged = GitStatusParser.parseNumstat("0\t0\t\0Old Name.swift\0New Name.swift\0" + "2\t0\tboth.swift\0" + "-\t-\timage.png\0")
    #expect(staged["New Name.swift"] == .init(additions: 0, deletions: 0))
    #expect(staged["image.png"] == .init(additions: 0, deletions: 0))

    let info = GitStatusParser.makeInfo(
        status: status,
        unstagedNumstat: unstaged,
        stagedNumstat: staged,
        hasRemote: true,
        contentRevision: 7
    )
    #expect(info.isGitRepo)
    #expect(info.hasRemote)
    #expect(info.contentRevision == 7)
    #expect(info.additions == 6)
    #expect(info.deletions == 2)
    #expect(info.stagedFileCount == 2)
    #expect(info.unstagedFileCount == 3)
    #expect(info.statusFileCount == 4)
    #expect(info.files.first { $0.path == "notes.txt" }?.isUntracked == true)
}

@Test func gitRevisionIdentifiesSnapshotsWithoutComparingFiles() {
    let fixture = GitStatusFixture(fileCount: 50)
    let first = fixture.makeInfo(contentRevision: 11)
    let same = fixture.makeInfo(contentRevision: 11)
    #expect(first == same)
    #expect(first.revision == same.revision)
    #expect(first.revision != GitRepositoryInfo().revision)
    #expect(GitRepositoryInfo().revision == 0)
    #expect(fixture.makeInfo(contentRevision: 12).revision != first.revision)

    let withoutRemote = GitStatusParser.makeInfo(
        status: GitStatusParser.parseStatus(fixture.status),
        unstagedNumstat: GitStatusParser.parseNumstat(fixture.unstagedNumstat),
        stagedNumstat: GitStatusParser.parseNumstat(fixture.stagedNumstat),
        hasRemote: false,
        contentRevision: 11
    )
    #expect(withoutRemote.revision != first.revision)
}

@Test func gitStatusParserReadsUnbornBranches() {
    let status = GitStatusParser.parseStatus("## No commits yet on trunk\0?? a\0")
    #expect(status.branch == "trunk")
    #expect(!status.hasCommits)
    #expect(!status.needsStagedStats)
    #expect(!status.needsUnstagedStats)
}

/// Synthetic output for a large working tree, shaped like git's `-z` output.
struct GitStatusFixture {
    let status: String
    let unstagedNumstat: String
    let stagedNumstat: String

    init(fileCount: Int) {
        var status = ["## feature/performance...origin/feature/performance [ahead 3]"]
        var unstaged: [String] = []
        var staged: [String] = []
        for index in 0..<fileCount {
            let path = "Sources/Module\(index / 50)/Feature\(index % 7)/File\(index).swift"
            switch index % 5 {
            case 0:
                status.append(" M \(path)")
                unstaged.append("\(index % 40)\t\(index % 9)\t\(path)")
            case 1:
                status.append("M  \(path)")
                staged.append("\(index % 30)\t\(index % 4)\t\(path)")
            case 2:
                status.append("MM \(path)")
                unstaged.append("\(index % 12)\t1\t\(path)")
                staged.append("\(index % 20)\t2\t\(path)")
            case 3:
                status.append("?? \(path)")
            default:
                status.append("R  \(path)")
                status.append("Old/\(path)")
                staged.append("1\t1\t\0Old/\(path)\0\(path)")
            }
        }
        self.status = status.joined(separator: "\0") + "\0"
        unstagedNumstat = unstaged.joined(separator: "\0") + "\0"
        stagedNumstat = staged.joined(separator: "\0") + "\0"
    }

    func makeInfo(contentRevision: UInt64) -> GitRepositoryInfo {
        GitStatusParser.makeInfo(
            status: GitStatusParser.parseStatus(status),
            unstagedNumstat: GitStatusParser.parseNumstat(unstagedNumstat),
            stagedNumstat: GitStatusParser.parseNumstat(stagedNumstat),
            hasRemote: true,
            contentRevision: contentRevision
        )
    }
}

func benchmarkMilliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
}

/// Opt-in, optimized benchmark of one unchanged git poll. Run with
/// `make benchmark-git` and compare on the same Mac.
@Test(.enabled(if: ProcessInfo.processInfo.environment["FLOWX_BENCHMARK_GIT"] == "1"))
func benchmarkGitStatusPoll() {
    let clock = ContinuousClock()
    let projectID = UUID()
    for fileCount in [200, 2_000, 10_000] {
        let fixture = GitStatusFixture(fileCount: fileCount)
        let current = fixture.makeInfo(contentRevision: 42)
        let published = [projectID: current]
        var unchanged = 0
        let iterations = 20
        // Parse both outputs, build GitInfo, then deep-compare it with the
        // published value: all of this ran on the main actor before.
        var next = current
        let pipeline = clock.measure {
            for _ in 0..<iterations {
                next = fixture.makeInfo(contentRevision: 42)
                if next == current { unchanged += 1 }
            }
        }
        let deepCompare = clock.measure {
            for _ in 0..<iterations where next != current { unchanged -= 1 }
        }
        // What remains on the main actor for an unchanged poll.
        let revisionIterations = 100_000
        let revisionCompare = clock.measure {
            for _ in 0..<revisionIterations where published[projectID]?.revision != next.revision {
                unchanged -= 1
            }
        }
        #expect(unchanged == iterations)
        print(String(
            format: "GIT POLL BENCHMARK: %5d files: parse + build + deep compare %.3f ms/poll (deep compare %.3f ms); revision compare %.4f us/poll",
            fileCount,
            benchmarkMilliseconds(pipeline) / Double(iterations),
            benchmarkMilliseconds(deepCompare) / Double(iterations),
            benchmarkMilliseconds(revisionCompare) * 1_000 / Double(revisionIterations)
        ))
    }
}
