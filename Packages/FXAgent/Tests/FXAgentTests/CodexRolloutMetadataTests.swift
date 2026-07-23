import Foundation
import Testing
@testable import FXAgent
@testable import FXCore

private func rolloutLine(_ object: [String: Any]) throws -> Data {
    var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    data.append(0x0A)
    return data
}

private func rolloutSummary(
    id: String,
    createdAt: Date,
    model: String? = nil,
    effort: String? = nil,
    agentMode: AgentMode? = nil,
    agentAccess: AgentAccess? = nil
) -> ProviderNativeThreadSummary {
    ProviderNativeThreadSummary(
        providerID: "codex",
        id: id,
        title: "Native task",
        workingDirectory: "/workspace",
        createdAt: createdAt,
        updatedAt: createdAt,
        model: model,
        effort: effort,
        agentMode: agentMode,
        agentAccess: agentAccess,
        source: "codex"
    )
}

private func makeRolloutContainer(
    named name: String
) throws -> (container: URL, sessions: URL, datedDirectory: URL) {
    let manager = FileManager.default
    let container = manager.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    let sessions = container.appendingPathComponent("sessions", isDirectory: true)
    let datedDirectory = sessions
        .appendingPathComponent("2026", isDirectory: true)
        .appendingPathComponent("07", isDirectory: true)
        .appendingPathComponent("23", isDirectory: true)
    try manager.createDirectory(at: datedDirectory, withIntermediateDirectories: true)
    return (container, sessions, datedDirectory)
}

private let july24UTC = Date(timeIntervalSince1970: 1_784_851_200)

@Test func codexNativeConfigurationMapsOnlyExactProviderPolicies() {
    let supervised = CodexNativeConfiguration.parse([
        "approval_policy": "untrusted",
        "sandbox_policy": ["type": "workspace-write"],
    ])
    #expect(supervised.agentAccess == .supervised)

    let acceptEdits = CodexNativeConfiguration.parse([
        "approvalPolicy": "on-request",
        "sandboxPolicy": ["type": "workspace-write"],
    ])
    #expect(acceptEdits.agentAccess == .acceptEdits)

    let fullAccess = CodexNativeConfiguration.parse([
        "approval_policy": "never",
        "sandbox_policy": ["type": "danger-full-access"],
    ])
    #expect(fullAccess.agentAccess == .fullAccess)

    let unsafeGuess = CodexNativeConfiguration.parse([
        "approval_policy": "never",
        "sandbox_policy": ["type": "workspace-write"],
    ])
    #expect(unsafeGuess.agentAccess == nil)

    let missingSandbox = CodexNativeConfiguration.parse([
        "approval_policy": "on-request",
    ])
    #expect(missingSandbox.agentAccess == nil)
}

@Test func codexNativeSummaryUsesConfigurationReturnedByAppServer() throws {
    let summary = try #require(CodexProvider.nativeThreadSummaryForTesting([
        "id": "11111111-2222-4333-8444-555555555555",
        "cwd": "/workspace",
        "createdAt": 100,
        "recencyAt": 200,
        "preview": "Use the provider settings",
        "model": "gpt-5.6-sol",
        "effort": "ultra",
        "collaborationMode": ["mode": "plan"],
        "approvalPolicy": "on-request",
        "sandboxPolicy": ["type": "workspace-write"],
    ]))

    #expect(summary.model == "gpt-5.6-sol")
    #expect(summary.effort == "ultra")
    #expect(summary.agentMode == .plan)
    #expect(summary.agentAccess == .acceptEdits)
}

@Test func codexRolloutMetadataFindsAdjacentUTCDayAndKeepsAppServerValues() throws {
    let manager = FileManager.default
    let layout = try makeRolloutContainer(named: "flowx-codex-rollout-metadata")
    defer { try? manager.removeItem(at: layout.container) }

    let threadID = "21111111-2222-4333-8444-555555555555"
    let file = layout.datedDirectory
        .appendingPathComponent("rollout-2026-07-23T23-59-59-\(threadID)")
        .appendingPathExtension("jsonl")
    var transcript = try rolloutLine([
        "type": "session_meta",
        "payload": ["id": threadID],
    ])
    transcript.append(try rolloutLine([
        "type": "turn_context",
        "payload": [
            "model": "gpt-5.6-sol",
            "effort": "ultra",
            "collaboration_mode": [
                "mode": "plan",
                "settings": [
                    "model": "ignored-settings-model",
                    "reasoning_effort": "ignored-settings-effort",
                ],
            ],
            "approval_policy": "never",
            "sandbox_policy": ["type": "danger-full-access"],
        ],
    ]))
    try transcript.write(to: file)

    var store = CodexRolloutMetadataStore(sessionsRoot: layout.sessions)
    let original = rolloutSummary(
        id: threadID,
        createdAt: july24UTC,
        model: "app-server-model"
    )
    let enriched = try #require(store.enrich([original]).first)
    #expect(enriched.model == "app-server-model")
    #expect(enriched.effort == "ultra")
    #expect(enriched.agentMode == .plan)
    #expect(enriched.agentAccess == .fullAccess)

    let parses = store.metadataParseCount
    let scans = store.directoryScanCount
    let bytesRead = store.totalBytesRead
    let cached = try #require(store.enrich([original]).first)
    #expect(cached.agentAccess == .fullAccess)
    #expect(store.metadataParseCount == parses)
    #expect(store.directoryScanCount == scans)
    #expect(store.totalBytesRead == bytesRead)
}

