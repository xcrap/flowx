import CryptoKit
import Foundation

public struct ConversationImageCorrelationKey: Codable, Sendable, Equatable, Hashable {
    public var promptDigest: String
    public var reverseOccurrence: Int

    public init(promptDigest: String, reverseOccurrence: Int) {
        self.promptDigest = promptDigest
        self.reverseOccurrence = reverseOccurrence
    }
}

public enum ConversationImageCorrelation {
    /// Correlates FlowX's local user message with the provider-native copy.
    /// Counting from newest to oldest keeps the visible tail stable when long
    /// provider threads are bounded.
    public static func keysByMessageID(
        in messages: [ConversationMessage]
    ) -> [UUID: ConversationImageCorrelationKey] {
        keysByMessageID(in: messages, imageMessagesOnly: false)
    }

    /// Correlates only prompts that actually contain an image (or a native
    /// provider image marker). Text-only prompts with identical wording must
    /// not shift an image's occurrence index and inherit its asset.
    public static func imageKeysByMessageID(
        in messages: [ConversationMessage]
    ) -> [UUID: ConversationImageCorrelationKey] {
        keysByMessageID(in: messages, imageMessagesOnly: true)
    }

    public static func containsImage(_ message: ConversationMessage) -> Bool {
        message.content.contains { content in
            switch content {
            case .image, .imageAsset:
                true
            case .text(let text):
                text.split(whereSeparator: \.isNewline).contains { line in
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed == "[Image]" || trimmed.hasPrefix("Attached image:")
                }
            default:
                false
            }
        }
    }

    private static func keysByMessageID(
        in messages: [ConversationMessage],
        imageMessagesOnly: Bool
    ) -> [UUID: ConversationImageCorrelationKey] {
        var occurrences: [String: Int] = [:]
        var result: [UUID: ConversationImageCorrelationKey] = [:]
        for message in messages.reversed() where message.role == .user {
            if imageMessagesOnly, !containsImage(message) { continue }
            let digest = promptDigest(for: message)
            let occurrence = occurrences[digest, default: 0]
            result[message.id] = ConversationImageCorrelationKey(
                promptDigest: digest,
                reverseOccurrence: occurrence
            )
            occurrences[digest] = occurrence + 1
        }
        return result
    }

    public static func promptDigest(for message: ConversationMessage) -> String {
        let normalized = normalizedPrompt(for: message)
        return SHA256.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public static func normalizedPrompt(for message: ConversationMessage) -> String {
        let text = message.content.compactMap { content -> String? in
            guard case .text(let value) = content else { return nil }
            return value
        }.joined(separator: "\n")

        return text
            .split(whereSeparator: \.isNewline)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed != "[Image]" && !trimmed.hasPrefix("Attached image:")
            }
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
