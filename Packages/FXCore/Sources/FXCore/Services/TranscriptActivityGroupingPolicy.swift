import Foundation

public enum TranscriptActivitySegment: Sendable, Equatable {
    case narrative([ConversationMessage])
    case activity([ConversationMessage])
}

/// Keeps human-readable assistant updates in the transcript while collapsing
/// only contiguous provider tool events into activity groups.
public enum TranscriptActivityGroupingPolicy {
    public static func segments(
        from messages: [ConversationMessage]
    ) -> [TranscriptActivitySegment] {
        guard !messages.isEmpty else { return [] }

        var segments: [TranscriptActivitySegment] = []
        var bufferedMessages: [ConversationMessage] = []
        var bufferingActivity: Bool?

        func flushBuffer() {
            guard !bufferedMessages.isEmpty,
                  let bufferingActivity else {
                return
            }
            segments.append(
                bufferingActivity
                    ? .activity(bufferedMessages)
                    : .narrative(bufferedMessages)
            )
            bufferedMessages.removeAll(keepingCapacity: true)
        }

        for message in messages {
            let isActivity = isActivityOnly(message)
            if let bufferingActivity, bufferingActivity != isActivity {
                flushBuffer()
            }
            bufferingActivity = isActivity
            bufferedMessages.append(message)
        }

        flushBuffer()
        return segments
    }

    public static func isActivityOnly(_ message: ConversationMessage) -> Bool {
        !message.content.isEmpty && message.content.allSatisfy { content in
            switch content {
            case .toolUse(_, let name, _):
                name.caseInsensitiveCompare("AskUserQuestion") != .orderedSame
            case .toolResult:
                true
            case .text, .code, .image, .imageAsset:
                false
            }
        }
    }
}
