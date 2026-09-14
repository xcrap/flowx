import Foundation
import Testing
@testable import FXAgent
import FXCore

@Test func writerConflictShowsRecoveryInsteadOfTerminalDiagnostics() {
    let message = CodexProvider.initializationFailureMessageForTesting(
        summary: "thread example already has an active writer",
        executableURL: URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
        stderr: "\u{1B}[31mERROR thread-store conflict\u{1B}[0m",
        terminationStatus: nil, terminatedBySignal: false, isQuarantined: false
    )
    #expect(message == CodexThreadWriterConflict.message)
    #expect(!message.contains("Executable:"))
    #expect(!message.contains("\u{1B}"))
    #expect(!CodexThreadWriterConflict.matches("thread not found"))
    #expect(!CodexThreadWriterConflict.matches("database is locked"))
}

@Test @MainActor func unsentPromptSurvivesRefreshAndDoesNotOverwriteNewerDraft() throws {
    let state = ConversationState(agentID: UUID())
    let attachment = Attachment(data: Data([1, 2, 3]), mimeType: "image/png", filename: "test.png")
    let unsent = UnsentConversationPrompt(prompt: "commit and push", attachments: [attachment], sessionID: "task")
    let optimisticID = state.appendUserMessage(unsent.prompt, attachments: unsent.attachments)
    state.inputText = "a newer draft"
    state.recoverUnsentPrompt(unsent, messageID: optimisticID)
    #expect(state.messages.isEmpty)
    #expect(state.inputText == "a newer draft")
    state.replaceMessages([ConversationMessage(role: .assistant, content: [.text("Synced update")])])
    #expect(state.unsentPrompt == unsent)

    let restored = try JSONDecoder().decode(UnsentConversationPrompt.self, from: JSONEncoder().encode(unsent))
    let fresh = ConversationState(agentID: UUID())
    fresh.recoverUnsentPrompt(restored)
    #expect(fresh.inputText == "commit and push")
    #expect(fresh.pendingAttachments == [attachment])
}

/// Exercises the real JSON-RPC transport and ConversationService, without sending
/// user input to a model or touching the user's Codex database.
@Test @MainActor func codexResumeConflictPreservesRequestAndRetriesWithoutDuplicateTurn() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("flowx-writer-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let executable = folder.appendingPathComponent("codex-fixture")
    let script = #"""
    #!/usr/bin/env python3
    import json, pathlib, sys
    if "--version" in sys.argv:
        print("codex-test 1.0")
        sys.exit(0)
    root = pathlib.Path(__file__).parent
    def emit(value):
        print(json.dumps(value), flush=True)
    for line in sys.stdin:
        request = json.loads(line)
        with (root / "requests.jsonl").open("a") as log:
            log.write(json.dumps(request) + "\n")
        method = request.get("method")
        if method == "initialize":
            emit({"id": request["id"], "result": {}})
        elif method == "thread/resume":
            if not (root / "released").exists():
                print("\033[31mERROR thread-store conflict\033[0m", file=sys.stderr, flush=True)
                emit({"id": request["id"], "error": {"code": -32603, "message": "thread existing-task already has an active writer"}})
            else:
                emit({"id": request["id"], "result": {"thread": {"id": "existing-task"}}})
        elif method == "turn/start":
            emit({"id": request["id"], "result": {"turn": {"id": "accepted-turn"}}})
            emit({"method": "turn/completed", "params": {"threadId": "existing-task", "turn": {"id": "accepted-turn", "status": "completed"}}})
    """#
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let discovery = RuntimeDiscovery()
    await discovery.register(BinarySpec(id: "codex", displayName: "Fixture", searchPaths: [executable.path]))
    let provider = CodexProvider(discovery: discovery)
    let registry = ProviderRegistry()
    registry.register(provider)
    let service = ConversationService(registry: registry)
    let state = ConversationState(agentID: UUID())
    state.sessionID = "existing-task"
    let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
    let attachment = Attachment(data: png, mimeType: "image/png", filename: "test.png")

    await withCheckedContinuation { done in
        service.send(prompt: "commit and push", attachments: [attachment], to: state,
                     providerID: "codex", model: nil, workingDirectory: folder,
                     onComplete: { done.resume() })
        service.send(prompt: "queued follow-up", to: state, providerID: "codex", model: nil,
                     workingDirectory: folder)
    }
    #expect(state.error == CodexThreadWriterConflict.message)
    #expect(state.inputText == "commit and push")
    #expect(state.pendingAttachments == [attachment])
    #expect(state.messages.isEmpty)
    #expect(state.queuedPromptCount == 1)
    let blockedRequests = try String(contentsOf: folder.appendingPathComponent("requests.jsonl"), encoding: .utf8)
    #expect(!blockedRequests.contains("turn/start"))
    #expect(!blockedRequests.contains("thread/start"))
    #expect(!blockedRequests.contains("thread/fork"))
    service.clearPendingRequests(for: state.agentID)

    // A transcript refresh must not change which text and images Retry sends.
    state.replaceMessages([ConversationMessage(role: .user, content: [.text("older native message")])])
    let retry = try #require(state.unsentPrompt)
    try Data().write(to: folder.appendingPathComponent("released"))
    await withCheckedContinuation { done in
        service.send(prompt: retry.prompt, attachments: retry.attachments, to: state,
                     providerID: "codex", model: nil, workingDirectory: folder,
                     resumeSessionID: retry.sessionID, onComplete: { done.resume() })
    }
    #expect(state.error == nil)
    #expect(state.unsentPrompt == nil)
    #expect(state.sessionID == "existing-task")
    let requests = try String(contentsOf: folder.appendingPathComponent("requests.jsonl"), encoding: .utf8)
        .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    let turns = requests.filter { $0["method"] as? String == "turn/start" }
    #expect(turns.count == 1)
    let params = try #require(turns.first?["params"] as? [String: Any])
    #expect(params["threadId"] as? String == "existing-task")
    let input = try #require(params["input"] as? [[String: Any]])
    #expect(input.last?["text"] as? String == "commit and push")
    #expect(input.first?["type"] as? String == "localImage")
    await provider.releaseAllSessions()
}
