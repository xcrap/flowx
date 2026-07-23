import Foundation
import Testing
@testable import FXCore

@Test func projectDiffBudgetIncludesEveryFragmentAndSeparator() {
    var budget = ProjectDiffBudgetPolicy(maximumBytes: 256)

    let appendedBinary = budget.append(
        "diff --git a/a b/a\nBinary files /dev/null and b/a differ"
    )
    let appendedText = budget.append("diff --git a/b b/b\n+small text patch")
    #expect(appendedBinary)
    #expect(appendedText)
    #expect(!budget.wasTruncated)
    #expect(
        budget.output
            == "diff --git a/a b/a\nBinary files /dev/null and b/a differ"
                + "\n\ndiff --git a/b b/b\n+small text patch"
    )
    #expect(budget.output.utf8.count <= 256)
}

@Test func projectDiffBudgetEmitsOneNoticeAndNeverExceedsItsByteLimit() {
    let maximumBytes = 256
    var budget = ProjectDiffBudgetPolicy(maximumBytes: maximumBytes)
    let oversized = String(repeating: "x", count: maximumBytes * 2)

    let shouldContinue = budget.append(oversized, sourceWasTruncated: true)
    #expect(!shouldContinue)

    let output = budget.output
    #expect(output.utf8.count <= maximumBytes)
    #expect(
        output.components(separatedBy: ProjectDiffBudgetPolicy.truncationNotice).count - 1 == 1
    )
}

@Test func projectDiffBudgetDoesNotSplitExtendedCharacters() {
    var budget = ProjectDiffBudgetPolicy(maximumBytes: 192)
    let oversized = String(repeating: "image 🖼️ ", count: 100)

    let shouldContinue = budget.append(oversized)
    #expect(!shouldContinue)
    #expect(String(data: Data(budget.output.utf8), encoding: .utf8) == budget.output)
    #expect(budget.output.utf8.count <= 192)
}