@Test func codexRolloutMetadataRejectsFilenameMatchesWithTheWrongSessionID() throws {
    let manager = FileManager.default
    let layout = try makeRolloutContainer(named: "flowx-codex-rollout-id-safety")
    defer { try? manager.removeItem(at: layout.container) }

    let requestedID = "31111111-2222-4333-8444-555555555555"
    let file = layout.datedDirectory
        .appendingPathComponent("rollout-2026-07-23T12-00-00-\(requestedID)")
        .appendingPathExtension("jsonl")
    var transcript = try rolloutLine([
        "type": "session_meta",
        "payload": ["id": "39999999-2222-4333-8444-555555555555"],
    ])
    transcript.append(try rolloutLine([
        "type": "turn_context",
        "payload": [
            "model": "must-not-leak",
            "effort": "ultra",
            "collaboration_mode": ["mode": "plan"],
            "approval_policy": "never",
            "sandbox_policy": ["type": "danger-full-access"],
        ],
    ]))
    try transcript.write(to: file)

    var store = CodexRolloutMetadataStore(sessionsRoot: layout.sessions)
    let result = try #require(store.enrich([
        rolloutSummary(id: requestedID, createdAt: july24UTC),
    ]).first)
    #expect(result.model == nil)
    #expect(result.effort == nil)
    #expect(result.agentMode == nil)
    #expect(result.agentAccess == nil)
    #expect(store.metadataParseCount == 0)
}

@Test func codexRolloutMetadataFindsLatestContextAcrossALongTail() throws {
    let manager = FileManager.default
    let layout = try makeRolloutContainer(named: "flowx-codex-rollout-long-tail")
    defer { try? manager.removeItem(at: layout.container) }

    let threadID = "41111111-2222-4333-8444-555555555555"
    let file = layout.datedDirectory
        .appendingPathComponent("rollout-2026-07-23T12-00-00-\(threadID)")
        .appendingPathExtension("jsonl")
    var transcript = try rolloutLine([
        "type": "session_meta",
        "payload": ["id": threadID],
    ])
    transcript.append(try rolloutLine([
        "type": "turn_context",
        "payload": [
            "model": "stale-head-model",
            "effort": "low",
            "collaboration_mode": ["mode": "plan"],
            "approval_policy": "untrusted",
            "sandbox_policy": ["type": "workspace-write"],
        ],
    ]))
    transcript.append(try rolloutLine([
        "type": "event_msg",
        "payload": [
            "blob": String(
                repeating: "x",
                count: CodexRolloutMetadataStore.contextSearchChunkBytes * 2
            ),
        ],
    ]))
    transcript.append(try rolloutLine([
        "type": "turn_context",
        "payload": [
            "model": "gpt-5.6-sol",
            "effort": "xhigh",
            "collaboration_mode": ["mode": "default"],
            "approval_policy": "never",
            "sandbox_policy": ["type": "danger-full-access"],
        ],
    ]))
    // Keep the authoritative context well outside the former 1 MiB tail.
    transcript.append(try rolloutLine([
        "type": "event_msg",
        "payload": [
            "blob": String(
                repeating: "y",
                count: CodexRolloutMetadataStore.contextSearchChunkBytes * 2
            ),
        ],
    ]))
    try transcript.write(to: file)

    var store = CodexRolloutMetadataStore(sessionsRoot: layout.sessions)
    let original = rolloutSummary(id: threadID, createdAt: july24UTC)
    let bounded = try #require(store.enrich([original]).first)
    #expect(bounded.model == "gpt-5.6-sol")
    #expect(bounded.effort == "xhigh")
    #expect(bounded.agentMode == .auto)
    #expect(bounded.agentAccess == .fullAccess)
    #expect(
        store.totalBytesRead
            <= CodexRolloutMetadataStore.maximumSessionMetadataBytes
                + CodexRolloutMetadataStore.maximumContextSearchBytes
                + CodexRolloutMetadataStore.maximumContextRecordBytes * 2
    )

    let bytesRead = store.totalBytesRead
    let cached = try #require(store.enrich([original]).first)
    #expect(cached.model == "gpt-5.6-sol")
    #expect(store.totalBytesRead == bytesRead)

    transcript.append(try rolloutLine([
        "type": "turn_context",
        "payload": [
            "model": "gpt-5.6-terra",
            "effort": "ultra",
            "collaboration_mode": ["mode": "plan"],
            "approval_policy": "on-request",
            "sandbox_policy": ["type": "workspace-write"],
        ],
    ]))
    try transcript.write(to: file, options: [.atomic])

    let refreshed = try #require(store.enrich([original]).first)
    #expect(refreshed.model == "gpt-5.6-terra")
    #expect(refreshed.effort == "ultra")
    #expect(refreshed.agentMode == .plan)
    #expect(refreshed.agentAccess == .acceptEdits)
}

