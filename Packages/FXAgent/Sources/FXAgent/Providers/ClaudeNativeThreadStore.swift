import Foundation
import FXCore

actor ClaudeNativeThreadStore {
    static let defaultMaximumThreadResults = 500
    private static let maximumSummaryBytes = 1 * 1_024 * 1_024
    static let defaultMaximumTranscriptBytes = 32 * 1_024 * 1_024
    static let defaultMaximumSummaryCacheEntries = 2_000
    private static let maximumJSONLineBytes = 4 * 1_024 * 1_024
    private static let maximumMessages = 250
    private let configuredRoot: URL?
    private let maximumTranscriptBytes: Int
    private let maximumThreadResults: Int
    private let maximumSummaryCacheEntries: Int
    private var summaryCache: [String: CachedSummary] = [:]
    private var summaryParseCount = 0
    private var summaryAccessCounter: UInt64 = 0

    init(
        configRoot: URL? = nil,
        maximumTranscriptBytes: Int = ClaudeNativeThreadStore.defaultMaximumTranscriptBytes,
        maximumThreadResults: Int = ClaudeNativeThreadStore.defaultMaximumThreadResults,
        maximumSummaryCacheEntries: Int = ClaudeNativeThreadStore.defaultMaximumSummaryCacheEntries
    ) {
        configuredRoot = configRoot
        self.maximumTranscriptBytes = max(1, maximumTranscriptBytes)
        self.maximumThreadResults = max(1, maximumThreadResults)
        self.maximumSummaryCacheEntries = max(1, maximumSummaryCacheEntries)
    }

    private struct FileFingerprint: Equatable {
        var size: Int
        var modificationDate: Date?
    }

    private struct CachedSummary {
        var fingerprint: FileFingerprint
        var summary: ProviderNativeThreadSummary?
        var lastAccess: UInt64
    }

    private struct ParsedSession {
        var sessionID: String?
        var cwd: String?
        var nativeTitle: String?
        var firstPrompt: String?
        var lastPrompt: String?
        var model: String?
        var createdAt: Date?
        var updatedAt: Date?
        var messages: [ConversationMessage] = []
    }

    func list(
        workingDirectory: URL,
        limit: Int
    ) throws -> [ProviderNativeThreadSummary] {
        try Task.checkCancellation()
        let configuredDirectory = try Self.standardizedDirectory(workingDirectory)
        let canonicalDirectory = configuredDirectory.resolvingSymlinksInPath().standardizedFileURL
        let projectDirectories = projectDirectories(
            configuredDirectory: configuredDirectory,
            canonicalDirectory: canonicalDirectory
        )
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .creationDateKey,
        ]

        var candidatesByPath: [String: (URL, URLResourceValues)] = [:]
        for projectDirectory in projectDirectories {
            try Task.checkCancellation()
            guard manager.fileExists(atPath: projectDirectory.path) else {
                pruneSummaryCache(in: projectDirectory, keeping: [])
                continue
            }
            let urls = try manager.contentsOfDirectory(
                at: projectDirectory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
            var candidates: [(URL, URLResourceValues)] = []
            for url in urls {
                try Task.checkCancellation()
                guard url.pathExtension.lowercased() == "jsonl",
                      let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true else {
                    continue
                }
                candidates.append((url, values))
            }
            let paths = Set(candidates.map { $0.0.standardizedFileURL.path })
            pruneSummaryCache(in: projectDirectory, keeping: paths)
            for candidate in candidates {
                candidatesByPath[candidate.0.standardizedFileURL.path] = candidate
            }
        }
        let candidates = candidatesByPath.values
            .sorted { ($0.1.contentModificationDate ?? .distantPast) > ($1.1.contentModificationDate ?? .distantPast) }

        let boundedLimit = min(max(limit, 1), maximumThreadResults)
        var summaries: [String: ProviderNativeThreadSummary] = [:]
        for (url, values) in candidates {
            try Task.checkCancellation()
            guard let summary = try summary(
                for: url,
                values: values,
                canonicalDirectory: canonicalDirectory
            ) else { continue }
            if summaries[summary.id] == nil { summaries[summary.id] = summary }
            if summaries.count >= boundedLimit { break }
        }
        return summaries.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    func read(
        id: String,
        workingDirectory: URL?
    ) throws -> ProviderNativeThread {
        try Task.checkCancellation()
        guard let workingDirectory else {
            throw Self.error("A workspace is required to read a Claude Code session safely.")
        }
        guard Self.isSafeSessionID(id) else { throw Self.error("Invalid Claude Code session id.") }
        let configuredDirectory = try Self.standardizedDirectory(workingDirectory)
        let canonicalDirectory = configuredDirectory.resolvingSymlinksInPath().standardizedFileURL
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]
        var match: (file: URL, summary: ProviderNativeThreadSummary)?
        for projectDirectory in projectDirectories(
            configuredDirectory: configuredDirectory,
            canonicalDirectory: canonicalDirectory
        ) {
            try Task.checkCancellation()
            let file = projectDirectory.appendingPathComponent(id).appendingPathExtension("jsonl")
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let summary = try summary(
                    for: file,
                    values: values,
                    canonicalDirectory: canonicalDirectory
                  ), summary.id == id else {
                continue
            }
            if match == nil || summary.updatedAt > match!.summary.updatedAt {
                match = (file, summary)
            }
        }
        guard let match else { throw Self.error("Claude Code session '\(id)' was not found for this workspace.") }

        let data = try Self.readTailData(from: match.file, maximumBytes: maximumTranscriptBytes)
        try Task.checkCancellation()
        let parsed = try Self.parse(data: data, includeMessages: true)
        if let parsedCWD = parsed.cwd,
           Self.canonicalPath(parsedCWD) != canonicalDirectory.path {
            throw Self.error("Claude Code session '\(id)' does not belong to this workspace.")
        }
        guard parsed.sessionID == nil || parsed.sessionID == id else {
            throw Self.error("Claude Code session '\(id)' does not belong to this workspace.")
        }
        return ProviderNativeThread(summary: match.summary, messages: Array(parsed.messages.suffix(Self.maximumMessages)))
    }

    func summaryCacheStatisticsForTesting() -> (entries: Int, parses: Int) {
        (summaryCache.count, summaryParseCount)
    }

    private func pruneSummaryCache(in projectDirectory: URL, keeping paths: Set<String>) {
        let projectPath = projectDirectory.standardizedFileURL.path
        summaryCache = summaryCache.filter { path, _ in
            URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path != projectPath
                || paths.contains(path)
        }
    }

    private func summary(
        for file: URL,
        values: URLResourceValues,
        canonicalDirectory: URL
    ) throws -> ProviderNativeThreadSummary? {
        let key = file.standardizedFileURL.path
        let fingerprint = FileFingerprint(
            size: values.fileSize ?? 0,
            modificationDate: values.contentModificationDate
        )
        if var cached = summaryCache[key], cached.fingerprint == fingerprint {
            summaryAccessCounter &+= 1
            cached.lastAccess = summaryAccessCounter
            summaryCache[key] = cached
            return cached.summary
        }

        let data = try Self.readSummaryData(from: file, size: fingerprint.size)
        try Task.checkCancellation()
        summaryParseCount += 1
        let parsed = try Self.parse(data: data, includeMessages: false)
        try Task.checkCancellation()
        let summary: ProviderNativeThreadSummary?
        if let sessionID = parsed.sessionID ?? Self.sessionID(from: file),
           let cwd = parsed.cwd,
           Self.canonicalPath(cwd) == canonicalDirectory.path {
            let firstPrompt = Self.nonEmpty(parsed.firstPrompt)
            let lastPrompt = Self.nonEmpty(parsed.lastPrompt) ?? firstPrompt
            let createdAt = parsed.createdAt ?? values.creationDate ?? values.contentModificationDate ?? .distantPast
            let updatedAt = parsed.updatedAt ?? values.contentModificationDate ?? createdAt
            summary = ProviderNativeThreadSummary(
                providerID: "claude",
                id: sessionID,
                title: Self.title(from: Self.nonEmpty(parsed.nativeTitle) ?? firstPrompt ?? lastPrompt),
                preview: String((lastPrompt ?? "").prefix(500)),
                workingDirectory: canonicalDirectory.path,
                createdAt: createdAt,
                updatedAt: updatedAt,
                model: parsed.model,
                effort: nil,
                status: "native",
                source: "claude-jsonl"
            )
        } else {
            summary = nil
        }
        summaryAccessCounter &+= 1
        summaryCache[key] = CachedSummary(
            fingerprint: fingerprint,
            summary: summary,
            lastAccess: summaryAccessCounter
        )
        trimSummaryCacheIfNeeded()
        return summary
    }

    private func trimSummaryCacheIfNeeded() {
        guard summaryCache.count > maximumSummaryCacheEntries else { return }
        // Evict a small batch so walking several new workspaces does not sort
        // the entire cache once per inserted transcript.
        let batchSize = max(1, maximumSummaryCacheEntries / 10)
        let removalCount = max(summaryCache.count - maximumSummaryCacheEntries, batchSize)
        let oldestKeys = summaryCache.sorted {
            if $0.value.lastAccess != $1.value.lastAccess {
                return $0.value.lastAccess < $1.value.lastAccess
            }
            return $0.key < $1.key
        }.prefix(removalCount).map(\.key)
        for key in oldestKeys {
            summaryCache[key] = nil
        }
    }

    private static func parse(data: Data, includeMessages: Bool) throws -> ParsedSession {
        var parsed = ParsedSession()
        var lineStart = data.startIndex
        var lineCount = 0
        while lineStart < data.endIndex {
            if lineCount.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            let lineEnd = data[lineStart...].firstIndex(of: 0x0A) ?? data.endIndex
            let rawLine = data[lineStart..<lineEnd]
            lineStart = lineEnd < data.endIndex ? data.index(after: lineEnd) : data.endIndex
            lineCount += 1
            guard !rawLine.isEmpty else { continue }
            guard rawLine.count <= maximumJSONLineBytes,
                  let object = try? JSONSerialization.jsonObject(with: Data(rawLine)) as? [String: Any] else { continue }
            let type = object["type"] as? String ?? ""
            if let sessionID = object["sessionId"] as? String { parsed.sessionID = sessionID }
            if let cwd = object["cwd"] as? String { parsed.cwd = cwd }
            if let timestamp = date(object["timestamp"] as? String) {
                parsed.createdAt = min(parsed.createdAt ?? timestamp, timestamp)
                parsed.updatedAt = max(parsed.updatedAt ?? timestamp, timestamp)
            }

            switch type {
            case "ai-title":
                if let title = nonEmpty(object["aiTitle"] as? String) { parsed.nativeTitle = title }
            case "custom-title":
                if let title = nonEmpty(
                    (object["customTitle"] as? String)
                        ?? (object["title"] as? String)
                        ?? (object["name"] as? String)
                ) {
                    parsed.nativeTitle = title
                }
            case "last-prompt":
                if let prompt = object["lastPrompt"] as? String { parsed.lastPrompt = prompt }
            case "user":
                guard let message = object["message"] as? [String: Any] else { continue }
                let contents = userContents(message["content"])
                let promptText = contents.compactMap { content -> String? in
                    if case .text(let text) = content { return text }
                    return nil
                }.joined(separator: "\n")
                if nonEmpty(parsed.firstPrompt) == nil, let prompt = nonEmpty(promptText) {
                    parsed.firstPrompt = prompt
                }
                if let prompt = nonEmpty(promptText) { parsed.lastPrompt = prompt }
                guard includeMessages, !contents.isEmpty else { continue }
                let isOnlyToolResults = contents.allSatisfy {
                    if case .toolResult = $0 { return true }
                    return false
                }
                parsed.messages.append(ConversationMessage(
                    id: nativeUUID(object["uuid"] as? String),
                    role: isOnlyToolResults ? .tool : .user,
                    content: contents,
                    timestamp: date(object["timestamp"] as? String) ?? .distantPast
                ))
            case "assistant":
                guard let message = object["message"] as? [String: Any] else { continue }
                if let model = message["model"] as? String { parsed.model = model }
                guard includeMessages else { continue }
                let contents = assistantContents(message["content"])
                guard !contents.isEmpty else { continue }
                parsed.messages.append(ConversationMessage(
                    id: nativeUUID(object["uuid"] as? String),
                    role: .assistant,
                    content: contents,
                    timestamp: date(object["timestamp"] as? String) ?? .distantPast
                ))
            default:
                continue
            }
        }
        try Task.checkCancellation()
        return parsed
    }

    private static func userContents(_ value: Any?) -> [MessageContent] {
        if let text = value as? String {
            return nonEmpty(text).map { [.text(bounded($0, maximum: 256 * 1_024))] } ?? []
        }
        guard let blocks = value as? [[String: Any]] else { return [] }
        return blocks.compactMap { block in
            switch block["type"] as? String {
            case "text":
                return (block["text"] as? String)
                    .flatMap(nonEmpty)
                    .map { .text(bounded($0, maximum: 256 * 1_024)) }
            case "tool_result":
                let content = contentString(block["content"])
                return .toolResult(
                    id: block["tool_use_id"] as? String ?? "",
                    content: bounded(content, maximum: 65_536),
                    isError: block["is_error"] as? Bool ?? false
                )
            case "image":
                return .text("[Image]")
            default:
                return nil
            }
        }
    }

    private static func assistantContents(_ value: Any?) -> [MessageContent] {
        guard let blocks = value as? [[String: Any]] else { return [] }
        return blocks.compactMap { block in
            switch block["type"] as? String {
            case "text":
                return (block["text"] as? String)
                    .flatMap(nonEmpty)
                    .map { .text(bounded($0, maximum: 256 * 1_024)) }
            case "tool_use":
                return .toolUse(
                    id: block["id"] as? String ?? "",
                    name: block["name"] as? String ?? "Tool",
                    input: bounded(jsonString(block["input"]) ?? "{}", maximum: 32_768)
                )
            default:
                return nil
            }
        }
    }

    private static func readSummaryData(from url: URL, size: Int) throws -> Data {
        guard size > maximumSummaryBytes else { return try Data(contentsOf: url, options: [.mappedIfSafe]) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let half = maximumSummaryBytes / 2
        let head = try handle.read(upToCount: half) ?? Data()
        try handle.seek(toOffset: UInt64(max(0, size - half)))
        var tail = try handle.readToEnd() ?? Data()
        if let newline = tail.firstIndex(of: 0x0A) { tail.removeSubrange(tail.startIndex...newline) }
        return head + Data([0x0A]) + tail
    }

    private static func readTailData(from url: URL, maximumBytes: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let size = values.fileSize ?? 0
        guard size > maximumBytes else { return try Data(contentsOf: url, options: [.mappedIfSafe]) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(size - maximumBytes))
        var data = try handle.readToEnd() ?? Data()
        if let newline = data.firstIndex(of: 0x0A) { data.removeSubrange(data.startIndex...newline) }
        return data
    }

    private func projectDirectories(
        configuredDirectory: URL,
        canonicalDirectory: URL
    ) -> [URL] {
        var seenPaths: Set<String> = []
        return [configuredDirectory.path, canonicalDirectory.path].compactMap { path in
            guard seenPaths.insert(path).inserted else { return nil }
            return projectDirectory(forPath: path)
        }
    }

    private func projectDirectory(forPath path: String) -> URL {
        let configRoot = configuredRoot
            ?? ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        let key = path.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        return configRoot
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(String(key), isDirectory: true)
    }

    private static func standardizedDirectory(_ url: URL) throws -> URL {
        let standardized = url.standardizedFileURL
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw error("The workspace path does not exist or is not a directory: \(standardized.path)")
        }
        return standardized
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func sessionID(from url: URL) -> String? {
        let id = url.deletingPathExtension().lastPathComponent
        return isSafeSessionID(id) ? id : nil
    }

    private static func isSafeSessionID(_ id: String) -> Bool {
        UUID(uuidString: id) != nil
    }

    private static func nativeUUID(_ value: String?) -> UUID {
        value.flatMap(UUID.init(uuidString:)) ?? UUID()
    }

    private static func title(from prompt: String?) -> String {
        guard let prompt = nonEmpty(prompt) else { return "Claude thread" }
        return prompt.split(whereSeparator: \.isNewline).first.map { String($0.prefix(100)) } ?? "Claude thread"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
            ?? (try? Date.ISO8601FormatStyle().parse(value))
    }

    private static func contentString(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let blocks = value as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return jsonString(value) ?? ""
    }

    private static func jsonString(_ value: Any?) -> String? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func bounded(_ value: String, maximum: Int) -> String {
        guard value.utf8.count > maximum else { return value }
        var bytes = 0
        var end = value.startIndex
        while end < value.endIndex {
            let next = value.index(after: end)
            let characterBytes = value[end..<next].utf8.count
            guard bytes + characterBytes <= maximum else { break }
            bytes += characterBytes
            end = next
        }
        return String(value[..<end]) + "\n… [historic provider payload truncated]"
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "ClaudeNativeThreadStore", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
