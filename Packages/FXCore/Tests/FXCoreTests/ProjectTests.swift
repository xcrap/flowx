import Foundation
import Testing
@testable import FXCore

@Test func projectNormalizesEquivalentRootPaths() {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("flowx-project-normalization", isDirectory: true)
    let pathWithDotSegments = root
        .appendingPathComponent("nested", isDirectory: true)
        .appendingPathComponent("..", isDirectory: true)
        .path

    #expect(Project.normalizedRootPath(pathWithDotSegments) == root.standardizedFileURL.path)
}

@Test func projectCanonicalPathResolvesSymbolicLinks() throws {
    let manager = FileManager.default
    let container = manager.temporaryDirectory
        .appendingPathComponent("flowx-project-canonical-\(UUID().uuidString)", isDirectory: true)
    let target = container.appendingPathComponent("target", isDirectory: true)
    let link = container.appendingPathComponent("link", isDirectory: true)
    try manager.createDirectory(at: target, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: container) }
    try manager.createSymbolicLink(at: link, withDestinationURL: target)

    let project = Project(rootPath: link.path)
    #expect(project.canonicalRootPath == target.path)
}

@Test func persistedProjectRootsRejectEmptyAndRelativePaths() {
    #expect(Project.validatedPersistedRootPath("") == nil)
    #expect(Project.validatedPersistedRootPath("relative/workspace") == nil)
    #expect(Project.validatedPersistedRootPath("/tmp/../tmp") == "/tmp")
}

@Test func imageAssetReferenceRoundTripsThroughMessageContent() throws {
    let reference = ConversationImageAssetReference(
        projectID: UUID(),
        agentID: UUID(),
        messageID: UUID(),
        contentIndex: 2,
        mimeType: "image/png",
        byteCount: 1_024
    )
    let encoded = try JSONEncoder().encode(MessageContent.imageAsset(reference))
    let decoded = try JSONDecoder().decode(MessageContent.self, from: encoded)
    #expect(decoded == .imageAsset(reference))
}

@Test func legacyInlineImageStillDecodes() throws {
    let data = Data([0x89, 0x50, 0x4E, 0x47])
    let encoded = try JSONEncoder().encode(MessageContent.image(data: data, mimeType: "image/png"))
    let decoded = try JSONDecoder().decode(MessageContent.self, from: encoded)
    #expect(decoded == .image(data: data, mimeType: "image/png"))
}

@Test func projectIndexSkipsGeneratedDirectoriesAtAnyDepth() {
    #expect(ProjectFileIndexPolicy.shouldSkip(relativePath: "Packages/FXAgent/.build", isDirectory: true))
    #expect(ProjectFileIndexPolicy.shouldSkip(relativePath: "apps/web/node_modules", isDirectory: true))
    #expect(ProjectFileIndexPolicy.shouldSkip(relativePath: "DerivedData", isDirectory: true))
    #expect(!ProjectFileIndexPolicy.shouldSkip(relativePath: "Packages/FXAgent/Sources", isDirectory: true))
}

@Test func projectIndexDoesNotSkipFilesNamedLikeBuildFolders() {
    #expect(!ProjectFileIndexPolicy.shouldSkip(relativePath: "Sources/dist", isDirectory: false))
    #expect(ProjectFileIndexPolicy.shouldSkipFile(relativePath: "apps/web/node_modules/package/index.js"))
    #expect(!ProjectFileIndexPolicy.shouldSkipFile(relativePath: "Sources/dist"))
}

@Test func imageCorrelationIgnoresProviderPlaceholders() {
    let local = ConversationMessage(
        role: .user,
        content: [.image(data: Data([1]), mimeType: "image/png"), .text("  inspect this image  ")]
    )
    let codex = ConversationMessage(role: .user, content: [.text("[Image]\ninspect this image")])
    let claude = ConversationMessage(
        role: .user,
        content: [.text("Attached image: /private/tmp/random/image.png\ninspect this image")]
    )

    #expect(ConversationImageCorrelation.promptDigest(for: local) == ConversationImageCorrelation.promptDigest(for: codex))
    #expect(ConversationImageCorrelation.promptDigest(for: local) == ConversationImageCorrelation.promptDigest(for: claude))
}

@Test func imageCorrelationCountsRepeatedPromptsFromNewest() {
    let older = ConversationMessage(role: .user, content: [.text("repeat")])
    let newer = ConversationMessage(role: .user, content: [.text("repeat")])
    let keys = ConversationImageCorrelation.keysByMessageID(in: [older, newer])

    #expect(keys[newer.id]?.reverseOccurrence == 0)
    #expect(keys[older.id]?.reverseOccurrence == 1)
}

