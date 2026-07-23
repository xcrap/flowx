import Foundation
import FXCore
import OSLog

private let conversationAssetLogger = Logger(
    subsystem: "com.flowx.app",
    category: "ConversationAssetStore"
)

enum ConversationAssetStoreError: LocalizedError, Sendable {
    case invalidReference
    case oversizedAsset
    case missingImageData

    var errorDescription: String? {
        switch self {
        case .invalidReference:
            "The conversation image reference is invalid."
        case .oversizedAsset:
            "The conversation image exceeds the durable history limit."
        case .missingImageData:
            "The conversation image has no data."
        }
    }
}

/// File-backed conversation images. References contain typed UUID components,
/// never an arbitrary persisted path, and every resolved URL is containment-
/// checked before the UI or persistence layer can access it.
enum ConversationAssetStore {
    nonisolated static let maximumAssetBytes = 25 * 1_024 * 1_024

    nonisolated static func fileURL(for reference: ConversationImageAssetReference) throws -> URL {
        guard reference.contentIndex >= 0,
              reference.contentIndex < 10_000,
              reference.byteCount > 0,
              reference.byteCount <= maximumAssetBytes,
              reference.mimeType.hasPrefix("image/") else {
            throw ConversationAssetStoreError.invalidReference
        }

        let directory = agentDirectoryURL(projectID: reference.projectID, agentID: reference.agentID)
        let filename = "\(reference.messageID.uuidString)-\(reference.contentIndex).asset"
        let candidate = directory.appendingPathComponent(filename, isDirectory: false).standardizedFileURL
        let canonicalDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalCandidate = candidate.resolvingSymlinksInPath()
        let prefix = canonicalDirectory.path.hasSuffix("/")
            ? canonicalDirectory.path
            : canonicalDirectory.path + "/"
        guard canonicalCandidate.path.hasPrefix(prefix) else {
            throw ConversationAssetStoreError.invalidReference
        }
        return candidate
    }

    nonisolated static func agentDirectoryURL(projectID: UUID, agentID: UUID) -> URL {
        baseDirectoryURL
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent(agentID.uuidString, isDirectory: true)
    }

    nonisolated static func persistAssets(
        in conversation: PersistedConversation,
        projectID: UUID
    ) throws -> (conversation: PersistedConversation, references: Set<ConversationImageAssetReference>) {
        var persisted = conversation
        var references: Set<ConversationImageAssetReference> = []

        persisted.messages = try conversation.messages.map { message in
            var persistedMessage = message
            persistedMessage.content = try message.content.enumerated().map { index, content in
                switch content {
                case .image(let data, let mimeType):
                    guard !data.isEmpty else { return content }
                    guard data.count <= maximumAssetBytes else {
                        throw ConversationAssetStoreError.oversizedAsset
                    }
                    let reference = ConversationImageAssetReference(
                        projectID: projectID,
                        agentID: conversation.agentID,
                        messageID: message.id,
                        contentIndex: index,
                        mimeType: mimeType,
                        byteCount: data.count
                    )
                    try write(data, for: reference)
                    references.insert(reference)
                    return .imageAsset(reference)

                case .imageAsset(let reference):
                    guard reference.projectID == projectID,
                          reference.agentID == conversation.agentID else {
                        throw ConversationAssetStoreError.invalidReference
                    }
                    _ = try fileURL(for: reference)
                    references.insert(reference)
                    return content

                default:
                    return content
                }
            }
            return persistedMessage
        }

        return (persisted, references)
    }

