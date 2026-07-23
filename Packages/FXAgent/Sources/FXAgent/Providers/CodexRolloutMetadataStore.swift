import Foundation
import FXCore

struct CodexNativeConfiguration: Sendable, Equatable {
    var model: String?
    var effort: String?
    var agentMode: AgentMode?
    var agentAccess: AgentAccess?

    var isEmpty: Bool {
        model == nil && effort == nil && agentMode == nil && agentAccess == nil
    }

    static func parse(_ object: [String: Any]) -> Self {
        let collaboration = dictionary(
            object["collaborationMode"] ?? object["collaboration_mode"]
        )
        let collaborationSettings = dictionary(collaboration?["settings"])

        let model = nonEmptyString(object["model"])
            ?? nonEmptyString(collaborationSettings?["model"])
        let effort = nonEmptyString(
            object["effort"]
                ?? object["reasoningEffort"]
                ?? object["reasoning_effort"]
        ) ?? nonEmptyString(
            collaborationSettings?["reasoningEffort"]
                ?? collaborationSettings?["reasoning_effort"]
        )
        let mode = agentMode(
            from: collaboration?["mode"]
                ?? object["collaborationMode"]
                ?? object["collaboration_mode"]
        )
        let access = agentAccess(
            approvalPolicy: object["approvalPolicy"] ?? object["approval_policy"],
            sandboxPolicy: object["sandboxPolicy"]
                ?? object["sandbox_policy"]
                ?? object["sandbox"]
        )

        return Self(
            model: model,
            effort: effort,
            agentMode: mode,
            agentAccess: access
        )
    }

    static func agentMode(from value: Any?) -> AgentMode? {
        guard let normalized = nonEmptyString(value)?.lowercased() else {
            return nil
        }
        switch normalized {
        case "default", "auto":
            return .auto
        case "plan":
            return .plan
        default:
            return nil
        }
    }

    static func agentAccess(
        approvalPolicy: Any?,
        sandboxPolicy: Any?
    ) -> AgentAccess? {
        guard let approval = nonEmptyString(approvalPolicy)?.lowercased(),
              let sandbox = sandboxType(sandboxPolicy)?.lowercased() else {
            return nil
        }
        switch (approval, sandbox) {
        case ("untrusted", "workspace-write"):
            return .supervised
        case ("on-request", "workspace-write"):
            return .acceptEdits
        case ("never", "danger-full-access"):
            return .fullAccess
        default:
            return nil
        }
    }