@Test func imageCorrelationDoesNotAttachAnImageToANewerTextOnlyRepeat() {
    let imagePrompt = ConversationMessage(
        role: .user,
        content: [.image(data: Data([1]), mimeType: "image/png"), .text("repeat")]
    )
    let textOnlyRepeat = ConversationMessage(role: .user, content: [.text("repeat")])
    let localKeys = ConversationImageCorrelation.imageKeysByMessageID(
        in: [imagePrompt, textOnlyRepeat]
    )

    #expect(localKeys[imagePrompt.id]?.reverseOccurrence == 0)
    #expect(localKeys[textOnlyRepeat.id] == nil)

    let nativeImagePrompt = ConversationMessage(role: .user, content: [.text("[Image]\nrepeat")])
    let nativeTextOnlyRepeat = ConversationMessage(role: .user, content: [.text("repeat")])
    let nativeKeys = ConversationImageCorrelation.imageKeysByMessageID(
        in: [nativeImagePrompt, nativeTextOnlyRepeat]
    )

    #expect(nativeKeys[nativeImagePrompt.id] == localKeys[imagePrompt.id])
    #expect(nativeKeys[nativeTextOnlyRepeat.id] == nil)
}

@Test func imageCorrelationCountsOnlyRepeatedImagePrompts() {
    let older = ConversationMessage(
        role: .user,
        content: [.image(data: Data([1]), mimeType: "image/png"), .text("repeat")]
    )
    let textOnly = ConversationMessage(role: .user, content: [.text("repeat")])
    let newer = ConversationMessage(
        role: .user,
        content: [.image(data: Data([2]), mimeType: "image/png"), .text("repeat")]
    )
    let keys = ConversationImageCorrelation.imageKeysByMessageID(in: [older, textOnly, newer])

    #expect(keys[newer.id]?.reverseOccurrence == 0)
    #expect(keys[older.id]?.reverseOccurrence == 1)
    #expect(keys[textOnly.id] == nil)
}

@Test func providerNativeConfigurationPreservesInheritedModeAndAccess() throws {
    let configuration = AgentConfiguration(
        providerID: "codex",
        modelID: nil,
        effort: nil,
        agentMode: nil,
        agentAccess: nil
    )

    let encoded = try JSONEncoder().encode(configuration)
    let decoded = try JSONDecoder().decode(AgentConfiguration.self, from: encoded)

    #expect(decoded.agentMode == nil)
    #expect(decoded.agentAccess == nil)
}

@Test func nativeProjectionRemovesOutOfWindowRowsOnlyForSuccessfulProviders() {
    struct Identity: Hashable {
        var provider: String
        var session: String
    }

    let retained = Identity(provider: "codex", session: "current")
    let outOfWindow = Identity(provider: "codex", session: "older-than-cap")
    let streaming = Identity(provider: "codex", session: "streaming")
    let selected = Identity(provider: "codex", session: "selected")
    let failedProvider = Identity(provider: "claude", session: "preserve")

    let removed = NativeProjectionPolicy.identitiesToRemove(
        visibleIdentities: [retained, outOfWindow, streaming, selected, failedProvider],
        returnedIdentities: [retained],
        successfullyListedProviders: ["codex"],
        protectedIdentities: [streaming, selected],
        providerID: \.provider
    )

    #expect(removed == [outOfWindow])
}

@Test func nativeProjectionBoundsDormantIdentityMappings() {
    let retained = NativeProjectionPolicy.retainedIdentities(
        activeIdentities: ["active-a", "active-b"],
        reserveIdentities: ["active-a", "recent-a", "recent-b", "old"],
        reserveLimit: 2
    )

    #expect(retained == ["active-a", "active-b", "recent-a", "recent-b"])
}

@Test func imageMaterializationIsIndependentOfNativeTranscriptCacheWindow() {
    let imagePrompt = ConversationMessage(
        role: .user,
        content: [.image(data: Data([1, 2, 3]), mimeType: "image/png"), .text("inspect")]
    )
    let laterMessages = (0..<251).map { index in
        ConversationMessage(role: .assistant, content: [.text("event \(index)")])
    }
    let retainedHistory = [imagePrompt] + laterMessages

    #expect(Array(retainedHistory.suffix(250)).contains(where: { $0.id == imagePrompt.id }) == false)
    #expect(
        ConversationImagePersistencePolicy.materializationMessages(from: retainedHistory).map(\.id)
            == [imagePrompt.id]
    )
}

@Test func coalescedImageMaterializationKeepsEarlierPromptAssets() {
    let first = ConversationMessage(
        role: .user,
        content: [.image(data: Data([1]), mimeType: "image/png")]
    )
    let second = ConversationMessage(
        role: .user,
        content: [.image(data: Data([2]), mimeType: "image/png")]
    )
    let merged = ConversationImagePersistencePolicy.mergingMaterializationMessages(
        existing: [first],
        newer: [second, second],
        limit: 250
    )

    #expect(merged.map(\.id) == [first.id, second.id])
}
