import Foundation
import Testing
@testable import FXAgent
@testable import FXCore

private func claudeNativeProjectDirectory(
    configRoot: URL,
    workspace: URL
) throws -> (canonicalWorkspace: String, projectDirectory: URL) {
    let canonicalWorkspace = workspace.standardizedFileURL.resolvingSymlinksInPath().path
    let projectKey = canonicalWorkspace.unicodeScalars.map { scalar -> Character in
        CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
    }
    let projectDirectory = configRoot
        .appendingPathComponent("projects", isDirectory: true)
        .appendingPathComponent(String(projectKey), isDirectory: true)
    try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
    return (canonicalWorkspace, projectDirectory)
}

private func claudeNativeJSONL(_ records: [[String: Any]]) throws -> Data {
    var result = Data()
    for record in records {
        result.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
        result.append(0x0A)
    }
    return result
}

@Test func claudeNativeSummaryExtractsRealConfigurationShapesAndLatestBoundedValues() async throws {
    let manager = FileManager.default
    let container = manager.temporaryDirectory
        .appendingPathComponent("flowx-claude-native-configuration-\(UUID().uuidString)", isDirectory: true)
    let workspace = container.appendingPathComponent("workspace", isDirectory: true)
    let config = container.appendingPathComponent("claude-config", isDirectory: true)
    try manager.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: container) }

    let fixture = try claudeNativeProjectDirectory(configRoot: config, workspace: workspace)
    let sessionID = "a1111111-2222-4333-8444-555555555555"
    let file = fixture.projectDirectory
        .appendingPathComponent(sessionID)
        .appendingPathExtension("jsonl")

    let initialRecords: [[String: Any]] = [
        [
            "type": "mode",
            "sessionId": sessionID,
            "mode": "normal",
        ],
        [
            "type": "permission-mode",
            "sessionId": sessionID,
            "permissionMode": "bypassPermissions",
        ],
        [
            "type": "user",
            "sessionId": sessionID,
            "cwd": fixture.canonicalWorkspace,
            "timestamp": "2026-07-23T06:21:45.000Z",
            "permissionMode": "bypassPermissions",
            "message": [
                "role": "user",
                "content": "Build the Waka page",
            ],
        ],
        [
            "type": "assistant",
            "sessionId": sessionID,
            "cwd": fixture.canonicalWorkspace,
            "timestamp": "2026-07-23T06:21:46.000Z",
            "effort": "xhigh",
            "message": [
                "role": "assistant",
                "model": "claude-fable-5",
                "content": [["type": "text", "text": "Built"]],
            ],
        ],
    ]
    let initialData = try claudeNativeJSONL(initialRecords)
    try initialData.write(to: file)

    let store = ClaudeNativeThreadStore(configRoot: config)
    let initialSummary = try #require(
        try await store.list(workingDirectory: workspace, limit: 10).first
    )
    #expect(initialSummary.model == "claude-fable-5")
    #expect(initialSummary.effort == "xhigh")
    #expect(initialSummary.agentMode == .auto)
    #expect(initialSummary.agentAccess == .fullAccess)

    let initialThread = try await store.read(id: sessionID, workingDirectory: workspace)
    #expect(initialThread.summary.model == "claude-fable-5")
    #expect(initialThread.summary.effort == "xhigh")
    #expect(initialThread.summary.agentMode == .auto)
    #expect(initialThread.summary.agentAccess == .fullAccess)

    let largeMiddleRecord: [String: Any] = [
        "type": "progress",
        "payload": String(repeating: "x", count: 1_100_000),
    ]
    let acceptEditsRecords: [[String: Any]] = [
        [
            "type": "mode",
            "sessionId": sessionID,
            "mode": "default",
        ],
        [
            "type": "permission-mode",
            "sessionId": sessionID,
            "permissionMode": "acceptEdits",
        ],
        [
            "type": "assistant",
            "sessionId": sessionID,
            "cwd": fixture.canonicalWorkspace,
            "timestamp": "2026-07-23T06:22:00.000Z",
            "effort": "high",
            "message": [
                "role": "assistant",
                "model": "claude-opus-4-1",
                "content": [["type": "text", "text": "Updated"]],
            ],
        ],
    ]
    let acceptEditsData = try claudeNativeJSONL(
        initialRecords + [largeMiddleRecord] + acceptEditsRecords
    )
    try acceptEditsData.write(to: file, options: [.atomic])

    let acceptEditsSummary = try #require(
        try await store.list(workingDirectory: workspace, limit: 10).first
    )
    #expect(acceptEditsSummary.model == "claude-opus-4-1")
    #expect(acceptEditsSummary.effort == "high")
    #expect(acceptEditsSummary.agentMode == .auto)
    #expect(acceptEditsSummary.agentAccess == .acceptEdits)

    let planRecords: [[String: Any]] = [
        [
            "type": "mode",
            "sessionId": sessionID,
            "mode": "plan",
        ],
        [
            "type": "permission-mode",
            "sessionId": sessionID,
            "permissionMode": "default",
        ],
    ]
    let planData = try claudeNativeJSONL(
        initialRecords + [largeMiddleRecord] + acceptEditsRecords + planRecords
    )
    try planData.write(to: file, options: [.atomic])

    let planSummary = try #require(
        try await store.list(workingDirectory: workspace, limit: 10).first
    )
    #expect(planSummary.model == "claude-opus-4-1")
    #expect(planSummary.effort == "high")
    #expect(planSummary.agentMode == .plan)
    #expect(planSummary.agentAccess == .supervised)

    let planThread = try await store.read(id: sessionID, workingDirectory: workspace)
    #expect(planThread.summary.agentMode == .plan)
    #expect(planThread.summary.agentAccess == .supervised)
}