    nonisolated static func persistImageAssets(
        in messages: [ConversationMessage],
        projectID: UUID,
        agentID: UUID,
        alreadyPersisted: Set<ConversationImageAssetReference> = []
    ) throws -> Set<ConversationImageAssetReference> {
        var references = alreadyPersisted
        for message in messages {
            for (index, content) in message.content.enumerated() {
                switch content {
                case .image(let data, let mimeType):
                    guard !data.isEmpty else { continue }
                    guard data.count <= maximumAssetBytes else {
                        throw ConversationAssetStoreError.oversizedAsset
                    }
                    let reference = ConversationImageAssetReference(
                        projectID: projectID,
                        agentID: agentID,
                        messageID: message.id,
                        contentIndex: index,
                        mimeType: mimeType,
                        byteCount: data.count
                    )
                    if !references.contains(reference) {
                        try write(data, for: reference)
                    }
                    references.insert(reference)

                case .imageAsset(let reference):
                    guard reference.projectID == projectID,
                          reference.agentID == agentID,
                          (try? fileURL(for: reference).checkResourceIsReachable()) == true else {
                        continue
                    }
                    references.insert(reference)

                default:
                    continue
                }
            }
        }
        return references
    }

    /// Replaces only inline images that have a verified durable counterpart.
    /// Message IDs and content positions make an older coalesced save harmless
    /// if newer messages arrived while the background write was running.
    nonisolated static func materializingPersistedImages(
        in liveMessages: [ConversationMessage],
        from persistedReferences: Set<ConversationImageAssetReference>,
        projectID: UUID,
        agentID: UUID
    ) -> [ConversationMessage]? {
        var referencesByMessage: [UUID: [Int: ConversationImageAssetReference]] = [:]
        for reference in persistedReferences {
            guard reference.projectID == projectID,
                  reference.agentID == agentID,
                  (try? fileURL(for: reference).checkResourceIsReachable()) == true else {
                continue
            }
            referencesByMessage[reference.messageID, default: [:]][reference.contentIndex] = reference
        }
        guard !referencesByMessage.isEmpty else { return nil }

        var changed = false
        let materialized = liveMessages.map { message in
            guard let references = referencesByMessage[message.id] else { return message }
            var updated = message
            updated.content = message.content.enumerated().map { index, content in
                guard case .image(let data, let mimeType) = content,
                      let reference = references[index],
                      reference.mimeType == mimeType,
                      reference.byteCount == data.count else {
                    return content
                }
                changed = true
                return .imageAsset(reference)
            }
            return updated
        }
        return changed ? materialized : nil
    }