@Test func codexRolloutMetadataDoesNotSkipAMalformedLatestContext() throws {
    let manager = FileManager.default
    let layout = try makeRolloutContainer(named: "flowx-codex-rollout-malformed-latest")
    defer { try? manager.removeItem(at: layout.container) }

    let threadID = "49999999-2222-4333-8444-555555555555"
    let file = layout.datedDirectory
        .appendingPathComponent("rollout-2026-07-23T12-00-00-\(threadID)")
        .appendingPathExtension("jsonl")
    var transcript = try rolloutLine([
        "type": "session_meta",
        "payload": ["id": threadID],
    ])
    transcript.append(try rolloutLine([
        "type": "turn_context",
        "payload": [
            "model": "must-not-use-older-context",
            "effort": "high",
            "collaboration_mode": ["mode": "plan"],
            "approval_policy": "never",
            "sandbox_policy": ["type": "danger-full-access"],
        ],
    ]))
    transcript.append(Data(#"{"type":"turn_context","payload":"#.utf8))
    transcript.append(0x0A)
    try transcript.write(to: file)

    var store = CodexRolloutMetadataStore(sessionsRoot: layout.sessions)
    let result = try #require(store.enrich([
        rolloutSummary(id: threadID, createdAt: july24UTC),
    ]).first)
    #expect(result.model == nil)
    #expect(result.effort == nil)
    #expect(result.agentMode == nil)
    #expect(result.agentAccess == nil)
}

@Test func codexRolloutMetadataDoesNotUseStaleHeadOutsideSearchCap() throws {
    let manager = FileManager.default
    let layout = try makeRolloutContainer(named: "flowx-codex-rollout-search-cap")
    defer { try? manager.removeItem(at: layout.container) }

    let threadID = "51111111-2222-4333-8444-555555555555"
    let file = layout.datedDirectory
        .appendingPathComponent("rollout-2026-07-23T12-00-00-\(threadID)")
        .appendingPathExtension("jsonl")
    var transcript = try rolloutLine([
        "type": "session_meta",
        "payload": ["id": threadID],
    ])
    transcript.append(try rolloutLine([
        "type": "turn_context",
        "payload": [
            "model": "must-not-import-stale-head",
            "effort": "low",
            "collaboration_mode": ["mode": "plan"],
            "approval_policy": "untrusted",
            "sandbox_policy": ["type": "workspace-write"],
        ],
    ]))
    try transcript.write(to: file)
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    try handle.truncate(
        atOffset: UInt64(
            transcript.count
                + CodexRolloutMetadataStore.maximumContextSearchBytes
                + CodexRolloutMetadataStore.contextSearchChunkBytes
        )
    )

    var store = CodexRolloutMetadataStore(sessionsRoot: layout.sessions)
    let result = try #require(store.enrich([
        rolloutSummary(id: threadID, createdAt: july24UTC),
    ]).first)
    #expect(result.model == nil)
    #expect(result.effort == nil)
    #expect(result.agentMode == nil)
    #expect(result.agentAccess == nil)
    #expect(
        store.totalBytesRead
            <= CodexRolloutMetadataStore.maximumSessionMetadataBytes
                + CodexRolloutMetadataStore.maximumContextSearchBytes
    )
}
