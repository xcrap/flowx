import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FXAgent
@testable import FXCore

/// Serves chronological turns as newest-first `thread/turns/list` pages.
private final class FakeTurnPages {
    let newestFirst: [[String: Any]]
    let repeatsCursor: Bool
    private(set) var fetches = 0

    init(chronological: [[String: Any]], repeatsCursor: Bool = false) {
        newestFirst = chronological.reversed()
        self.repeatsCursor = repeatsCursor
    }

    func fetch(_ cursor: String?, _ limit: Int) -> (page: [[String: Any]], nextCursor: String?) {
        fetches += 1
        let start = cursor.flatMap(Int.init) ?? 0
        let end = min(newestFirst.count, start + limit)
        let page = start < end ? Array(newestFirst[start..<end]) : []
        if repeatsCursor { return (page, "0") }
        return (page, end < newestFirst.count ? String(end) : nil)
    }
}

/// The pre-optimization loop: convert every accumulated turn after every page.
private func referencePaginatedMessages(
    thread: [String: Any],
    pages source: FakeTurnPages
) -> (messages: [ConversationMessage], convertedTurns: Int) {
    var pages = CodexNativeTurnPageAccumulator(maximumTurns: 128)
    var cursor: String?
    var messages: [ConversationMessage] = []
    var convertedTurns = 0
    repeat {
        let page = source.fetch(cursor, min(16, 128 - pages.newestFirstTurns.count))
        cursor = pages.append(page: page.page, nextCursor: page.nextCursor)
        var boundedThread = thread
        boundedThread["turns"] = pages.chronologicalTurns
        messages = CodexProvider.mapNativeMessagesForTesting(boundedThread, deferLocalImages: true)
        convertedTurns += pages.newestFirstTurns.count
    } while cursor != nil && messages.count < 250
    return (messages, convertedTurns)
}

private func pngDataURL(side: Int, seed: Int) throws -> String {
    let context = try #require(CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    // Deterministic noise so PNG compression leaves a screenshot-sized file.
    var state = UInt32(truncatingIfNeeded: seed &* 2_654_435_761 &+ 1)
    for y in stride(from: 0, to: side, by: 2) {
        for x in stride(from: 0, to: side, by: 2) {
            state = state &* 1_664_525 &+ 1_013_904_223
            context.setFillColor(
                red: CGFloat(state & 0xFF) / 255,
                green: CGFloat((state >> 8) & 0xFF) / 255,
                blue: CGFloat((state >> 16) & 0xFF) / 255,
                alpha: 1
            )
            context.fill(CGRect(x: x, y: y, width: 2, height: 2))
        }
    }
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        data, UTType.png.identifier as CFString, 1, nil
    ))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return "data:image/png;base64," + (data as Data).base64EncodedString()
}

private func turn(_ index: Int, id: Bool = true, items: [[String: Any]]) -> [String: Any] {
    var turn: [String: Any] = [
        "startedAt": 1_700_000_000 + index * 10,
        "completedAt": 1_700_000_000 + index * 10 + 5,
        "items": items,
    ]
    if id { turn["id"] = "turn-id-\(index)" }
    return turn
}

private func assertPaginationMatchesReference(
    _ turns: [[String: Any]],
    repeatsCursor: Bool = false,
    expectedFetches: Int,
    expectedConversions: Int? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let thread: [String: Any] = ["id": "thread-pagination"]
    let referenceSource = FakeTurnPages(chronological: turns, repeatsCursor: repeatsCursor)
    let expected = referencePaginatedMessages(thread: thread, pages: referenceSource)
    let source = FakeTurnPages(chronological: turns, repeatsCursor: repeatsCursor)
    let actual = try await CodexProvider.paginatedNativeMessagesForTesting(thread: thread) {
        source.fetch($0, $1)
    }
    #expect(actual.messages == expected.messages, sourceLocation: sourceLocation)
    #expect(source.fetches == referenceSource.fetches, sourceLocation: sourceLocation)
    #expect(source.fetches == expectedFetches, sourceLocation: sourceLocation)
    // Converting once is the goal; image-only prompts near the message
    // limit may need an exact conversion, but never more than before.
    #expect(actual.convertedTurns <= expected.convertedTurns, sourceLocation: sourceLocation)
    if let expectedConversions {
        #expect(actual.convertedTurns == expectedConversions, sourceLocation: sourceLocation)
    }
}

@Test func codexPaginationMatchesFullReconversionForTextAndImages() async throws {
    let image = try pngDataURL(side: 24, seed: 1)
    let turns = (0..<128).map { index -> [String: Any] in
        var content: [[String: Any]] = [["type": "text", "text": "Prompt \(index)"]]
        if index.isMultiple(of: 4) { content.append(["type": "image", "url": image]) }
        return turn(index, items: [
            ["id": "user-\(index)", "type": "userMessage", "content": content],
            ["id": "agent-\(index)", "type": "agentMessage", "text": "Reply \(index)"],
        ])
    }
    try await assertPaginationMatchesReference(turns, expectedFetches: 8, expectedConversions: 128)
}