@Test func claudeNativeSummaryLeavesMissingAndLatestUnknownConfigurationUnset() async throws {
    let manager = FileManager.default
    let container = manager.temporaryDirectory
        .appendingPathComponent("flowx-claude-native-unknown-configuration-\(UUID().uuidString)", isDirectory: true)
    let workspace = container.appendingPathComponent("workspace", isDirectory: true)
    let config = container.appendingPathComponent("claude-config", isDirectory: true)
    try manager.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: container) }

    let fixture = try claudeNativeProjectDirectory(configRoot: config, workspace: workspace)
    let unknownSessionID = "b1111111-2222-4333-8444-555555555555"
    let unknownRecords: [[String: Any]] = [
        [
            "type": "mode",
            "sessionId": unknownSessionID,
            "mode": "normal",
        ],
        [
            "type": "permission-mode",
            "sessionId": unknownSessionID,
            "permissionMode": "bypassPermissions",
        ],
        [
            "type": "assistant",
            "sessionId": unknownSessionID,
            "cwd": fixture.canonicalWorkspace,
            "timestamp": "2026-07-23T07:00:00.000Z",
            "effort": "xhigh",
            "message": [
                "role": "assistant",
                "model": "claude-fable-5",
                "content": [["type": "text", "text": "Known configuration"]],
            ],
        ],
        [
            "type": "mode",
            "sessionId": unknownSessionID,
            "mode": "bypassPermissions",
        ],
        [
            "type": "permission-mode",
            "sessionId": unknownSessionID,
            "permissionMode": "plan",
        ],
        [
            "type": "assistant",
            "sessionId": unknownSessionID,
            "cwd": fixture.canonicalWorkspace,
            "timestamp": "2026-07-23T07:01:00.000Z",
            "effort": NSNull(),
            "message": [
                "role": "assistant",
                "model": NSNull(),
                "content": [["type": "text", "text": "Unknown configuration"]],
            ],
        ],
    ]
    try claudeNativeJSONL(unknownRecords).write(
        to: fixture.projectDirectory
            .appendingPathComponent(unknownSessionID)
            .appendingPathExtension("jsonl")
    )

    let missingSessionID = "c1111111-2222-4333-8444-555555555555"
    let missingRecords: [[String: Any]] = [[
        "type": "user",
        "sessionId": missingSessionID,
        "cwd": fixture.canonicalWorkspace,
        "timestamp": "2026-07-23T06:00:00.000Z",
        "message": [
            "role": "user",
            "content": "No configuration metadata",
        ],
    ]]
    try claudeNativeJSONL(missingRecords).write(
        to: fixture.projectDirectory
            .appendingPathComponent(missingSessionID)
            .appendingPathExtension("jsonl")
    )

    let store = ClaudeNativeThreadStore(configRoot: config)
    let summaries = try await store.list(workingDirectory: workspace, limit: 10)
    let unknownSummary = try #require(summaries.first { $0.id == unknownSessionID })
    #expect(unknownSummary.model == nil)
    #expect(unknownSummary.effort == nil)
    #expect(unknownSummary.agentMode == nil)
    #expect(unknownSummary.agentAccess == nil)

    let unknownThread = try await store.read(id: unknownSessionID, workingDirectory: workspace)
    #expect(unknownThread.summary.model == nil)
    #expect(unknownThread.summary.effort == nil)
    #expect(unknownThread.summary.agentMode == nil)
    #expect(unknownThread.summary.agentAccess == nil)

    let missingSummary = try #require(summaries.first { $0.id == missingSessionID })
    #expect(missingSummary.model == nil)
    #expect(missingSummary.effort == nil)
    #expect(missingSummary.agentMode == nil)
    #expect(missingSummary.agentAccess == nil)
}
