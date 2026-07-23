import Foundation

public struct UserMessagePresentation: Equatable, Sendable {
    public let visibleText: String
    public let attachmentFilenames: [String]

    public init(visibleText: String, attachmentFilenames: [String] = []) {
        self.visibleText = visibleText
        self.attachmentFilenames = attachmentFilenames
    }
}

public struct TranscriptDirective: Equatable, Sendable {
    public let name: String
    public let attributes: [String: String]

    public init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    public subscript(attribute: String) -> String? {
        attributes[attribute]
    }
}

public struct AssistantMessagePresentation: Equatable, Sendable {
    public let visibleText: String
    public let directives: [TranscriptDirective]

    public init(visibleText: String, directives: [TranscriptDirective] = []) {
        self.visibleText = visibleText
        self.directives = directives
    }
}

/// Separates provider transport metadata from the human-readable transcript.
/// Provider-native tasks can retain attachment envelopes and Codex app
/// directives in their raw text; those records remain untouched on disk while
/// the UI presents their structured meaning.
public enum TranscriptPresentationParser {
    private static let fileEnvelopeMarkers = [
        "# Files mentioned by the user:",
        "Files mentioned by the user:",
    ]
    private static let requestMarkers = [
        "## My request for Codex:",
        "My request for Codex:",
    ]

    public static func userMessage(_ source: String) -> UserMessagePresentation {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard fileEnvelopeMarkers.contains(where: trimmed.hasPrefix),
              let requestRange = firstRange(of: requestMarkers, in: trimmed) else {
            return UserMessagePresentation(visibleText: source)
        }

        let envelope = String(trimmed[..<requestRange.lowerBound])
        let visibleText = String(trimmed[requestRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let filenames = envelope.components(separatedBy: .newlines).compactMap {
            attachmentFilename(from: $0)
        }

        return UserMessagePresentation(
            visibleText: visibleText,
            attachmentFilenames: filenames
        )
    }

    public static func assistantMessage(_ source: String) -> AssistantMessagePresentation {
        var visibleLines: [String] = []
        var directives: [TranscriptDirective] = []

        for line in source.components(separatedBy: .newlines) {
            if let directive = directive(from: line) {
                directives.append(directive)
            } else {
                visibleLines.append(line)
            }
        }

        return AssistantMessagePresentation(
            visibleText: visibleLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            directives: directives
        )
    }

    private static func firstRange(
        of markers: [String],
        in source: String
    ) -> Range<String.Index>? {
        markers.compactMap { source.range(of: $0) }
            .min { $0.lowerBound < $1.lowerBound }
    }

    private static func attachmentFilename(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("## ") else { return nil }

        let entry = trimmed.dropFirst(3)
        guard let separator = entry.firstIndex(of: ":") else { return nil }
        let filename = entry[..<separator].trimmingCharacters(in: .whitespaces)
        guard !filename.isEmpty else { return nil }
        return filename
    }

    private static func directive(from line: String) -> TranscriptDirective? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("::"),
              trimmed.hasSuffix("}"),
              let openBrace = trimmed.firstIndex(of: "{") else {
            return nil
        }

        let nameStart = trimmed.index(trimmed.startIndex, offsetBy: 2)
        let name = String(trimmed[nameStart..<openBrace])
        guard !name.isEmpty, name.allSatisfy(isDirectiveNameCharacter) else {
            return nil
        }

        let bodyStart = trimmed.index(after: openBrace)
        let bodyEnd = trimmed.index(before: trimmed.endIndex)
        let body = String(trimmed[bodyStart..<bodyEnd])
        guard let attributes = parseAttributes(body) else { return nil }
        return TranscriptDirective(name: name, attributes: attributes)
    }

    private static func isDirectiveNameCharacter(_ character: Character) -> Bool {
        character.isASCII
            && (character.isLowercase || character.isNumber || character == "-")
    }

    private static func parseAttributes(_ source: String) -> [String: String]? {
        let characters = Array(source)
        var attributes: [String: String] = [:]
        var index = 0

        func skippingWhitespace(_ startingIndex: Int) -> Int {
            var next = startingIndex
            while next < characters.count, characters[next].isWhitespace {
                next += 1
            }
            return next
        }

        while true {
            index = skippingWhitespace(index)
            guard index < characters.count else { return attributes }

            let keyStart = index
            while index < characters.count {
                let character = characters[index]
                guard character.isLetter || character.isNumber || character == "_" else {
                    break
                }
                index += 1
            }
            guard index > keyStart else { return nil }
            let key = String(characters[keyStart..<index])

            index = skippingWhitespace(index)
            guard index < characters.count, characters[index] == "=" else { return nil }
            index = skippingWhitespace(index + 1)
            guard index < characters.count else { return nil }

            let value: String
            if characters[index] == "\"" {
                index += 1
                var decoded: [Character] = []
                var closed = false

                while index < characters.count {
                    let character = characters[index]
                    index += 1
                    if character == "\"" {
                        closed = true
                        break
                    }
                    if character == "\\", index < characters.count {
                        let escaped = characters[index]
                        index += 1
                        switch escaped {
                        case "n": decoded.append("\n")
                        case "r": decoded.append("\r")
                        case "t": decoded.append("\t")
                        default: decoded.append(escaped)
                        }
                    } else {
                        decoded.append(character)
                    }
                }

                guard closed else { return nil }
                value = String(decoded)
            } else {
                let valueStart = index
                while index < characters.count, !characters[index].isWhitespace {
                    index += 1
                }
                guard index > valueStart else { return nil }
                value = String(characters[valueStart..<index])
            }

            attributes[key] = value
        }
    }
}
