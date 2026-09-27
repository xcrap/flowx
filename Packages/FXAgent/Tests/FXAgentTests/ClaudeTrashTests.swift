import Foundation
import Testing
@testable import FXAgent

@Test func claudeTrashOnlyReportsMissingWhenAllExactArtifactsAreAbsent() async throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let workspace = root.appendingPathComponent("workspace")
    let config = root.appendingPathComponent("config")
    try manager.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    let path = workspace.resolvingSymlinksInPath().standardizedFileURL.path
    let key = String(path.unicodeScalars.map {
        CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : "-"
    })
    let directory = config.appendingPathComponent("projects").appendingPathComponent(key)
    let id = "41111111-2222-4333-8444-555555555555"
    let file = directory.appendingPathComponent("\(id).jsonl")
    let store = ClaudeNativeThreadStore(configRoot: config, trashHandler: { _ in
        Issue.record("Unvalidated artifacts must never reach Trash")
    })

    await #expect(throws: NativeThreadTrashError.sessionMissing) {
        try await store.moveToTrash(id: id, workingDirectory: workspace)
    }
    let subagents = directory.appendingPathComponent(id).appendingPathComponent("subagents")
    try manager.createDirectory(at: subagents, withIntermediateDirectories: true)
    do {
        try await store.moveToTrash(id: id, workingDirectory: workspace)
        Issue.record("An orphaned session directory needs validation")
    } catch {
        #expect(!(error is NativeThreadTrashError))
    }
    try manager.removeItem(at: directory.appendingPathComponent(id))

    for contents in [
        "invalid JSON",
        "{\"type\":\"user\",\"sessionId\":\"\(id)\",\"cwd\":\"/another-workspace\",\"message\":{\"content\":\"Other task\"}}\n",
    ] {
        try Data(contents.utf8).write(to: file)
        do {
            try await store.moveToTrash(id: id, workingDirectory: workspace)
            Issue.record("Existing unvalidated transcripts must not be treated as missing")
        } catch {
            #expect(!(error is NativeThreadTrashError))
        }
        #expect(manager.fileExists(atPath: file.path))
    }

    // Permissions failures must never authorize removing the local fallback.
    try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
    defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
    do {
        try await store.moveToTrash(id: id, workingDirectory: workspace)
        Issue.record("Unreadable session directories must fail")
    } catch {
        #expect(!(error is NativeThreadTrashError))
    }
}
