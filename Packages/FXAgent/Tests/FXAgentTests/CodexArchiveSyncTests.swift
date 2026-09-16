import Foundation
import Testing
@testable import FXAgent
import FXCore

/// Two clients of one fixture store exercise the real transport without
/// archiving/restoring any of the user's tasks or starting a model turn.
@Test func codexArchiveAndRestoreStayProviderAuthoritativeAcrossClients() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("flowx-archive-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let executable = folder.appendingPathComponent("codex-fixture")
    let script = #"""
    #!/usr/bin/env python3
    import json, pathlib, sys
    if "--version" in sys.argv:
        print("codex-test 1.0")
        sys.exit(0)
    root = pathlib.Path(__file__).parent.resolve()
    archived = root / "archived"
    def emit(value):
        print(json.dumps(value), flush=True)
    def thread():
        return {"id": "native-task", "name": "Archive fixture", "cwd": str(root),
                "createdAt": 1784000000, "updatedAt": 1784000001, "source": "vscode",
                "model": "gpt-6-astra", "reasoningEffort": "high", "status": {"type": "idle"}}
    for line in sys.stdin:
        request = json.loads(line)
        with (root / "requests.jsonl").open("a") as log:
            log.write(json.dumps(request) + "\n")
        method = request.get("method")
        params = request.get("params", {})
        if "id" not in request:
            continue
        if method == "initialize":
            result = {}
        elif method == "thread/list":
            if (root / "fail-list").exists():
                emit({"id": request["id"], "error": {"code": -32603, "message": "Temporary list failure"}})
                continue
            assert isinstance(params["archived"], bool)
            result = {"data": [thread()] if params["archived"] == archived.exists() else [], "nextCursor": None}
        elif method == "thread/read":
            assert params["includeTurns"] is False
            result = {"thread": thread()}
        elif method == "thread/archive":
            assert params["threadId"] == "native-task"
            archived.touch()
            result = {}
        elif method == "thread/unarchive":
            assert params["threadId"] == "native-task"
            archived.unlink()
            result = {"thread": thread()}
        else:
            emit({"id": request["id"], "error": {"code": -32601, "message": "Unexpected method " + method}})
            continue
        emit({"id": request["id"], "result": result})
    """#
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let discovery = RuntimeDiscovery()
    await discovery.register(BinarySpec(id: "codex", displayName: "Fixture", searchPaths: [executable.path]))
    let flowx = CodexProvider(discovery: discovery)
    let otherClient = CodexProvider(discovery: discovery)

    let initial = try await flowx.listNativeThreads(workingDirectory: folder, limit: 250)
    #expect(initial.map(\.id) == ["native-task"])
    // Codex -> FlowX while the same reader connection remains open.
    try await otherClient.archiveNativeThread(id: "native-task", workingDirectory: folder)
    let activeAfterArchive = try await flowx.listNativeThreads(workingDirectory: folder, limit: 250)
    let archived = try await flowx.listArchivedNativeThreads(workingDirectory: folder)
    #expect(activeAfterArchive.isEmpty)
    #expect(archived.map(\.id) == ["native-task"])
    // FlowX -> Codex restore and archive, both observed by the other connection.
    try await flowx.unarchiveNativeThread(id: "native-task", workingDirectory: folder)
    let restored = try await otherClient.listNativeThreads(workingDirectory: folder, limit: 250)
    #expect(restored.map(\.id) == initial.map(\.id))
    try await flowx.archiveNativeThread(id: "native-task", workingDirectory: folder)
    let otherArchived = try await otherClient.listArchivedNativeThreads(workingDirectory: folder)
    #expect(otherArchived.map(\.id) == ["native-task"])
    try await otherClient.unarchiveNativeThread(id: "native-task", workingDirectory: folder)
    let finalActive = try await flowx.listNativeThreads(workingDirectory: folder, limit: 250)
    let finalArchived = try await flowx.listArchivedNativeThreads(workingDirectory: folder)
    #expect(finalActive.map(\.id) == initial.map(\.id))
    #expect(finalArchived.isEmpty)

    // Errors cannot masquerade as a successful empty list and erase the cache.
    try Data().write(to: folder.appendingPathComponent("fail-list"))
    do {
        _ = try await flowx.listArchivedNativeThreads(workingDirectory: folder)
        Issue.record("A failed list was accepted")
    } catch {
        #expect(error.localizedDescription.contains("Temporary list failure"))
    }
    let requests = try String(contentsOf: folder.appendingPathComponent("requests.jsonl"), encoding: .utf8)
    #expect(!requests.contains("thread/resume"))
    #expect(!requests.contains("turn/start"))
    await flowx.releaseAllSessions()
    await otherClient.releaseAllSessions()
}