@Test func codexPaginationStopsOnTheSamePageForToolHeavyTurns() async throws {
    let turns = (0..<128).map { index -> [String: Any] in
        turn(index, id: !index.isMultiple(of: 3), items: [
            ["type": "userMessage", "content": [["type": "text", "text": "Run \(index)"]]],
            ["type": "reasoning", "summary": ["thinking"]],
            ["type": "commandExecution", "command": "ls", "aggregatedOutput": "a\nb"],
            ["type": "commandExecution", "command": "true", "aggregatedOutput": " \n\t "],
            ["type": "commandExecution", "command": "true", "aggregatedOutput": "  Completed \n"],
            ["type": "fileChange", "changes": [["path": "a.swift", "kind": "update"]]],
            ["type": "mcpToolCall", "output": NSNull()],
            ["type": "unknown", "name": "custom"],
            ["type": "agentMessage", "text": ""],
        ])
    }
    // Ten messages per turn: 160 after the first page, 320 after the second.
    try await assertPaginationMatchesReference(turns, expectedFetches: 2, expectedConversions: 32)
}

@Test func codexPaginationResolvesImageOnlyPromptsExactly() async throws {
    let valid = try pngDataURL(side: 8, seed: 2)
    let invalid = "data:image/png;base64,AAAA"
    // Two certain messages per turn plus one image-only prompt: pages 6 and 7
    // are only decidable by decoding the images.
    for (images, pages) in [([valid], 6), ([invalid], 8), ([valid, invalid], 7)] {
        let turns = (0..<128).map { index -> [String: Any] in
            let url = images[index % images.count]
            return turn(index, id: index.isMultiple(of: 2), items: [
                ["type": "userMessage", "content": [
                    ["type": "image", "url": url],
                    ["type": "localImage", "path": "/nonexistent/flowx-\(index).png"],
                    ["type": "text", "text": ""],
                ]],
                ["type": "agentMessage", "text": "One \(index)"],
                ["type": "agentMessage", "text": "Two \(index)"],
            ])
        }
        try await assertPaginationMatchesReference(turns, expectedFetches: pages)
    }
}

@Test func codexPaginationHandlesEmptyMalformedAndRepeatedPages() async throws {
    try await assertPaginationMatchesReference([], expectedFetches: 1)
    let malformed = (0..<40).map { index -> [String: Any] in
        var turn = turn(index, items: [])
        turn["items"] = [["type": "agentMessage", "text": "Dropped \(index)"], "not an item"] as [Any]
        return turn
    }
    try await assertPaginationMatchesReference(malformed, expectedFetches: 3)
    let repeated = (0..<40).map { index in
        turn(index, items: [["type": "agentMessage", "text": "Repeated \(index)"]])
    }
    try await assertPaginationMatchesReference(repeated, repeatsCursor: true, expectedFetches: 2)
}

/// Opt-in, optimized benchmark of native Codex transcript loading.
/// Run with `make benchmark-chat` and compare on the same Mac.
@Test(.enabled(if: ProcessInfo.processInfo.environment["FLOWX_BENCHMARK_CHAT"] == "1"))
func benchmarkCodexNativeTurnPagination() async throws {
    // 128 turns of prompt + reply; every fourth prompt carries a screenshot.
    // 256 messages means every page is fetched before the 250 bound is met.
    let images = try (0..<4).map { try pngDataURL(side: 320, seed: $0) }
    let turns = (0..<128).map { index -> [String: Any] in
        var content: [[String: Any]] = [["type": "text", "text": "Prompt \(index)"]]
        if index.isMultiple(of: 4) { content.append(["type": "image", "url": images[index / 4 % 4]]) }
        return turn(index, items: [
            ["id": "user-\(index)", "type": "userMessage", "content": content],
            ["id": "agent-\(index)", "type": "agentMessage", "text": String(repeating: "Reply \(index). ", count: 40)],
        ])
    }
    let thread: [String: Any] = ["id": "thread-benchmark"]
    let clock = ContinuousClock()
    func median(_ durations: [Duration]) -> Double {
        let median = durations.sorted()[durations.count / 2]
        return Double(median.components.seconds) * 1_000 + Double(median.components.attoseconds) / 1e15
    }

    // Before: the previous loop, converting every accumulated turn per page.
    var referenceDurations: [Duration] = []
    var reference: (messages: [ConversationMessage], convertedTurns: Int) = ([], 0)
    for _ in 0..<7 {
        let source = FakeTurnPages(chronological: turns)
        let start = clock.now
        reference = referencePaginatedMessages(thread: thread, pages: source)
        referenceDurations.append(start.duration(to: clock.now))
    }

    var durations: [Duration] = []
    var result: (messages: [ConversationMessage], convertedTurns: Int) = ([], 0)
    var fetches = 0
    for _ in 0..<7 {
        let source = FakeTurnPages(chronological: turns)
        let start = clock.now
        result = try await CodexProvider.paginatedNativeMessagesForTesting(thread: thread) {
            source.fetch($0, $1)
        }
        durations.append(start.duration(to: clock.now))
        fetches = source.fetches
    }
    #expect(result.messages.count == 250)
    #expect(result.messages == reference.messages)
    let imageBytes = images.reduce(0) { $0 + $1.utf8.count }
    print(String(
        format: "CODEX PAGINATION BENCHMARK: 128 turns, %d pages, 32 images (~%d KB base64 each): convert every page %.2f ms (%d turn conversions); convert once %.2f ms (%d turn conversions); %.1fx",
        fetches, imageBytes / 4 / 1_024,
        median(referenceDurations), reference.convertedTurns,
        median(durations), result.convertedTurns,
        median(referenceDurations) / median(durations)
    ))
}