    nonisolated static func updatedNativeImageSidecar(
        existing: [NativeImageSidecarEntry],
        messages: [ConversationMessage],
        sessionID: String?,
        projectID: UUID,
        agentID: UUID
    ) -> [NativeImageSidecarEntry] {
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty else {
            return []
        }

        struct EntryKey: Hashable {
            var sessionID: String
            var correlation: ConversationImageCorrelationKey
        }

        struct HistoricalKey: Hashable {
            var promptDigest: String
            var messageID: UUID
        }

        var entries: [EntryKey: NativeImageSidecarEntry] = [:]
        var currentEntryOrder: [EntryKey] = []
        let currentMessageIDs = Set(messages.map(\.id))
        let currentAssetReferences = Set(messages.flatMap { message in
            message.content.compactMap { content -> ConversationImageAssetReference? in
                guard case .imageAsset(let reference) = content else { return nil }
                return reference
            }
        })
        var historicalEntries: [HistoricalKey: NativeImageSidecarEntry] = [:]
        var historicalOrder: [HistoricalKey] = []
        for entry in existing where entry.sessionID == sessionID {
            let references = validReferences(
                entry.references,
                projectID: projectID,
                agentID: agentID,
                requireExistingFile: false
            )
            guard !references.isEmpty else { continue }
            let isRepresentedInCurrentMessages = references.contains {
                currentMessageIDs.contains($0.messageID) || currentAssetReferences.contains($0)
            }
            guard !isRepresentedInCurrentMessages, let messageID = references.first?.messageID else {
                continue
            }
            let normalized = NativeImageSidecarEntry(
                sessionID: sessionID,
                correlation: entry.correlation,
                references: references
            )
            let historicalKey = HistoricalKey(
                promptDigest: entry.correlation.promptDigest,
                messageID: messageID
            )
            if let retained = historicalEntries[historicalKey] {
                if retained.correlation.reverseOccurrence <= entry.correlation.reverseOccurrence {
                    continue
                }
            } else {
                // The persisted sidecar is stored newest-first. Preserve that
                // order across refreshes so unique prompt digests retain real
                // recency instead of being reordered lexically by their hash.
                historicalOrder.append(historicalKey)
            }
            historicalEntries[historicalKey] = normalized
        }

        let correlations = ConversationImageCorrelation.imageKeysByMessageID(in: messages)
        let currentCounts = correlations.values.reduce(into: [String: Int]()) { counts, correlation in
            counts[correlation.promptDigest, default: 0] += 1
        }
        // Current transcript messages have authoritative chronology. Visit
        // them newest-first so the bounded sidecar can never evict a newly
        // submitted image in favor of an older unrelated prompt digest.
        for message in messages.reversed() where message.role == .user {
            guard let correlation = correlations[message.id] else { continue }
            let references = message.content.enumerated().compactMap { index, content -> ConversationImageAssetReference? in
                switch content {
                case .image(let data, let mimeType) where !data.isEmpty && data.count <= maximumAssetBytes:
                    return ConversationImageAssetReference(
                        projectID: projectID,
                        agentID: agentID,
                        messageID: message.id,
                        contentIndex: index,
                        mimeType: mimeType,
                        byteCount: data.count
                    )
                case .imageAsset(let reference)
                    where reference.projectID == projectID && reference.agentID == agentID:
                    return reference
                default:
                    return nil
                }
            }
            guard !references.isEmpty else { continue }
            let key = EntryKey(sessionID: sessionID, correlation: correlation)
            entries[key] = NativeImageSidecarEntry(
                sessionID: sessionID,
                correlation: correlation,
                references: references
            )
            currentEntryOrder.append(key)
        }

        var historicalCounts: [String: Int] = [:]
        var historicalEntryOrder: [EntryKey] = []
        for historicalKey in historicalOrder {
            guard let entry = historicalEntries[historicalKey] else { continue }
            let promptDigest = historicalKey.promptDigest
            let correlation = ConversationImageCorrelationKey(
                promptDigest: promptDigest,
                reverseOccurrence: currentCounts[promptDigest, default: 0]
                    + historicalCounts[promptDigest, default: 0]
            )
            historicalCounts[promptDigest, default: 0] += 1
            let key = EntryKey(sessionID: sessionID, correlation: correlation)
            entries[key] = NativeImageSidecarEntry(
                sessionID: sessionID,
                correlation: correlation,
                references: entry.references
            )
            historicalEntryOrder.append(key)
        }

        var retained: [NativeImageSidecarEntry] = []
        retained.reserveCapacity(min(500, entries.count))
        var seen: Set<EntryKey> = []
        for key in currentEntryOrder + historicalEntryOrder where seen.insert(key).inserted {
            if let entry = entries[key] {
                retained.append(entry)
            }
            if retained.count == 500 { break }
        }
        return retained
    }

