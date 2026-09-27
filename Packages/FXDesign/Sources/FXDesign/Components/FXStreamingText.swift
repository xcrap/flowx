import SwiftUI

/// Splits growing text into finished rows and a trailing row, so an update
/// that appends text only rescans and re-lays out the trailing row.
///
/// Rows break at a line break that starts a blank line (a finished
/// paragraph), or at any line break once a paragraph exceeds
/// `maximumRowBytes`, which keeps long code blocks and lists bounded. The
/// break itself is dropped: stacked with the text's line spacing, the rows lay
/// out exactly like one `Text` of the whole string.
struct FXStreamingTextRows {
    private(set) var rows: [String] = []
    private(set) var tail = ""
    let maximumRowBytes: Int

    private var source = ""
    /// UTF-8 offset where the trailing row begins.
    private var rowStart = 0
    /// UTF-8 offset up to which `source` has been scanned.
    private var scanned = 0
    private var rowHasContent = false

    init(maximumRowBytes: Int = 2_048) {
        self.maximumRowBytes = max(1, maximumRowBytes)
    }

    mutating func update(_ text: String) {
        var text = text
        if !continues(text) {
            rows.removeAll(keepingCapacity: true)
            rowStart = 0
            scanned = 0
            rowHasContent = false
        }
        text.withUTF8 { bytes in
            var index = scanned
            while index < bytes.count {
                if bytes[index] == 0x0A {
                    // Deciding needs the next byte; rescan this break later.
                    guard index + 1 < bytes.count else { break }
                    if rowHasContent, bytes[index + 1] == 0x0A || index - rowStart >= maximumRowBytes {
                        rows.append(String(decoding: UnsafeBufferPointer(rebasing: bytes[rowStart..<index]), as: UTF8.self))
                        rowStart = index + 1
                        rowHasContent = false
                    }
                } else {
                    rowHasContent = true
                }
                index += 1
            }
            scanned = index
            tail = String(decoding: UnsafeBufferPointer(rebasing: bytes[rowStart...]), as: UTF8.self)
        }
        source = text
    }

    /// Whether `text` extends the scanned part of the previous text unchanged.
    private mutating func continues(_ text: String) -> Bool {
        guard scanned > 0 else { return true }
        guard text.utf8.count >= scanned else { return false }
        var text = text
        let length = scanned
        return source.withUTF8 { old in
            text.withUTF8 { new in
                memcmp(old.baseAddress!, new.baseAddress!, length) == 0
            }
        }
    }
}

/// Body text that is still being written. Finished paragraphs render as
/// cached rows, so each update lays out only the paragraph being appended to
/// instead of the whole reply. Looks the same as one `Text` of `text`.
public struct FXStreamingText: View {
    private let text: String
    @State private var cache = Cache()

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        let rows = cache.rows(for: text)
        // Sealed chunks keep the stack SwiftUI diffs and places short.
        let chunkCount = (rows.rows.count + Self.rowsPerChunk - 1) / Self.rowsPerChunk
        VStack(alignment: .leading, spacing: Self.lineSpacing) {
            ForEach(0..<chunkCount, id: \.self) { chunk in
                let start = chunk * Self.rowsPerChunk
                Chunk(rows: Array(rows.rows[start..<min(start + Self.rowsPerChunk, rows.rows.count)]))
                    .equatable()
            }
            if !rows.tail.isEmpty {
                Row(text: rows.tail)
            }
        }
        .textSelection(.enabled)
    }

    static let lineSpacing = FXSpacing.xs
    private static let rowsPerChunk = 16

    @MainActor
    private final class Cache {
        private var rows = FXStreamingTextRows()

        func rows(for text: String) -> FXStreamingTextRows {
            rows.update(text)
            return rows
        }
    }

    private struct Chunk: View, Equatable {
        let rows: [String]

        var body: some View {
            VStack(alignment: .leading, spacing: FXStreamingText.lineSpacing) {
                ForEach(rows.indices, id: \.self) { index in
                    Row(text: rows[index])
                        .equatable()
                }
            }
        }
    }

    private struct Row: View, Equatable {
        let text: String

        var body: some View {
            Text(text)
                .font(FXTypography.body)
                .foregroundStyle(FXColors.fg)
                .lineSpacing(FXStreamingText.lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
