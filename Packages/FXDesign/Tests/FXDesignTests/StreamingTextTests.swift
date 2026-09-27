import AppKit
import SwiftUI
import Testing
@testable import FXDesign

private func joined(_ rows: FXStreamingTextRows) -> String {
    (rows.rows + [rows.tail]).joined(separator: "\n")
}

@Test func streamingRowsRebuildTheTextAtEveryUpdate() {
    let paragraph = "A sentence that keeps going, with **markdown** and `code`."
    let text = [
        paragraph,
        "",
        "",
        "Second paragraph\nwith a wrapped line",
        "",
        "```swift",
        (0..<30).map { "let value\($0) = \($0)" }.joined(separator: "\n"),
        "```",
        "",
        "Done. ✅ Ünïcödé",
    ].joined(separator: "\n")
    var incremental = FXStreamingTextRows(maximumRowBytes: 64)
    var index = text.startIndex
    while index < text.endIndex {
        index = text.index(index, offsetBy: 7, limitedBy: text.endIndex) ?? text.endIndex
        let prefix = String(text[..<index])
        incremental.update(prefix)
        #expect(joined(incremental) == prefix)
        var fresh = FXStreamingTextRows(maximumRowBytes: 64)
        fresh.update(prefix)
        #expect(fresh.rows == incremental.rows)
        #expect(fresh.tail == incremental.tail)
        #expect(!incremental.rows.contains { $0.allSatisfy(\.isNewline) })
    }
    #expect(incremental.rows.count > 4)
    #expect(incremental.rows.first == paragraph)
    // A row ends at the first line break past the cap.
    #expect(incremental.rows.allSatisfy { $0.utf8.count <= 64 + 64 })
}

@Test func streamingRowsStartOverWhenEarlierTextChanges() {
    var rows = FXStreamingTextRows()
    rows.update("First\n\nSecond\n\nThird")
    #expect(rows.rows == ["First", "\nSecond"])
    // A presentation pass can remove an earlier line (a finished directive).
    rows.update("First\n\nThird and more")
    #expect(rows.rows == ["First"])
    #expect(rows.tail == "\nThird and more")
    rows.update("")
    #expect(rows.rows.isEmpty)
    #expect(rows.tail.isEmpty)
}

@MainActor private func layoutHeight<V: View>(_ view: V, width: CGFloat) -> CGFloat {
    let host = NSHostingView(rootView: view.frame(width: width, alignment: .leading))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
        styleMask: [.borderless], backing: .buffered, defer: false
    )
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    defer { window.contentView = nil }
    return host.fittingSize.height
}

/// The view `MessageBubble` streamed before rows were introduced.
private struct SingleStreamingText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(FXTypography.body)
            .foregroundStyle(FXColors.fg)
            .textSelection(.enabled)
            .lineSpacing(FXSpacing.xs)
            .fixedSize(horizontal: false, vertical: true)
    }
}

@Test @MainActor func streamingTextLaysOutLikeOneText() {
    _ = NSApplication.shared
    let long = String(repeating: "word ", count: 180)
    let samples = [
        "One line",
        "Intro \(long)\n\n\nSecond \(long)\nThird line\n\nEnd",
        (0..<80).map { "line \($0) \($0.isMultiple(of: 9) ? long : "")" }.joined(separator: "\n"),
        "A\n\n\n\nB\n \nC",
    ]
    for text in samples {
        for width in [320.0, 680.0] {
            let single = layoutHeight(SingleStreamingText(text: text), width: width)
            let rows = layoutHeight(FXStreamingText(text), width: width)
            #expect(abs(single - rows) < 0.5, "\(width)pt: \(single) vs \(rows) for \(text.prefix(24).debugDescription)")
        }
    }
}

/// Opt-in, optimized benchmark of stream updates in an offscreen window: the
/// layout and display work of each 50 ms publication. Run with
/// `make benchmark-chat` and compare on the same Mac.
@Test(.enabled(if: ProcessInfo.processInfo.environment["FLOWX_BENCHMARK_CHAT"] == "1"))
@MainActor func benchmarkStreamingTextUpdates() {
    _ = NSApplication.shared
    let paragraph = String(repeating: "The renderer now keeps finished paragraphs stable while text streams. ", count: 8)
    let code = (0..<24).map { "    let value\($0) = compute(\($0)) // explanation" }.joined(separator: "\n")

    struct Result {
        var total = Duration.zero
        var firstQuarter = Duration.zero
        var lastQuarter = Duration.zero
    }
    func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    for blocks in [36, 108] {
        let reply = (0..<blocks).map { index in
            index.isMultiple(of: 6) ? "```swift\n\(code)\n```" : "\(index + 1). \(paragraph)"
        }.joined(separator: "\n\n")
        // About 64 bytes per 50 ms publication.
        var updates: [String] = []
        var end = reply.startIndex
        while end < reply.endIndex {
            end = reply.index(end, offsetBy: 64, limitedBy: reply.endIndex) ?? reply.endIndex
            updates.append(String(reply[..<end]))
        }
        let quarter = updates.count / 4

        func measure<V: View>(_ make: (String) -> V) -> Result {
            let host = NSHostingView(rootView: make(""))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 680, height: 900),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.contentView = host
            let clock = ContinuousClock()
            var result = Result()
            for (index, text) in updates.enumerated() {
                let start = clock.now
                host.rootView = make(text)
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                let elapsed = start.duration(to: clock.now)
                result.total += elapsed
                if index < quarter { result.firstQuarter += elapsed }
                if index >= updates.count - quarter { result.lastQuarter += elapsed }
            }
            window.contentView = nil
            return result
        }

        // Hosted in a scroll view like the transcript. Warm fonts and
        // SwiftUI caches for both, then measure.
        func single(_ text: String) -> some View {
            ScrollView { SingleStreamingText(text: text).frame(width: 680, alignment: .leading) }
        }
        func streaming(_ text: String) -> some View {
            ScrollView { FXStreamingText(text).frame(width: 680, alignment: .leading) }
        }
        _ = measure(single)
        _ = measure(streaming)
        let singleResult = measure(single)
        let rowsResult = measure(streaming)
        func line(_ name: String, _ result: Result) -> String {
            String(
                format: "%@ %.1f ms total, %.2f -> %.2f ms/update (first -> last quarter)",
                name, milliseconds(result.total),
                milliseconds(result.firstQuarter) / Double(quarter),
                milliseconds(result.lastQuarter) / Double(quarter)
            )
        }
        print(String(
            format: "STREAM BENCHMARK: %d KB reply, %d updates: %@; %@; %.1fx",
            reply.utf8.count / 1_024, updates.count,
            line("one Text", singleResult), line("rows", rowsResult),
            milliseconds(singleResult.total) / milliseconds(rowsResult.total)
        ))
    }
}