    private static func sandboxType(_ value: Any?) -> String? {
        nonEmptyString(value)
            ?? nonEmptyString(dictionary(value)?["type"])
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct CodexNativeContextUsage: Sendable, Equatable {
    var currentContextTokens: Int
    var contextWindow: Int?
}

struct CodexRolloutMetadataStore {
    static let maximumSessionMetadataBytes = 128 * 1_024
    static let maximumContextSearchBytes = 32 * 1_024 * 1_024
    static let contextSearchChunkBytes = 1_024 * 1_024
    static let maximumContextRecordBytes = 1_024 * 1_024
    static let maximumUsageSearchBytes = 8 * 1_024 * 1_024
    static let usageSearchChunkBytes = 256 * 1_024
    static let maximumUsageRecordBytes = 64 * 1_024
    private static let turnContextMarker = Data(
        #""type":"turn_context""#.utf8
    )
    private static let tokenCountMarker = Data(
        #""type":"token_count""#.utf8
    )

    private struct FileFingerprint: Equatable {
        var size: Int64
        var modificationDate: Date
    }

    private struct DirectoryFingerprint: Equatable {
        var modificationDate: Date
    }

    private struct CachedMetadata {
        var threadID: String
        var fingerprint: FileFingerprint
        var validatedSession: Bool
        var metadata: CodexNativeConfiguration?
    }

    private struct CachedDirectory {
        var fingerprint: DirectoryFingerprint
        var files: [URL]
    }

    private struct CachedUsage {
        var threadID: String
        var fingerprint: FileFingerprint
        var validatedSession: Bool
        var usage: CodexNativeContextUsage?
    }

    private let sessionsRoot: URL
    private let fileManager: FileManager
    private var fileByThreadID: [String: URL] = [:]
    private var metadataByFile: [URL: CachedMetadata] = [:]
    private var usageByFile: [URL: CachedUsage] = [:]
    private var directoryListings: [URL: CachedDirectory] = [:]
    private(set) var metadataParseCount = 0
    private(set) var directoryScanCount = 0
    private(set) var totalBytesRead = 0

    init(
        sessionsRoot: URL = Self.defaultSessionsRoot(),
        fileManager: FileManager = .default
    ) {
        self.sessionsRoot = sessionsRoot.standardizedFileURL
        self.fileManager = fileManager
    }

    mutating func enrich(
        _ summaries: [ProviderNativeThreadSummary]
    ) -> [ProviderNativeThreadSummary] {
        guard summaries.contains(where: Self.needsMetadata) else {
            return summaries
        }

        var candidateDirectoriesByID: [String: [URL]] = [:]
        var uniqueDirectories: Set<URL> = []
        for summary in summaries where Self.needsMetadata(summary) {
            if let knownFile = fileByThreadID[summary.id],
               fingerprint(forFile: knownFile) != nil {
                candidateDirectoriesByID[summary.id] = []
                continue
            }
            let directories = candidateDirectories(for: summary.createdAt)
            candidateDirectoriesByID[summary.id] = directories
            uniqueDirectories.formUnion(directories)
        }

        var filesByDirectory: [URL: [URL]] = [:]
        for directory in uniqueDirectories {
            filesByDirectory[directory] = files(in: directory)
        }

        return summaries.map { original in
            guard Self.needsMetadata(original) else { return original }
            var summary = original
            guard let metadata = metadata(
                threadID: summary.id,
                candidateDirectories: candidateDirectoriesByID[summary.id] ?? [],
                filesByDirectory: filesByDirectory
            ) else {
                return summary
            }
            if summary.model == nil { summary.model = metadata.model }
            if summary.effort == nil { summary.effort = metadata.effort }
            if summary.agentMode == nil { summary.agentMode = metadata.agentMode }
            if summary.agentAccess == nil { summary.agentAccess = metadata.agentAccess }
            return summary
        }
    }

    /// Loads only the selected task's latest context usage. Listing hundreds
    /// of tasks must stay metadata-only; reading a transcript is the bounded
    /// point where a live context ring is useful.
    mutating func enrichUsage(
        _ original: ProviderNativeThreadSummary
    ) -> ProviderNativeThreadSummary {
        var summary = original
        let threadID = summary.id
        var candidates: [URL] = []

        if let knownFile = fileByThreadID[threadID],
           fingerprint(forFile: knownFile) != nil {
            candidates.append(knownFile)
        } else {
            fileByThreadID.removeValue(forKey: threadID)
        }

        if candidates.isEmpty {
            let suffix = "\(threadID).jsonl"
            candidates = candidateDirectories(for: summary.createdAt)
                .flatMap { files(in: $0) }
                .filter { $0.lastPathComponent.hasSuffix(suffix) }
                .sorted { $0.path < $1.path }
        }

        for file in candidates {
            guard let fingerprint = fingerprint(forFile: file) else { continue }

            let cached: CachedUsage
            if let existing = usageByFile[file],
               existing.threadID == threadID,
               existing.fingerprint == fingerprint {
                cached = existing
            } else {
                let validatedSession = sessionID(
                    from: file,
                    fileSize: fingerprint.size
                ) == threadID
                let usage = validatedSession
                    ? latestTokenUsage(from: file, fileSize: fingerprint.size)
                    : nil
                cached = CachedUsage(
                    threadID: threadID,
                    fingerprint: fingerprint,
                    validatedSession: validatedSession,
                    usage: usage
                )
                usageByFile[file] = cached
            }

            guard cached.validatedSession else { continue }
            fileByThreadID[threadID] = file
            if let usage = cached.usage {
                summary.currentContextTokens = usage.currentContextTokens
                summary.contextWindow = usage.contextWindow
            }
            trimCachesIfNeeded()
            return summary
        }

        trimCachesIfNeeded()
        return summary
    }

    private static func needsMetadata(_ summary: ProviderNativeThreadSummary) -> Bool {
        summary.model == nil
            || summary.effort == nil
            || summary.agentMode == nil
            || summary.agentAccess == nil
    }

    private mutating func metadata(
        threadID: String,
        candidateDirectories: [URL],
        filesByDirectory: [URL: [URL]]
    ) -> CodexNativeConfiguration? {
        var candidates: [URL] = []
        if let knownFile = fileByThreadID[threadID],
           fingerprint(forFile: knownFile) != nil {
            candidates.append(knownFile)
        } else {
            fileByThreadID.removeValue(forKey: threadID)
        }

        if candidates.isEmpty {
            let suffix = "\(threadID).jsonl"
            candidates = candidateDirectories
                .flatMap { filesByDirectory[$0] ?? [] }
                .filter { $0.lastPathComponent.hasSuffix(suffix) }
                .sorted { $0.path < $1.path }
        }

        for file in candidates {
            guard let fingerprint = fingerprint(forFile: file) else { continue }
            if let cached = metadataByFile[file],
               cached.threadID == threadID,
               cached.fingerprint == fingerprint {
                if cached.validatedSession {
                    fileByThreadID[threadID] = file
                }
                return cached.metadata
            }

            let parsed = parseMetadata(
                from: file,
                threadID: threadID,
                fingerprint: fingerprint
            )
            metadataByFile[file] = CachedMetadata(
                threadID: threadID,
                fingerprint: fingerprint,
                validatedSession: parsed.validatedSession,
                metadata: parsed.metadata
            )
            if parsed.validatedSession {
                fileByThreadID[threadID] = file
                trimCachesIfNeeded()
                return parsed.metadata
            }
        }

        trimCachesIfNeeded()
        return nil
    }

    private mutating func parseMetadata(
        from file: URL,
        threadID: String,
        fingerprint: FileFingerprint
    ) -> (validatedSession: Bool, metadata: CodexNativeConfiguration?) {
        guard sessionID(
            from: file,
            fileSize: fingerprint.size
        ) == threadID else {
            return (false, nil)
        }
        guard let context = latestTurnContext(
            from: file,
            fileSize: fingerprint.size
        ) else {
            return (true, nil)
        }
        metadataParseCount += 1
        let metadata = CodexNativeConfiguration.parse(context)
        return (true, metadata.isEmpty ? nil : metadata)
    }

    private mutating func sessionID(
        from file: URL,
        fileSize: Int64
    ) -> String? {
        guard fileSize > 0,
              let handle = try? FileHandle(forReadingFrom: file) else {
            return nil
        }
        defer { try? handle.close() }
        let limit = min(Int(fileSize), Self.maximumSessionMetadataBytes)
        guard let data = try? handle.read(upToCount: limit),
              !data.isEmpty else {
            return nil
        }
        totalBytesRead += data.count

        let record: Data
        if let newline = data.firstIndex(of: 0x0A) {
            record = Data(data[..<newline])
        } else {
            guard Int64(data.count) == fileSize else { return nil }
            record = data
        }
        guard let object = try? JSONSerialization.jsonObject(with: record),
              let envelope = object as? [String: Any],
              envelope["type"] as? String == "session_meta",
              let payload = envelope["payload"] as? [String: Any] else {
            return nil
        }
        return payload["id"] as? String
    }

    private mutating func latestTurnContext(
        from file: URL,
        fileSize: Int64
    ) -> [String: Any]? {
        guard fileSize > 0,
              let handle = try? FileHandle(forReadingFrom: file) else {
            return nil
        }
        defer { try? handle.close() }

        let searchFloor = max(
            Int64.zero,
            fileSize - Int64(Self.maximumContextSearchBytes)
        )
        let overlapCount = max(Self.turnContextMarker.count - 1, 0)
        var cursor = fileSize
        var rightOverlap = Data()

        while cursor > searchFloor {
            let chunkStart = max(
                searchFloor,
                cursor - Int64(Self.contextSearchChunkBytes)
            )
            let byteCount = Int(cursor - chunkStart)
            do {
                try handle.seek(toOffset: UInt64(chunkStart))
                guard let chunk = try handle.read(upToCount: byteCount),
                      !chunk.isEmpty else {
                    return nil
                }
                totalBytesRead += chunk.count

                var searchable = chunk
                searchable.append(rightOverlap)
                var searchUpperBound = searchable.endIndex
                while searchUpperBound - searchable.startIndex
                    >= Self.turnContextMarker.count,
                    let markerRange = searchable.range(
                        of: Self.turnContextMarker,
                        options: .backwards,
                        in: searchable.startIndex..<searchUpperBound
                    ) {
                    // Matches starting in the overlap belong to the newer chunk
                    // and were already considered on the previous iteration.
                    if markerRange.lowerBound < chunk.endIndex {
                        let markerOffset = chunkStart
                            + Int64(markerRange.lowerBound - searchable.startIndex)
                        guard let record = contextRecord(
                            from: handle,
                            fileSize: fileSize,
                            markerOffset: markerOffset
                        ) else {
                            return nil
                        }
                        // Once the newest context marker is found, an invalid or
                        // oversized record means its settings are unknown. Older
                        // contexts must never be substituted as current.
                        return Self.turnContext(from: record[...])
                    }
                    searchUpperBound = markerRange.lowerBound
                }

                rightOverlap = Data(chunk.prefix(overlapCount))
                cursor = chunkStart
            } catch {
                return nil
            }
        }
        return nil
    }

    private mutating func contextRecord(
        from handle: FileHandle,
        fileSize: Int64,
        markerOffset: Int64
    ) -> Data? {
        let radius = Int64(Self.maximumContextRecordBytes)
        let windowStart = max(Int64.zero, markerOffset - radius)
        let windowEnd = min(
            fileSize,
            markerOffset + Int64(Self.turnContextMarker.count) + radius
        )
        guard windowEnd > windowStart else { return nil }

        do {
            try handle.seek(toOffset: UInt64(windowStart))
            guard let data = try handle.read(
                upToCount: Int(windowEnd - windowStart)
            ), !data.isEmpty else {
                return nil
            }
            totalBytesRead += data.count

            let relativeMarker = Int(markerOffset - windowStart)
            guard relativeMarker >= data.startIndex,
                  relativeMarker < data.endIndex else {
                return nil
            }

            let recordStart: Data.Index
            if let newline = data[..<relativeMarker].lastIndex(of: 0x0A) {
                recordStart = data.index(after: newline)
            } else {
                guard windowStart == 0 else { return nil }
                recordStart = data.startIndex
            }

            let markerEnd = min(
                relativeMarker + Self.turnContextMarker.count,
                data.endIndex
            )
            let recordEnd: Data.Index
            if let newline = data[markerEnd...].firstIndex(of: 0x0A) {
                recordEnd = newline
            } else {
                guard windowEnd == fileSize else { return nil }
                recordEnd = data.endIndex
            }

            guard recordEnd >= recordStart,
                  recordEnd - recordStart <= Self.maximumContextRecordBytes else {
                return nil
            }
            return Data(data[recordStart..<recordEnd])
        } catch {
            return nil
        }
    }

    private static func turnContext(
        from bytes: Data.SubSequence
    ) -> [String: Any]? {
        var record = Data(bytes)
        if record.last == 0x0D { record.removeLast() }
        guard let object = try? JSONSerialization.jsonObject(with: record),
              let envelope = object as? [String: Any],
              envelope["type"] as? String == "turn_context",
              let payload = envelope["payload"] as? [String: Any] else {
            return nil
        }
        return payload
    }

    private mutating func latestTokenUsage(
        from file: URL,
        fileSize: Int64
    ) -> CodexNativeContextUsage? {
        guard fileSize > 0,
              let handle = try? FileHandle(forReadingFrom: file) else {
            return nil
        }
        defer { try? handle.close() }

        let searchFloor = max(
            Int64.zero,
            fileSize - Int64(Self.maximumUsageSearchBytes)
        )
        let overlapCount = max(Self.tokenCountMarker.count - 1, 0)
        var cursor = fileSize
        var rightOverlap = Data()

        while cursor > searchFloor {
            let chunkStart = max(
                searchFloor,
                cursor - Int64(Self.usageSearchChunkBytes)
            )
            let byteCount = Int(cursor - chunkStart)
            do {
                try handle.seek(toOffset: UInt64(chunkStart))
                guard let chunk = try handle.read(upToCount: byteCount),
                      !chunk.isEmpty else {
                    return nil
                }
                totalBytesRead += chunk.count

                var searchable = chunk
                searchable.append(rightOverlap)
                var searchUpperBound = searchable.endIndex
                while searchUpperBound - searchable.startIndex
                    >= Self.tokenCountMarker.count,
                    let markerRange = searchable.range(
                        of: Self.tokenCountMarker,
                        options: .backwards,
                        in: searchable.startIndex..<searchUpperBound
                    ) {
                    if markerRange.lowerBound < chunk.endIndex {
                        let markerOffset = chunkStart
                            + Int64(markerRange.lowerBound - searchable.startIndex)
                        guard let record = usageRecord(
                            from: handle,
                            fileSize: fileSize,
                            markerOffset: markerOffset
                        ) else {
                            return nil
                        }
                        // The newest token-count event is authoritative. A
                        // null or malformed newest event means usage is
                        // unknown; never resurrect an older pre-compaction
                        // value.
                        return Self.tokenUsage(from: record[...])
                    }
                    searchUpperBound = markerRange.lowerBound
                }

                rightOverlap = Data(chunk.prefix(overlapCount))
                cursor = chunkStart
            } catch {
                return nil
            }
        }
        return nil
    }

    private mutating func usageRecord(
        from handle: FileHandle,
        fileSize: Int64,
        markerOffset: Int64
    ) -> Data? {
        let radius = Int64(Self.maximumUsageRecordBytes)
        let windowStart = max(Int64.zero, markerOffset - radius)
        let windowEnd = min(
            fileSize,
            markerOffset + Int64(Self.tokenCountMarker.count) + radius
        )
        guard windowEnd > windowStart else { return nil }

        do {
            try handle.seek(toOffset: UInt64(windowStart))
            guard let data = try handle.read(
                upToCount: Int(windowEnd - windowStart)
            ), !data.isEmpty else {
                return nil
            }
            totalBytesRead += data.count

            let relativeMarker = Int(markerOffset - windowStart)
            guard relativeMarker >= data.startIndex,
                  relativeMarker < data.endIndex else {
                return nil
            }

            let recordStart: Data.Index
            if let newline = data[..<relativeMarker].lastIndex(of: 0x0A) {
                recordStart = data.index(after: newline)
            } else {
                guard windowStart == 0 else { return nil }
                recordStart = data.startIndex
            }

            let markerEnd = min(
                relativeMarker + Self.tokenCountMarker.count,
                data.endIndex
            )
            let recordEnd: Data.Index
            if let newline = data[markerEnd...].firstIndex(of: 0x0A) {
                recordEnd = newline
            } else {
                guard windowEnd == fileSize else { return nil }
                recordEnd = data.endIndex
            }

            guard recordEnd >= recordStart,
                  recordEnd - recordStart <= Self.maximumUsageRecordBytes else {
                return nil
            }
            return Data(data[recordStart..<recordEnd])
        } catch {
            return nil
        }
    }

    private static func tokenUsage(
        from bytes: Data.SubSequence
    ) -> CodexNativeContextUsage? {
        var record = Data(bytes)
        if record.last == 0x0D { record.removeLast() }
        guard let object = try? JSONSerialization.jsonObject(with: record),
              let envelope = object as? [String: Any],
              envelope["type"] as? String == "event_msg",
              let payload = envelope["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let last = info["last_token_usage"] as? [String: Any],
              let totalTokens = integer(last["total_tokens"]),
              totalTokens >= 0 else {
            return nil
        }
        let contextWindow = integer(info["model_context_window"])
        return CodexNativeContextUsage(
            currentContextTokens: totalTokens,
            contextWindow: contextWindow.flatMap { $0 > 0 ? $0 : nil }
        )
    }

    private static func integer(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            value
        case let value as NSNumber:
            value.intValue
        default:
            nil
        }
    }

    private func candidateDirectories(for createdAt: Date) -> [URL] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return (-1...1).compactMap { offset -> URL? in
            guard let date = calendar.date(
                byAdding: .day,
                value: offset,
                to: createdAt
            ) else {
                return nil
            }
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = components.year,
                  let month = components.month,
                  let day = components.day else {
                return nil
            }
            return sessionsRoot
                .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
        }
    }

    private mutating func files(in directory: URL) -> [URL] {
        guard let fingerprint = fingerprint(forDirectory: directory) else {
            directoryListings.removeValue(forKey: directory)
            return []
        }
        if let cached = directoryListings[directory],
           cached.fingerprint == fingerprint {
            return cached.files
        }
        let files = (
            try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
        )?
            .filter { $0.pathExtension == "jsonl" }
            ?? []
        directoryScanCount += 1
        directoryListings[directory] = CachedDirectory(
            fingerprint: fingerprint,
            files: files
        )
        return files
    }

    private func fingerprint(forFile file: URL) -> FileFingerprint? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: file.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let modificationDate = attributes[.modificationDate] as? Date else {
            return nil
        }
        return FileFingerprint(size: size, modificationDate: modificationDate)
    }

    private func fingerprint(forDirectory directory: URL) -> DirectoryFingerprint? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: directory.path),
              let modificationDate = attributes[.modificationDate] as? Date else {
            return nil
        }
        return DirectoryFingerprint(modificationDate: modificationDate)
    }

    private mutating func trimCachesIfNeeded() {
        while metadataByFile.count > 512, let key = metadataByFile.keys.first {
            metadataByFile.removeValue(forKey: key)
        }
        while usageByFile.count > 512, let key = usageByFile.keys.first {
            usageByFile.removeValue(forKey: key)
        }
        while fileByThreadID.count > 512, let key = fileByThreadID.keys.first {
            fileByThreadID.removeValue(forKey: key)
        }
        while directoryListings.count > 64, let key = directoryListings.keys.first {
            directoryListings.removeValue(forKey: key)
        }
    }

    private static func defaultSessionsRoot() -> URL {
        let environment = ProcessInfo.processInfo.environment
        let root: URL
        if let configured = environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            root = URL(
                fileURLWithPath: NSString(string: configured).expandingTildeInPath,
                isDirectory: true
            )
        } else {
            root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
        }
        return root.appendingPathComponent("sessions", isDirectory: true)
    }
}
