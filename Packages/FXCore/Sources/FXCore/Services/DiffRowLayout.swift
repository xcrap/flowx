import Foundation

/// Indexes a diff without flattening or copying its code lines on disclosure.
/// Memory and rebuild cost depend on the file count, not the line count.
public struct DiffRowLayout: Sendable {
    public struct Location: Equatable, Sendable {
        public let section: Int
        /// Nil identifies the section header.
        public let line: Int?
    }

    private let starts: [Int]
    public let count: Int

    public init(lineCounts: [Int], collapsedSections: Set<Int>) {
        var starts: [Int] = []
        starts.reserveCapacity(lineCounts.count)
        var count = 0
        for (section, lines) in lineCounts.enumerated() {
            starts.append(count)
            count += 1 + (collapsedSections.contains(section) ? 0 : max(0, lines))
        }
        self.starts = starts
        self.count = count
    }

    public func headerRow(for section: Int) -> Int? {
        starts.indices.contains(section) ? starts[section] : nil
    }

    public func location(at row: Int) -> Location? {
        guard row >= 0, row < count else { return nil }
        var lower = 0
        var upper = starts.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if starts[middle] <= row { lower = middle + 1 } else { upper = middle }
        }
        let section = lower - 1
        let offset = row - starts[section]
        return Location(section: section, line: offset == 0 ? nil : offset - 1)
    }
}