    nonisolated static func reattachingNativeImages(
        to nativeMessages: [ConversationMessage],
        from cachedMessages: [ConversationMessage],
        sidecar: [NativeImageSidecarEntry],
        sessionID: String,
        projectID: UUID,
        agentID: UUID
    ) -> [ConversationMessage] {
        let cachedCorrelations = ConversationImageCorrelation.imageKeysByMessageID(in: cachedMessages)
        var cachedImages: [ConversationImageCorrelationKey: [MessageContent]] = [:]
        for message in cachedMessages where message.role == .user {
            guard let correlation = cachedCorrelations[message.id] else { continue }
            let images = message.content.compactMap { content -> MessageContent? in
                switch content {
                case .image(let data, _) where !data.isEmpty:
                    return content
                case .imageAsset(let reference)
                    where reference.projectID == projectID
                        && reference.agentID == agentID
                        && (try? fileURL(for: reference).checkResourceIsReachable()) == true:
                    return content
                default:
                    return nil
                }
            }
            if !images.isEmpty {
                cachedImages[correlation] = images
            }
        }

        var sidecarImages: [ConversationImageCorrelationKey: [MessageContent]] = [:]
        for entry in sidecar where entry.sessionID == sessionID {
            let references = validReferences(
                entry.references,
                projectID: projectID,
                agentID: agentID,
                requireExistingFile: true
            )
            if !references.isEmpty {
                sidecarImages[entry.correlation] = references.map(MessageContent.imageAsset)
            }
        }

        let nativeCorrelations = ConversationImageCorrelation.imageKeysByMessageID(in: nativeMessages)
        return nativeMessages.map { message in
            guard message.role == .user,
                  let correlation = nativeCorrelations[message.id],
                  let images = cachedImages[correlation] ?? sidecarImages[correlation],
                  !images.isEmpty else {
                return message
            }
            if message.content.contains(where: { content in
                if case .image = content { return true }
                if case .imageAsset = content { return true }
                return false
            }) {
                return message
            }

            var restored = message
            let cleanedContent = message.content.compactMap { content -> MessageContent? in
                guard case .text(let text) = content else { return content }
                let cleaned = removingProviderImagePlaceholders(from: text)
                return cleaned.isEmpty ? nil : .text(cleaned)
            }
            restored.content = images + cleanedContent
            return restored
        }
    }

    nonisolated static func nativeImageReferences(
        in sidecar: [NativeImageSidecarEntry],
        projectID: UUID,
        agentID: UUID
    ) -> Set<ConversationImageAssetReference> {
        Set(sidecar.flatMap {
            validReferences(
                $0.references,
                projectID: projectID,
                agentID: agentID,
                requireExistingFile: true
            )
        })
    }

    nonisolated static func removeUnreferencedAssets(
        projectID: UUID,
        agentID: UUID,
        retaining references: Set<ConversationImageAssetReference>
    ) {
        let directory = agentDirectoryURL(projectID: projectID, agentID: agentID)
        let retainedNames = Set(references.compactMap { reference in
            try? fileURL(for: reference).lastPathComponent
        })
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for url in urls where !retainedNames.contains(url.lastPathComponent) {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                continue
            }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                conversationAssetLogger.error(
                    "Failed to remove orphaned asset: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    nonisolated private static var baseDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent(AppEnvironment.appSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("conversations", isDirectory: true)
    }

    nonisolated private static func validReferences(
        _ references: [ConversationImageAssetReference],
        projectID: UUID,
        agentID: UUID,
        requireExistingFile: Bool
    ) -> [ConversationImageAssetReference] {
        var seen: Set<ConversationImageAssetReference> = []
        return references.filter { reference in
            guard reference.projectID == projectID,
                  reference.agentID == agentID,
                  seen.insert(reference).inserted,
                  let url = try? fileURL(for: reference) else {
                return false
            }
            return !requireExistingFile || (try? url.checkResourceIsReachable()) == true
        }
    }

    nonisolated private static func removingProviderImagePlaceholders(from text: String) -> String {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed != "[Image]" && !trimmed.hasPrefix("Attached image:")
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func write(
        _ data: Data,
        for reference: ConversationImageAssetReference
    ) throws {
        guard !data.isEmpty else { throw ConversationAssetStoreError.missingImageData }
        guard data.count == reference.byteCount, data.count <= maximumAssetBytes else {
            throw ConversationAssetStoreError.oversizedAsset
        }

        let url = try fileURL(for: reference)
        let directory = url.deletingLastPathComponent()
        let assetsDirectory = directory.deletingLastPathComponent()
        let projectDirectory = assetsDirectory.deletingLastPathComponent()
        let conversationsDirectory = projectDirectory.deletingLastPathComponent()
        let appDirectory = conversationsDirectory.deletingLastPathComponent()
        let manager = FileManager.default
        for protectedDirectory in [
            appDirectory, conversationsDirectory, projectDirectory, assetsDirectory, directory,
        ] {
            try manager.createDirectory(
                at: protectedDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try manager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: protectedDirectory.path
            )
        }
        try data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
