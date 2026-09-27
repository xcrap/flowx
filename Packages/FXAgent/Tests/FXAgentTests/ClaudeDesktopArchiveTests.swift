import Foundation
import Testing
@testable import FXAgent

@Test func claudeSessionsArchivedInTheClaudeAppMoveToArchivedTasks() async throws {
    let manager = FileManager.default
    let container = manager.temporaryDirectory
        .appendingPathComponent("flowx-claude-desktop-archive-\(UUID().uuidString)", isDirectory: true)
    let workspace = container.appendingPathComponent("workspace", isDirectory: true)
    let config = container.appendingPathComponent("claude-config", isDirectory: true)
    let desktop = container.appendingPathComponent("claude-code-sessions", isDirectory: true)
    try manager.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: container) }

    let canonical = workspace.standardizedFileURL.resolvingSymlinksInPath().path
    let projectKey = canonical.unicodeScalars.map { scalar -> Character in
        CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
    }
    let project = config
        .appendingPathComponent("projects", isDirectory: true)
        .appendingPathComponent(String(projectKey), isDirectory: true)
    try manager.createDirectory(at: project, withIntermediateDirectories: true)

    let liveID = "11111111-2222-4333-8444-555555555555"
    let archivedID = "66666666-7777-4888-9999-aaaaaaaaaaaa"
    for id in [liveID, archivedID] {
        let record = #"{"type":"user","uuid":"UUID","sessionId":"ID","cwd":"WORKSPACE","timestamp":"2026-09-27T10:00:00.000Z","message":{"content":"Hello"}}"#
            .replacingOccurrences(of: "UUID", with: UUID().uuidString.lowercased())
            .replacingOccurrences(of: "ID", with: id)
            .replacingOccurrences(of: "WORKSPACE", with: canonical)
        try Data((record + "\n").utf8)
            .write(to: project.appendingPathComponent(id).appendingPathExtension("jsonl"))
    }

    // The Claude app keeps one metadata file per session it wraps.
    let organization = desktop
        .appendingPathComponent("account", isDirectory: true)
        .appendingPathComponent("organization", isDirectory: true)
    try manager.createDirectory(at: organization, withIntermediateDirectories: true)
    func writeMetadata(_ id: String, archived: Bool) throws {
        let metadata: [String: Any] = ["cliSessionId": id, "isArchived": archived, "title": "Task"]
        try JSONSerialization.data(withJSONObject: metadata)
            .write(to: organization.appendingPathComponent("local_\(id).json"))
    }
    try writeMetadata(liveID, archived: false)
    try writeMetadata(archivedID, archived: true)

    let store = ClaudeNativeThreadStore(configRoot: config, desktopSessionsRoot: desktop)
    #expect(try await store.list(workingDirectory: workspace, limit: 10).map(\.id) == [liveID])
    #expect(try await store.list(workingDirectory: workspace, limit: 10, archived: true).map(\.id) == [archivedID])
    let revision = try #require(await store.desktopArchiveRevision())

    // Unarchiving in the Claude app changes the revision and the listing.
    try await Task.sleep(for: .milliseconds(20))
    try writeMetadata(archivedID, archived: false)
    #expect(await store.desktopArchiveRevision() != revision)
    #expect(try await Set(store.list(workingDirectory: workspace, limit: 10).map(\.id)) == [liveID, archivedID])
    #expect(try await store.list(workingDirectory: workspace, limit: 10, archived: true).isEmpty)

    // Without the Claude app's metadata nothing is treated as archived.
    let standalone = ClaudeNativeThreadStore(configRoot: config)
    #expect(try await standalone.list(workingDirectory: workspace, limit: 10).count == 2)
}
