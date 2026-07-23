import Foundation

/// Bounds the complete text assembled for a project diff, including separators
/// between independently collected tracked and untracked patches.
public struct ProjectDiffBudgetPolicy: Sendable {
    public static let defaultMaximumBytes = 16 * 1_024 * 1_024
    public static let truncationNotice =
        "[FlowX truncated this project diff because it exceeded the safe display limit. Remaining changes are not shown.]"

    private let maximumBytes: Int
    private let contentByteLimit: Int
    private var chunks: [String] = []
    private var contentByteCount = 0

    public private(set) var wasTruncated = false

    public init(maximumBytes: Int = Self.defaultMaximumBytes) {
        let reservedNoticeBytes = Self.truncationNotice.utf8.count + 2
        precondition(maximumBytes >= reservedNoticeBytes)
        self.maximumBytes = maximumBytes
        contentByteLimit = maximumBytes - reservedNoticeBytes
    }

    /// Maximum bytes the next command may return without exceeding the
    /// aggregate content budget. The inter-patch separator is included.
    public var remainingFragmentBytes: Int {
        let separatorBytes = chunks.isEmpty ? 0 : 2
        return max(0, contentByteLimit - contentByteCount - separatorBytes)
    }

    /// Appends a complete or command-bounded patch. Returns `false` once no
    /// more sources should be collected.
    @discardableResult
    public mutating func append(
        _ fragment: String,
        sourceWasTruncated: Bool = false
    ) -> Bool {
        let separator = chunks.isEmpty ? "" : "\n\n"
        let fragmentBudget = remainingFragmentBytes
        let boundedFragment = Self.utf8Prefix(fragment, maximumBytes: fragmentBudget)

        if !boundedFragment.isEmpty {
            chunks.append(boundedFragment)
            contentByteCount += separator.utf8.count + boundedFragment.utf8.count
        }

        if sourceWasTruncated || boundedFragment.utf8.count < fragment.utf8.count {
            wasTruncated = true
            return false
        }

        return remainingFragmentBytes > 0
    }

    public mutating func markTruncated() {
        wasTruncated = true
    }

    public var output: String {
        var result = chunks.joined(separator: "\n\n")
        guard wasTruncated else { return result }

        if !result.isEmpty {
            result += "\n\n"
        }
        result += Self.truncationNotice
        assert(result.utf8.count <= maximumBytes)
        return result
    }

    private static func utf8Prefix(_ text: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0 else { return "" }
        guard text.utf8.count > maximumBytes else { return text }

        var byteCount = 0
        var end = text.startIndex
        while end < text.endIndex {
            let next = text.index(after: end)
            let characterByteCount = text[end..<next].utf8.count
            guard byteCount + characterByteCount <= maximumBytes else { break }
            byteCount += characterByteCount
            end = next
        }
        return String(text[..<end])
    }
}
