import Darwin
import Foundation
import FXCore

actor ClaudeNativeThreadStore {
    typealias TrashHandler = @Sendable (URL) throws -> Void

    static let defaultMaximumThreadResults = 500
    private static let maximumSummaryBytes = 1 * 1_024 * 1_024
    static let defaultMaximumTranscriptBytes = 32 * 1_024 * 1_024
    static let defaultMaximumSummaryCacheEntries = 2_000
    static let defaultMaximumTranscriptCacheEntries = 4
    static let defaultMaximumTranscriptCacheBytes = 48 * 1_024 * 1_024
    private static let maximumJSONLineBytes = 4 * 1_024 * 1_024
    private static let maximumTranscriptJSONLRecords = 512
    private static let transcriptTailReadChunkBytes = 256 * 1_024
    private static let maximumMessages = 250
    private static let maximumMessagesDuringParse = 512
    private static let retainedMessagesAfterParseTrim = 320
    private let configuredRoot: URL?
    private let maximumTranscriptBytes: Int
    private let maximumThreadResults: Int
    private let maximumSummaryCacheEntries: Int
    private let maximumTranscriptCacheEntries: Int
    private let maximumTranscriptCacheBytes: Int
    private let trashHandler: TrashHandler
    private var summaryCache: [String: CachedSummary] = [:]
    private var transcriptCache: [String: CachedTranscript] = [:]
    private var summaryParseCount = 0
    private var transcriptParseCount = 0
    private var summaryAccessCounter: UInt64 = 0
    private var transcriptAccessCounter: UInt64 = 0

    init(
        configRoot: URL? = nil,
        maximumTranscriptBytes: Int = ClaudeNativeThreadStore.defaultMaximumTranscriptBytes,
        maximumThreadResults: Int = ClaudeNativeThreadStore.defaultMaximumThreadResults,
        maximumSummaryCacheEntries: Int = ClaudeNativeThreadStore.defaultMaximumSummaryCacheEntries,
        maximumTranscriptCacheEntries: Int = ClaudeNativeThreadStore.defaultMaximumTranscriptCacheEntries,
        maximumTranscriptCacheBytes: Int = ClaudeNativeThreadStore.defaultMaximumTranscriptCacheBytes,
        trashHandler: @escaping TrashHandler = ClaudeNativeThreadStore.moveItemToTrash
    ) {
        configuredRoot = configRoot
        self.maximumTranscriptBytes = max(1, maximumTranscriptBytes)
        self.maximumThreadResults = max(1, maximumThreadResults)
        self.maximumSummaryCacheEntries = max(1, maximumSummaryCacheEntries)
        self.maximumTranscriptCacheEntries = max(1, maximumTranscriptCacheEntries)
        self.maximumTranscriptCacheBytes = max(1, maximumTranscriptCacheBytes)
        self.trashHandler = trashHandler
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

    private struct CachedTranscript {
        var fingerprint: FileFingerprint
        var messages: [ConversationMessage]
        var byteCost: Int
        var lastAccess: UInt64
    }

    private struct ParsedSession {
        var sessionID: String?
        var cwd: String?
        var nativeTitle: String?
        var firstPrompt: String?
        var lastPrompt: String?
        var model: String?
        var effort: String?
        var agentMode: AgentMode?
        var agentAccess: AgentAccess?
        var currentContextTokens: Int?
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
        var match: (
            file: URL,
            summary: ProviderNativeThreadSummary,
            fingerprint: FileFingerprint
        )?
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
                match = (
                    file,
                    summary,
                    FileFingerprint(
                        size: values.fileSize ?? 0,
                        modificationDate: values.contentModificationDate
                    )
                )
            }
        }
        guard let match else { throw Self.error("Claude Code session '\(id)' was not found for this workspace.") }

        let cacheKey = match.file.standardizedFileURL.path
        if var cached = transcriptCache[cacheKey],
           cached.fingerprint == match.fingerprint {
            transcriptAccessCounter &+= 1
            cached.lastAccess = transcriptAccessCounter
            transcriptCache[cacheKey] = cached
            return ProviderNativeThread(summary: match.summary, messages: cached.messages)
        }

        let data = try Self.readTailData(
            from: match.file,
            maximumBytes: maximumTranscriptBytes,
            maximumRecords: Self.maximumTranscriptJSONLRecords
        )
        try Task.checkCancellation()
        transcriptParseCount += 1
        let parsed = try Self.parse(data: data, includeMessages: true)
        if let parsedCWD = parsed.cwd,
           Self.canonicalPath(parsedCWD) != canonicalDirectory.path {
            throw Self.error("Claude Code session '\(id)' does not belong to this workspace.")
        }
        guard parsed.sessionID == nil || parsed.sessionID == id else {
            throw Self.error("Claude Code session '\(id)' does not belong to this workspace.")
        }
        let messages = Array(parsed.messages.suffix(Self.maximumMessages))
        cacheTranscript(messages, key: cacheKey, fingerprint: match.fingerprint)
        return ProviderNativeThread(summary: match.summary, messages: messages)
    }

    func moveToTrash(
        id: String,
        workingDirectory: URL
    ) throws {
        try Task.checkCancellation()
        guard Self.isSafeSessionID(id) else { throw Self.error("Invalid Claude Code session id.") }

        let configuredDirectory = try Self.standardizedDirectory(workingDirectory)
        let canonicalDirectory = configuredDirectory.resolvingSymlinksInPath().standardizedFileURL
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey,
        ]
        var matchedArtifactsByPath: [String: URL] = [:]
        var matchedTranscriptPaths: Set<String> = []

        for projectDirectory in projectDirectories(
            configuredDirectory: configuredDirectory,
            canonicalDirectory: canonicalDirectory
        ) {
            try Task.checkCancellation()
            let file = projectDirectory.appendingPathComponent(id).appendingPathExtension("jsonl")
            guard let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let summary = try summary(
                    for: file,
                    values: values,
                    canonicalDirectory: canonicalDirectory
                  ),
                  summary.id == id,
                  Self.canonicalPath(summary.workingDirectory) == canonicalDirectory.path else {
                continue
            }
            let transcript = file.standardizedFileURL
            matchedArtifactsByPath[transcript.path] = transcript
            matchedTranscriptPaths.insert(transcript.path)

            // Claude stores spawned subagent transcripts under a sibling
            // session directory (`<session-id>/subagents/*.jsonl`). Once the
            // parent transcript has proven the exact workspace identity, that
            // UUID-named directory is session-owned and moves with it.
            let sessionDirectory = projectDirectory
                .appendingPathComponent(id, isDirectory: true)
                .standardizedFileURL
            if let directoryValues = try? sessionDirectory.resourceValues(forKeys: keys),
               directoryValues.isDirectory == true {
                matchedArtifactsByPath[sessionDirectory.path] = sessionDirectory
            }
        }

        let matchedArtifacts = matchedArtifactsByPath.values.sorted { $0.path < $1.path }
        guard !matchedTranscriptPaths.isEmpty else {
            throw Self.error("Claude Code session '\(id)' was not found for this workspace.")
        }

        // Once the recoverable operation begins, finish every validated
        // duplicate path instead of leaving a half-moved session because the
        // surrounding UI task was cancelled.
        for artifact in matchedArtifacts {
            try trashHandler(artifact)
        }
        for transcriptPath in matchedTranscriptPaths {
            summaryCache[transcriptPath] = nil
            transcriptCache[transcriptPath] = nil
        }
    }

    func rename(
        id: String,
        name: String,
        workingDirectory: URL
    ) throws {
        try Task.checkCancellation()
        guard Self.isSafeSessionID(id) else {
            throw Self.error("Invalid Claude Code session id.")
        }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw Self.error("A task name is required.")
        }

        let configuredDirectory = try Self.standardizedDirectory(workingDirectory)
        let canonicalDirectory = configuredDirectory.resolvingSymlinksInPath().standardizedFileURL
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey,
        ]
        var matchedFilesByCanonicalPath: [String: URL] = [:]
        var cachePaths: Set<String> = []

        for projectDirectory in projectDirectories(
            configuredDirectory: configuredDirectory,
            canonicalDirectory: canonicalDirectory
        ) {
            try Task.checkCancellation()
            let file = projectDirectory.appendingPathComponent(id).appendingPathExtension("jsonl")
            guard let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let summary = try summary(
                    for: file,
                    values: values,
                    canonicalDirectory: canonicalDirectory
                  ),
                  summary.id == id,
                  Self.canonicalPath(summary.workingDirectory) == canonicalDirectory.path else {
                continue
            }
            let standardizedFile = file.standardizedFileURL
            let resolvedFile = standardizedFile.resolvingSymlinksInPath()
            matchedFilesByCanonicalPath[resolvedFile.path] = resolvedFile
            cachePaths.insert(standardizedFile.path)
            cachePaths.insert(resolvedFile.path)
        }

        guard !matchedFilesByCanonicalPath.isEmpty else {
            throw Self.error("Claude Code session '\(id)' was not found for this workspace.")
        }

        let record: [String: Any] = [
            "type": "custom-title",
            "customTitle": normalizedName,
            "sessionId": id,
        ]
        for file in matchedFilesByCanonicalPath.values.sorted(by: { $0.path < $1.path }) {
            try Self.appendJSONLine(record, to: file)
        }
        for path in cachePaths {
            summaryCache[path] = nil
            transcriptCache[path] = nil
        }
    }

    func summaryCacheStatisticsForTesting() -> (entries: Int, parses: Int) {
        (summaryCache.count, summaryParseCount)
    }

    func transcriptCacheStatisticsForTesting() -> (entries: Int, parses: Int) {
        (transcriptCache.count, transcriptParseCount)
    }

    private func pruneSummaryCache(in projectDirectory: URL, keeping paths: Set<String>) {
        let projectPath = projectDirectory.standardizedFileURL.path
        summaryCache = summaryCache.filter { path, _ in
            URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path != projectPath
                || paths.contains(path)
        }
        transcriptCache = transcriptCache.filter { path, _ in
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
                effort: parsed.effort,
                agentMode: parsed.agentMode,
                agentAccess: parsed.agentAccess,
                status: "native",
                currentContextTokens: parsed.currentContextTokens,
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

    private func cacheTranscript(
        _ messages: [ConversationMessage],
        key: String,
        fingerprint: FileFingerprint
    ) {
        let byteCost = Self.transcriptByteCost(messages)
        guard byteCost <= maximumTranscriptCacheBytes else {
            transcriptCache[key] = nil
            return
        }
        transcriptAccessCounter &+= 1
        transcriptCache[key] = CachedTranscript(
            fingerprint: fingerprint,
            messages: messages,
            byteCost: byteCost,
            lastAccess: transcriptAccessCounter
        )
        trimTranscriptCacheIfNeeded()
    }

    private func trimTranscriptCacheIfNeeded() {
        var totalBytes = transcriptCache.values.reduce(0) { $0 + $1.byteCost }
        guard transcriptCache.count > maximumTranscriptCacheEntries
                || totalBytes > maximumTranscriptCacheBytes else {
            return
        }

        let oldestKeys = transcriptCache.sorted {
            if $0.value.lastAccess != $1.value.lastAccess {
                return $0.value.lastAccess < $1.value.lastAccess
            }
            return $0.key < $1.key
        }.map(\.key)

        for key in oldestKeys {
            guard transcriptCache.count > maximumTranscriptCacheEntries
                    || totalBytes > maximumTranscriptCacheBytes else {
                break
            }
            if let removed = transcriptCache.removeValue(forKey: key) {
                totalBytes -= removed.byteCost
            }
        }
    }

    private static func transcriptByteCost(_ messages: [ConversationMessage]) -> Int {
        messages.reduce(0) { total, message in
            total + message.content.reduce(0) { contentTotal, content in
                let byteCost: Int
                switch content {
                case .text(let text):
                    byteCost = text.utf8.count
                case .code(let language, let code):
                    byteCost = language.utf8.count + code.utf8.count
                case .image(let data, let mimeType):
                    byteCost = data.count + mimeType.utf8.count
                case .imageAsset(let reference):
                    byteCost = reference.byteCount
                case .toolUse(let id, let name, let input):
                    byteCost = id.utf8.count + name.utf8.count + input.utf8.count
                case .toolResult(let id, let content, _):
                    byteCost = id.utf8.count + content.utf8.count
                }
                return contentTotal + byteCost
            }
        }
    }

    private static func parse(data: Data, includeMessages: Bool) throws -> ParsedSession {
        var parsed = ParsedSession()
        var remainingImageBytes = ProviderNativeImageImporter.maximumTranscriptImageBytes
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
            if object.keys.contains("model") {
                parsed.model = nonEmpty(object["model"] as? String)
            }
            if object.keys.contains("effort") {
                parsed.effort = nonEmpty(object["effort"] as? String)
            }
            if object.keys.contains("mode") {
                parsed.agentMode = agentMode(fromClaudeMode: object["mode"])
            }
            if object.keys.contains("permissionMode") {
                parsed.agentAccess = agentAccess(fromClaudePermissionMode: object["permissionMode"])
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
                // Claude writes provider-owned context (image dimensions,
                // local-command caveats, expanded skill text, and attachment
                // payloads) as user-shaped records. They are linked into the
                // native transcript for Claude's context, but are not prompts
                // the user authored and Claude's own UI does not render them
                // as dialogue.
                guard object["isMeta"] as? Bool != true else { continue }
                guard let message = object["message"] as? [String: Any] else { continue }
                let contents = userContents(
                    message["content"],
                    importImages: includeMessages,
                    remainingImageBytes: &remainingImageBytes
                )
                if includeMessages,
                   let toolUseResult = object["toolUseResult"] as? [String: Any],
                   let structuredPatch = toolUseResult["structuredPatch"] as? [Any],
                   !structuredPatch.isEmpty {
                    enrichMatchingEditToolUse(
                        messages: &parsed.messages,
                        resultContents: contents,
                        parentUUID: object["parentUuid"] as? String,
                        structuredPatch: structuredPatch
                    )
                }
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
                if message.keys.contains("model") {
                    parsed.model = nonEmpty(message["model"] as? String)
                }
                if object["isSidechain"] as? Bool != true,
                   let usage = message["usage"] as? [String: Any],
                   let currentContextTokens = currentContextTokens(from: usage) {
                    parsed.currentContextTokens = currentContextTokens
                }
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

            if includeMessages, parsed.messages.count > maximumMessagesDuringParse {
                parsed.messages.removeFirst(
                    parsed.messages.count - retainedMessagesAfterParseTrim
                )
            }
        }
        try Task.checkCancellation()
        return parsed
    }

    private static func currentContextTokens(
        from usage: [String: Any]
    ) -> Int? {
        let keys = [
            "input_tokens",
            "cache_creation_input_tokens",
            "cache_read_input_tokens",
            "output_tokens",
        ]
        let values = keys.compactMap { nonNegativeInteger(usage[$0]) }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }

    private static func nonNegativeInteger(_ value: Any?) -> Int? {
        let result: Int?
        switch value {
        case let value as Int:
            result = value
        case let value as NSNumber:
            result = value.intValue
        default:
            result = nil
        }
        return result.flatMap { $0 >= 0 ? $0 : nil }
    }

    private static func agentMode(fromClaudeMode value: Any?) -> AgentMode? {
        switch value as? String {
        case "normal", "default":
            return .auto
        case "plan":
            return .plan
        default:
            return nil
        }
    }

    private static func agentAccess(fromClaudePermissionMode value: Any?) -> AgentAccess? {
        switch value as? String {
        case "bypassPermissions":
            return .fullAccess
        case "acceptEdits":
            return .acceptEdits
        case "default", "supervised":
            return .supervised
        default:
            return nil
        }
    }

    private static func userContents(
        _ value: Any?,
        importImages: Bool,
        remainingImageBytes: inout Int
    ) -> [MessageContent] {
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
                guard importImages,
                      let source = block["source"] as? [String: Any],
                      source["type"] as? String == "base64",
                      let mimeType = source["media_type"] as? String,
                      let encoded = source["data"] as? String else {
                    return nil
                }
                return ProviderNativeImageImporter.base64(
                    encoded,
                    mimeType: mimeType,
                    remainingBytes: &remainingImageBytes
                )
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
                    input: boundedJSONString(block["input"], maximum: 32_768)
                )
            default:
                return nil
            }
        }
    }

    private static func enrichMatchingEditToolUse(
        messages: inout [ConversationMessage],
        resultContents: [MessageContent],
        parentUUID: String?,
        structuredPatch: [Any]
    ) {
        let resultToolIDs = Set(resultContents.compactMap { content -> String? in
            guard case .toolResult(let id, _, _) = content, !id.isEmpty else { return nil }
            return id
        })
        let parentMessageID = parentUUID.flatMap(UUID.init(uuidString:))
        guard !resultToolIDs.isEmpty || parentMessageID != nil else { return }

        for messageIndex in messages.indices.reversed() {
            if let parentMessageID,
               messages[messageIndex].id != parentMessageID {
                continue
            }
            for contentIndex in messages[messageIndex].content.indices.reversed() {
                guard case .toolUse(let id, let name, let input) =
                    messages[messageIndex].content[contentIndex],
                    name.caseInsensitiveCompare("Edit") == .orderedSame,
                    resultToolIDs.isEmpty || resultToolIDs.contains(id),
                    let inputData = input.data(using: .utf8),
                    var inputObject = try? JSONSerialization.jsonObject(with: inputData) as? [String: Any]
                else {
                    continue
                }
                inputObject["_flowxStructuredPatch"] = structuredPatch
                messages[messageIndex].content[contentIndex] = .toolUse(
                    id: id,
                    name: name,
                    input: boundedJSONString(inputObject, maximum: 32_768)
                )
                return
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

    private static func readTailData(
        from url: URL,
        maximumBytes: Int,
        maximumRecords: Int
    ) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = Int(try handle.seekToEnd())
        guard size > 0, maximumBytes > 0, maximumRecords > 0 else { return Data() }

        let earliestOffset = max(0, size - maximumBytes)
        var readOffset = size
        var newlineCount = 0
        var reverseChunks: [Data] = []

        // Read backward until there are enough delimiters to isolate the
        // requested number of complete JSONL records. One extra delimiter
        // supplies the boundary before the oldest retained record whether or
        // not the file currently ends in a newline.
        while readOffset > earliestOffset, newlineCount <= maximumRecords {
            try Task.checkCancellation()
            let chunkStart = max(
                earliestOffset,
                readOffset - Self.transcriptTailReadChunkBytes
            )
            try handle.seek(toOffset: UInt64(chunkStart))
            let chunk = try handle.read(upToCount: readOffset - chunkStart) ?? Data()
            guard !chunk.isEmpty else { break }
            newlineCount += chunk.reduce(into: 0) { count, byte in
                if byte == 0x0A { count += 1 }
            }
            reverseChunks.append(chunk)
            readOffset = chunkStart
        }

        let byteCount = reverseChunks.reduce(0) { $0 + $1.count }
        var data = Data()
        data.reserveCapacity(byteCount)
        for chunk in reverseChunks.reversed() {
            data.append(chunk)
        }

        return completeJSONLRecordSuffix(
            from: data,
            maximumRecords: maximumRecords,
            startsAtFileBeginning: readOffset == 0
        )
    }

    private static func completeJSONLRecordSuffix(
        from data: Data,
        maximumRecords: Int,
        startsAtFileBeginning: Bool
    ) -> Data {
        guard !data.isEmpty, maximumRecords > 0 else { return Data() }

        // A byte-window or chunk boundary can land inside a large JSON object.
        // Only the first segment is ambiguous; every segment after its newline
        // is known to be a complete record.
        let earliestCompleteStart: Data.Index
        if startsAtFileBeginning {
            earliestCompleteStart = data.startIndex
        } else if let firstNewline = data.firstIndex(of: 0x0A) {
            earliestCompleteStart = data.index(after: firstNewline)
        } else {
            return Data()
        }

        guard earliestCompleteStart < data.endIndex else { return Data() }

        var selectedStart: Data.Index?
        var recordCount = 0
        var lineEnd = data.endIndex
        var cursor = data.endIndex

        while cursor > earliestCompleteStart {
            let index = data.index(before: cursor)
            if data[index] == 0x0A {
                let lineStart = data.index(after: index)
                if lineStart < lineEnd {
                    selectedStart = lineStart
                    recordCount += 1
                    if recordCount == maximumRecords { break }
                }
                lineEnd = index
            }
            cursor = index
        }

        if recordCount < maximumRecords, earliestCompleteStart < lineEnd {
            selectedStart = earliestCompleteStart
        }

        guard let selectedStart else { return Data() }
        return Data(data[selectedStart..<data.endIndex])
    }

    static func readTailDataForTesting(
        from url: URL,
        maximumBytes: Int,
        maximumRecords: Int
    ) throws -> Data {
        try readTailData(
            from: url,
            maximumBytes: maximumBytes,
            maximumRecords: maximumRecords
        )
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

    private nonisolated static func moveItemToTrash(_ url: URL) throws {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
    }

    private nonisolated static func appendJSONLine(
        _ object: [String: Any],
        to url: URL
    ) throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw error("Could not encode the Claude Code task name.")
        }
        var payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        payload.append(0x0A)

        let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_WRONLY | O_APPEND | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }

        try payload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var writtenBytes = 0
            while writtenBytes < rawBuffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: writtenBytes),
                    rawBuffer.count - writtenBytes
                )
                if result > 0 {
                    writtenBytes += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
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

    private static func boundedJSONString(_ value: Any?, maximum: Int) -> String {
        guard let value, let serialized = jsonString(value) else { return "{}" }
        guard serialized.utf8.count > maximum else { return serialized }

        // Bound string fields before encoding instead of cutting an encoded
        // JSON document in half. That keeps imported tool input parseable and
        // preserves small structural fields such as paths and diff line
        // numbers even when old/new source bodies are very large.
        var fieldLimit = maximum
        while fieldLimit > 0 {
            let candidateValue = boundingJSONStrings(in: value, maximum: fieldLimit)
            if let candidate = jsonString(candidateValue),
               candidate.utf8.count <= maximum {
                return candidate
            }
            fieldLimit /= 2
        }
        let minimalValue = boundingJSONStrings(in: value, maximum: 0)
        if let candidate = jsonString(minimalValue), candidate.utf8.count <= maximum {
            return candidate
        }
        return #"{"_flowxPayloadTruncated":true}"#
    }

    private static func boundingJSONStrings(in value: Any, maximum: Int) -> Any {
        if let string = value as? String {
            return boundedJSONField(string, maximum: maximum)
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues { boundingJSONStrings(in: $0, maximum: maximum) }
        }
        if let array = value as? [Any] {
            return array.map { boundingJSONStrings(in: $0, maximum: maximum) }
        }
        return value
    }

    private static func boundedJSONField(_ value: String, maximum: Int) -> String {
        guard value.utf8.count > maximum else { return value }
        guard maximum > 0 else { return "" }
        let marker = "… [historic provider field truncated]"
        let markerBytes = marker.utf8.count
        guard maximum > markerBytes else { return "" }

        let prefixMaximum = maximum - markerBytes
        var bytes = 0
        var end = value.startIndex
        while end < value.endIndex {
            let next = value.index(after: end)
            let characterBytes = value[end..<next].utf8.count
            guard bytes + characterBytes <= prefixMaximum else { break }
            bytes += characterBytes
            end = next
        }
        return String(value[..<end]) + marker
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
