import Foundation
import Testing
@testable import FXCore

/// Opt-in, optimized benchmark of presentation preparation (not frame rate or
/// model latency). Run with `make benchmark-chat` and compare on the same Mac.
@Test(.enabled(if: ProcessInfo.processInfo.environment["FLOWX_BENCHMARK_CHAT"] == "1"))
func benchmarkTranscriptPreparation() throws {
    let paragraph = String(repeating: "A detailed explanation of the updated project and its rendering behavior.\n", count: 60)
    let baseline = (0..<120).flatMap { index in
        [
            ConversationMessage(role: .user, content: [.text("Prompt \(index)")]),
            ConversationMessage(role: .assistant, content: [.text(paragraph)])
        ]
    }
    let snapshots = (0..<100).map { index in
        var messages = baseline
        messages[messages.count - 1].content = [.text(paragraph + "\nUpdate \(index)")]
        return messages
    }
    func present(_ messages: [ConversationMessage], _ active: Bool) -> [String] {
        messages.map { message in
            message.role == .user
                ? TranscriptPresentationParser.userMessage(message.textContent).visibleText
                : TranscriptPresentationParser.assistantMessage(message.textContent).visibleText
        }
    }
    let clock = ContinuousClock()
    var fullChecksum = 0
    let fullTime = try clock.measure {
        for messages in snapshots {
            var uncached = TranscriptTurnCache<String>()
            fullChecksum += try uncached.render(messages: messages, isRunning: true, transform: present)
                .reduce(0) { $0 + $1.utf8.count }
        }
    }
    var incremental = TranscriptTurnCache<String>()
    _ = try incremental.render(messages: baseline, isRunning: true, transform: present)
    var cachedChecksum = 0
    let cachedTime = try clock.measure {
        for messages in snapshots {
            cachedChecksum += try incremental.render(messages: messages, isRunning: true, transform: present)
                .reduce(0) { $0 + $1.utf8.count }
        }
    }
    #expect(fullChecksum == cachedChecksum)

    // The old no-directive path split, trimmed and rejoined every line, even
    // on every streamed token. The fixture contains no directive syntax.
    let longText = String(repeating: paragraph, count: 30)
    var oldChecksum = 0
    let oldTime = clock.measure {
        for _ in 0..<100 {
            var visible: [String] = []
            for line in longText.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                precondition(!trimmed.hasPrefix("::"))
                visible.append(line)
            }
            oldChecksum += visible.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines).utf8.count
        }
    }
    var newChecksum = 0
    let newTime = clock.measure {
        for _ in 0..<100 {
            newChecksum += TranscriptPresentationParser.assistantMessage(longText).visibleText.utf8.count
        }
    }
    #expect(oldChecksum == newChecksum)
    func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
    print(String(format: "CHAT BENCHMARK: 240 messages, 100 updates: full %.2f ms; cached %.2f ms; %.1fx", milliseconds(fullTime), milliseconds(cachedTime), milliseconds(fullTime) / milliseconds(cachedTime)))
    print(String(format: "TEXT BENCHMARK: %d bytes, 100 parses: old %.2f ms; fast path %.2f ms; %.1fx", longText.utf8.count, milliseconds(oldTime), milliseconds(newTime), milliseconds(oldTime) / milliseconds(newTime)))
}
