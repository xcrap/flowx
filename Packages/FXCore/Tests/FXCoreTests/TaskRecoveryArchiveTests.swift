import Foundation
import Testing
@testable import FXCore

@Test func missingProviderTaskRecoveryPreservesCacheAttachmentsAndOriginalPaths() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? manager.removeItem(at: root) }
    let assets = root.appendingPathComponent("assets")
    try manager.createDirectory(at: assets, withIntermediateDirectories: true)
    let cache = root.appendingPathComponent("conversation.json")
    let image = assets.appendingPathComponent("image.asset")
    try Data("cached conversation".utf8).write(to: cache)
    try Data([1, 2, 3]).write(to: image)
    let trash = root.appendingPathComponent("trashed-recovery")
    let metadata = Data(#"{"sessionID":"missing-session"}"#.utf8)

    try TaskRecoveryArchive.copyToTrash(
        metadata: metadata,
        files: [cache, root.appendingPathComponent("absent.backup"), assets],
        stagingDirectory: root.appendingPathComponent("staging"),
        trashHandler: { try manager.moveItem(at: $0, to: trash) }
    )

    #expect(try Data(contentsOf: trash.appendingPathComponent("task.json")) == metadata)
    #expect(try Data(contentsOf: trash.appendingPathComponent("files/0/conversation.json")) == Data(contentsOf: cache))
    #expect(try Data(contentsOf: trash.appendingPathComponent("files/2/assets/image.asset")) == Data(contentsOf: image))
    let manifest = try #require(JSONSerialization.jsonObject(
        with: Data(contentsOf: trash.appendingPathComponent("files.json"))
    ) as? [[String: String]])
    #expect(manifest.map { $0["originalPath"] } == [cache.path, assets.path])
    #expect(manager.fileExists(atPath: cache.path))
    #expect(manager.fileExists(atPath: image.path))
}

@Test func taskRecoveryTrashFailureLeavesOriginalDataIntact() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    let cache = root.appendingPathComponent("conversation.json")
    let original = Data("only remaining conversation".utf8)
    try original.write(to: cache)
    let staging = root.appendingPathComponent("staging")

    #expect(throws: CocoaError.self) {
        try TaskRecoveryArchive.copyToTrash(
            metadata: Data("{}".utf8), files: [cache], stagingDirectory: staging,
            trashHandler: { _ in throw CocoaError(.fileWriteNoPermission) }
        )
    }
    #expect(try Data(contentsOf: cache) == original)
    #expect(try manager.contentsOfDirectory(atPath: staging.path).isEmpty)
}
