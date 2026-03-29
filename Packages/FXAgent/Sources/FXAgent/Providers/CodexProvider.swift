import Foundation
import FXCore

private actor CodexSessionStore {
    private var sessions: [String: CodexSession] = [:]

    func session(
        for threadID: String?,
        workingDirectory: URL?,
        systemPrompt: String?,
        agentMode: AgentMode?,
        agentAccess: AgentAccess?,
        discovery: RuntimeDiscovery
    ) -> CodexSession {
        if let threadID, let existing = sessions[threadID] {
            return existing
        }

        let session = CodexSession(
            resumeThreadID: threadID,
            workingDirectory: workingDirectory,
            systemPrompt: systemPrompt,
            agentMode: agentMode,
            agentAccess: agentAccess,
            discovery: discovery
        )

        if let threadID {
            sessions[threadID] = session
        }

        return session
    }

    func register(_ session: CodexSession, for threadID: String) {
        sessions[threadID] = session
    }
}

private actor CodexSession {
    private enum ApprovalResponseID: Sendable {
        case int(Int)
        case string(String)
    }

    private let initialResumeThreadID: String?
    private var workingDirectory: URL?
    private var developerInstructions: String?
    private let discovery: RuntimeDiscovery
    private let approvalPolicy: String
    private let sandboxMode: String

    private var process: Process?
    private var writer: FileHandle?
    private var stderrPipe: Pipe?
    private var threadID: String?
    private var threadReady = false
    private var nextID: Int = 10
    private var lineBuffer = ""
    private var startupError: String?

    private var activeContinuation: AsyncThrowingStream<StreamEvent, Error>.Continuation?
    private var activeTurnID: String?
    private var pendingInterrupt = false
    private var lastTurnStartRequestID: Int?
    private var didEmitTurnStarted = false
    private var pendingApprovalResponseIDs: [UUID: ApprovalResponseID] = [:]
    private var activeAttachmentPaths: [URL] = []

    init(
        resumeThreadID: String?,
        workingDirectory: URL?,
        systemPrompt: String?,
        agentMode: AgentMode?,
        agentAccess: AgentAccess?,
        discovery: RuntimeDiscovery
    ) {
        initialResumeThreadID = resumeThreadID
        threadID = resumeThreadID
        self.workingDirectory = workingDirectory
        self.discovery = discovery

        let params = CodexProvider.codexParams(for: agentAccess ?? .fullAccess)
        approvalPolicy = params.approvalPolicy
        sandboxMode = params.sandbox

        var instructions = systemPrompt
        if (agentMode ?? .auto) == .plan {
            let planPrefix = "Before executing any actions, first create a detailed plan and present it for review. Do not execute commands or make changes until the plan is approved."
            if let existing = instructions, !existing.isEmpty {
                instructions = planPrefix + "\n\n" + existing
            } else {
                instructions = planPrefix
            }
        }
        developerInstructions = instructions
    }

    func startTurn(
        prompt: String,
        attachments: [Attachment] = [],
        model: String,
        effort: String?,
        workingDirectory: URL?,
        systemPrompt: String?,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws -> String {
        if let workingDirectory {
            self.workingDirectory = workingDirectory
        }
        if let systemPrompt, !systemPrompt.isEmpty {
            developerInstructions = systemPrompt
        }

        try await ensureServerStarted()
        let resolvedThreadID = try await ensureThreadReady()

        activeContinuation = continuation
        activeTurnID = nil
        pendingInterrupt = false
        didEmitTurnStarted = false
        continuation.yield(.initialized(sessionID: resolvedThreadID, model: model))

        let requestID = nextRequestID()
        lastTurnStartRequestID = requestID

        clearActiveAttachments()
        let attachmentPaths = Self.writeAttachmentsToTemp(attachments)
        activeAttachmentPaths = attachmentPaths

        var input: [[String: Any]] = []
        for path in attachmentPaths {
            input.append([
                "type": "localImage",
                "path": path.path,
            ])
        }
        input.append(["type": "text", "text": prompt])

        var params: [String: Any] = [
            "threadId": resolvedThreadID,
            "input": input,
            "model": model,
        ]

        if let effort = Self.normalizedEffort(effort) {
            params["effort"] = effort
        }

        if let workingDirectory = self.workingDirectory?.path, !workingDirectory.isEmpty {
            params["cwd"] = workingDirectory
        }

        writeJSON("turn/start", id: requestID, params: params)
        return resolvedThreadID
    }

    func interruptCurrentTurn() {
        guard activeContinuation != nil else { return }

        if let threadID, let activeTurnID {
            writeJSON("turn/interrupt", id: nextRequestID(), params: [
                "threadId": threadID,
                "turnId": activeTurnID,
            ])
        } else {
            pendingInterrupt = true
        }
    }

    private func ensureServerStarted() async throws {
        if process?.isRunning == true, writer != nil {
            return
        }

        guard let codexURL = await discovery.resolvedPath(for: "codex") else {
            let hint = await discovery.spec(for: "codex")?.installHint ?? "npm install -g @openai/codex"
            throw NSError(domain: "CodexProvider", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Codex CLI not found. Install with: \(hint)",
            ])
        }

        startServer(executableURL: codexURL)

        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            if process?.isRunning == true, writer != nil {
                return
            }
        }

        throw NSError(domain: "CodexProvider", code: 1, userInfo: [
            NSLocalizedDescriptionKey: startupError ?? "Codex app-server failed to start.",
        ])
    }

    private func ensureThreadReady() async throws -> String {
        if threadReady, let threadID {
            return threadID
        }

        for _ in 0..<200 {
            try await Task.sleep(for: .milliseconds(50))
            if threadReady, let threadID {
                return threadID
            }
            if let startupError {
                throw NSError(domain: "CodexProvider", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: startupError,
                ])
            }
        }

        throw NSError(domain: "CodexProvider", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Codex thread was not ready in time.",
        ])
    }

    private func nextRequestID() -> Int {
        nextID += 1
        return nextID
    }

    private func startServer(executableURL: URL) {
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = ["app-server"]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(NSHomeDirectory())/.local/bin",
            environment["PATH"] ?? "",
        ]
        .joined(separator: ":")
        process.environment = environment

        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        lineBuffer = ""
        startupError = nil
        threadReady = false
        writer = stdinPipe.fileHandleForWriting
        self.stderrPipe = stderrPipe
        self.process = process

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak process] handle in
            let data = handle.availableData
            Task {
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    await self.handleEOF()
                    return
                }

                guard process?.isRunning == true,
                      let fragment = String(data: data, encoding: .utf8) else { return }
                await self.consume(fragment: fragment)
            }
        }

        do {
            try process.run()
        } catch {
            startupError = "Failed to start codex app-server: \(error.localizedDescription)"
            self.process = nil
            writer = nil
            self.stderrPipe = nil
            return
        }

        writeJSON("initialize", id: 0, params: [
            "clientInfo": ["name": "FlowX", "version": "1.0"]
        ])
    }

    private static let maxLineBufferSize = 1_048_576

    private static func normalizedEffort(_ effort: String?) -> String? {
        guard let effort else { return nil }

        switch effort.lowercased() {
        case "none", "minimal", "low", "medium", "high", "xhigh":
            return effort.lowercased()
        case "max":
            return "xhigh"
        default:
            return "high"
        }
    }

    private func consume(fragment: String) {
        lineBuffer += fragment
        if lineBuffer.count > Self.maxLineBufferSize {
            lineBuffer = String(lineBuffer.suffix(Self.maxLineBufferSize))
        }

        while let newlineRange = lineBuffer.range(of: "\n") {
            let line = String(lineBuffer[..<newlineRange.lowerBound])
            lineBuffer.removeSubrange(lineBuffer.startIndex...newlineRange.lowerBound)
            if !line.isEmpty {
                processLine(line)
            }
        }
    }

    private func handleEOF() {
        if !lineBuffer.isEmpty {
            processLine(lineBuffer)
            lineBuffer = ""
        }

        let stderrText = stderrPipe
            .flatMap { String(data: $0.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let activeContinuation {
            if let stderrText, !stderrText.isEmpty {
                activeContinuation.yield(.error("Codex app-server exited: \(stderrText)"))
            }
            activeContinuation.finish()
        }

        activeContinuation = nil
        activeTurnID = nil
        lastTurnStartRequestID = nil
        didEmitTurnStarted = false
        pendingApprovalResponseIDs.removeAll()
        clearActiveAttachments()
        threadReady = false
        writer = nil
        stderrPipe = nil
        process = nil
    }

    private func processLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let method = json["method"] as? String {
            if let responseID = Self.approvalResponseID(from: json["id"]),
               method.contains("Approval") || method.contains("requestApproval") || method == "item/tool/call" {
                guard activeContinuation != nil else {
                    respondToApproval(responseID, approved: true)
                    return
                }
                if let approvalRequest = makeApprovalRequest(method: method, params: json["params"] as? [String: Any] ?? [:], responseID: responseID) {
                    activeContinuation?.yield(.approvalRequest(approvalRequest))
                } else {
                    respondToApproval(responseID, approved: true)
                }
                return
            }

            let params = json["params"] as? [String: Any] ?? [:]
            handleNotification(method: method, params: params)
            return
        }

        if let responseID = json["id"] as? Int {
            handleResponse(id: responseID, payload: json)
        }
    }

    private func handleResponse(id: Int, payload: [String: Any]) {
        if let error = payload["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Unknown Codex error"
            if id == 1 {
                startupError = message
            } else {
                activeContinuation?.yield(.error(message))
                if id == lastTurnStartRequestID {
                    activeContinuation?.finish()
                    activeContinuation = nil
                    activeTurnID = nil
                    pendingInterrupt = false
                    lastTurnStartRequestID = nil
                    clearActiveAttachments()
                }
            }
            return
        }

        if id == 0 {
            startOrResumeThread()
            return
        }

        if id == 1,
           let result = payload["result"] as? [String: Any],
           let thread = result["thread"] as? [String: Any],
           let resolvedThreadID = thread["id"] as? String {
            threadID = resolvedThreadID
            startupError = nil
            threadReady = true
            return
        }

        if id == lastTurnStartRequestID,
           let result = payload["result"] as? [String: Any],
           let turn = result["turn"] as? [String: Any],
           let turnID = turn["id"] as? String {
            activeTurnID = turnID
            emitTurnStartedIfNeeded(turnID: turnID)
            if pendingInterrupt {
                interruptCurrentTurn()
            }
        }
    }

    private func handleNotification(method: String, params: [String: Any]) {
        switch method {
        case "turn/started":
            if let turn = params["turn"] as? [String: Any],
               let turnID = turn["id"] as? String {
                activeTurnID = turnID
                emitTurnStartedIfNeeded(turnID: turnID)
                if pendingInterrupt {
                    interruptCurrentTurn()
                }
            }

        case "item/agentMessage/delta":
            if let delta = params["delta"] as? String {
                activeContinuation?.yield(.textDelta(delta))
            }

        case "item/started":
            if let item = params["item"] as? [String: Any] {
                let type = item["type"] as? String ?? ""
                if type == "toolCall" || type == "commandExecution" {
                    let name = item["name"] as? String ?? item["command"] as? String ?? type
                    activeContinuation?.yield(.toolUse(id: item["id"] as? String ?? "", name: name, input: ""))
                }
            }

        case "thread/tokenUsage/updated":
            if let usage = params["tokenUsage"] as? [String: Any] {
                let contextWindow = usage["modelContextWindow"] as? Int

                if let last = usage["last"] as? [String: Any] {
                    activeContinuation?.yield(.contextUsage(
                        inputTokens: last["inputTokens"] as? Int ?? 0,
                        outputTokens: last["outputTokens"] as? Int ?? 0,
                        cachedInputTokens: last["cachedInputTokens"] as? Int ?? 0,
                        reasoningOutputTokens: last["reasoningOutputTokens"] as? Int ?? 0,
                        totalTokens: last["totalTokens"] as? Int ?? 0,
                        contextWindow: contextWindow
                    ))
                }

                if let total = usage["total"] as? [String: Any] {
                    activeContinuation?.yield(.usageTotal(
                        inputTokens: total["inputTokens"] as? Int ?? 0,
                        outputTokens: total["outputTokens"] as? Int ?? 0,
                        cachedInputTokens: total["cachedInputTokens"] as? Int ?? 0,
                        reasoningOutputTokens: total["reasoningOutputTokens"] as? Int ?? 0,
                        totalTokens: total["totalTokens"] as? Int ?? 0,
                        contextWindow: contextWindow
                    ))
                }
            }

        case "thread/compacted":
            activeContinuation?.yield(.lifecycle(.phaseChanged(.compacted)))

        case "thread/status/changed":
            let compactStatus = compactStatus(from: params)
            if compactStatus == "compacting" {
                activeContinuation?.yield(.lifecycle(.phaseChanged(.compacting)))
            } else if compactStatus == "compacted" {
                activeContinuation?.yield(.lifecycle(.phaseChanged(.compacted)))
            }

            if let status = params["status"] as? [String: Any],
               status["type"] as? String == "systemError" {
                activeContinuation?.yield(.error("Codex thread entered a system error state."))
            }

        case "turn/completed":
            if let turn = params["turn"] as? [String: Any],
               let status = turn["status"] as? String,
               status == "failed",
               let error = turn["error"] as? [String: Any],
               let message = error["message"] as? String {
                activeContinuation?.yield(.error(message))
            }

            let stopReason: String
            if let turn = params["turn"] as? [String: Any],
               let status = turn["status"] as? String {
                stopReason = status
            } else {
                stopReason = "end_turn"
            }

            activeContinuation?.yield(.done(stopReason: stopReason))
            activeContinuation?.finish()
            activeContinuation = nil
            activeTurnID = nil
            pendingInterrupt = false
            lastTurnStartRequestID = nil
            didEmitTurnStarted = false
            pendingApprovalResponseIDs.removeAll()
            clearActiveAttachments()

        default:
            break
        }
    }

    private func emitTurnStartedIfNeeded(turnID: String?) {
        guard !didEmitTurnStarted else { return }
        didEmitTurnStarted = true
        activeContinuation?.yield(.lifecycle(.turnStarted(turnID: turnID)))
    }

    private func compactStatus(from params: [String: Any]) -> String? {
        if let status = params["status"] as? String {
            return normalizeCompactStatus(status)
        }

        if let status = params["status"] as? [String: Any] {
            for key in ["type", "state", "status"] {
                if let value = status[key] as? String,
                   let normalized = normalizeCompactStatus(value) {
                    return normalized
                }
            }
        }

        if let thread = params["thread"] as? [String: Any] {
            for key in ["state", "status"] {
                if let value = thread[key] as? String,
                   let normalized = normalizeCompactStatus(value) {
                    return normalized
                }
            }
        }

        for key in ["state", "type"] {
            if let value = params[key] as? String,
               let normalized = normalizeCompactStatus(value) {
                return normalized
            }
        }

        return nil
    }

    private func normalizeCompactStatus(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("compacting") {
            return "compacting"
        }
        if normalized.contains("compacted") || normalized == "compact_boundary" {
            return "compacted"
        }
        return nil
    }

    private func startOrResumeThread() {
        let threadToResume = threadID ?? initialResumeThreadID

        if let threadToResume {
            var params: [String: Any] = [
                "threadId": threadToResume,
                "approvalPolicy": approvalPolicy,
                "sandbox": sandboxMode,
            ]

            if let developerInstructions, !developerInstructions.isEmpty {
                params["developerInstructions"] = developerInstructions
            }

            if let workingDirectory = workingDirectory?.path, !workingDirectory.isEmpty {
                params["cwd"] = workingDirectory
            }

            writeJSON("thread/resume", id: 1, params: params)
            return
        }

        var params: [String: Any] = [
            "approvalPolicy": approvalPolicy,
            "sandbox": sandboxMode,
        ]

        if let developerInstructions, !developerInstructions.isEmpty {
            params["developerInstructions"] = developerInstructions
        }

        if let workingDirectory = workingDirectory?.path, !workingDirectory.isEmpty {
            params["cwd"] = workingDirectory
        }

        writeJSON("thread/start", id: 1, params: params)
    }

    func respondToApproval(_ approvalID: UUID, approved: Bool) {
        guard let responseID = pendingApprovalResponseIDs.removeValue(forKey: approvalID) else { return }
        respondToApproval(responseID, approved: approved)
    }

    private func respondToApproval(_ requestID: ApprovalResponseID, approved: Bool) {
        guard let writer else { return }

        let responseID: Any
        switch requestID {
        case .int(let value):
            responseID = value
        case .string(let value):
            responseID = value
        }

        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": responseID,
            "result": ["approved": approved],
        ]

        if let data = try? JSONSerialization.data(withJSONObject: response),
           let string = String(data: data, encoding: .utf8) {
            writer.write(Data((string + "\n").utf8))
        }
    }

    private func makeApprovalRequest(
        method: String,
        params: [String: Any],
        responseID: ApprovalResponseID
    ) -> ProviderApprovalRequest? {
        let item = (params["item"] as? [String: Any])
            ?? (params["toolCall"] as? [String: Any])
            ?? (params["call"] as? [String: Any])
            ?? params

        let toolName = Self.firstNonEmptyString(
            from: item,
            keys: ["name", "toolName", "command", "title", "type"]
        ) ?? Self.firstNonEmptyString(
            from: params,
            keys: ["name", "toolName", "command", "title", "type"]
        ) ?? "Tool call"

        let description = Self.firstNonEmptyString(
            from: params,
            keys: ["message", "reason", "description", "title"]
        ) ?? Self.firstNonEmptyString(
            from: item,
            keys: ["description", "reason", "summary"]
        ) ?? Self.defaultApprovalDescription(for: toolName, item: item)

        let parameters = Self.approvalParameters(from: params, item: item)
        let approvalID = UUID()
        pendingApprovalResponseIDs[approvalID] = responseID

        return ProviderApprovalRequest(
            id: approvalID,
            toolName: toolName,
            description: description,
            parameters: parameters,
            riskLevel: Self.riskLevel(for: toolName, parameters: parameters)
        )
    }

    private static func approvalResponseID(from rawValue: Any?) -> ApprovalResponseID? {
        switch rawValue {
        case let value as Int:
            .int(value)
        case let value as String:
            .string(value)
        default:
            nil
        }
    }

    private static func firstNonEmptyString(from payload: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = payload[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    private static func defaultApprovalDescription(for toolName: String, item: [String: Any]) -> String {
        if firstNonEmptyString(from: item, keys: ["command"]) != nil {
            return "Codex wants to run a command in your workspace."
        }

        if toolName.lowercased().contains("command") || toolName.lowercased().contains("shell") {
            return "Codex wants to execute a command that requires your approval."
        }

        return "Codex needs approval before continuing this tool action."
    }

    private static func approvalParameters(from params: [String: Any], item: [String: Any]) -> [String: String] {
        var details: [String: String] = [:]

        for (key, value) in [
            ("command", item["command"] ?? params["command"]),
            ("cwd", item["cwd"] ?? params["cwd"]),
            ("tool", item["name"] ?? params["name"]),
            ("reason", params["reason"] ?? item["reason"]),
            ("path", item["path"] ?? params["path"]),
            ("prompt", item["prompt"] ?? params["prompt"]),
            ("sandbox", params["sandbox"]),
        ] {
            if let stringValue = stringValue(for: value) {
                details[key] = stringValue
            }
        }

        if let input = item["input"] ?? item["arguments"] ?? params["input"] ?? params["arguments"],
           let stringValue = stringValue(for: input) {
            details["input"] = stringValue
        }

        if details.isEmpty, let raw = stringValue(for: params) {
            details["details"] = raw
        }

        return details
    }

    private static func stringValue(for rawValue: Any?) -> String? {
        guard let rawValue else { return nil }

        if let value = rawValue as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        if JSONSerialization.isValidJSONObject(rawValue),
           let data = try? JSONSerialization.data(withJSONObject: rawValue, options: [.sortedKeys]),
           let value = String(data: data, encoding: .utf8) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        return String(describing: rawValue)
    }

    private static func riskLevel(for toolName: String, parameters: [String: String]) -> ToolRiskLevel {
        let tool = toolName.lowercased()
        let detail = parameters.values.joined(separator: " ").lowercased()

        let dangerousHints = [
            "rm ",
            "rm -",
            "git push",
            "git reset",
            "git clean",
            "sudo ",
            "chmod ",
            "chown ",
            "mv ",
            "cp ",
            "kill ",
            "pkill",
            "curl ",
            "wget ",
            "scp ",
            "ssh ",
            "kubectl delete",
            "terraform apply",
            "npm publish",
            "cargo publish",
        ]

        if dangerousHints.contains(where: { detail.contains($0) || tool.contains($0.trimmingCharacters(in: .whitespaces)) }) {
            return .dangerous
        }

        let moderateHints = ["command", "shell", "bash", "write", "edit", "patch", "exec"]
        if moderateHints.contains(where: { tool.contains($0) || detail.contains($0) }) {
            return .moderate
        }

        return .safe
    }

    private func writeJSON(_ method: String, id: Int, params: [String: Any]) {
        guard let writer else { return }

        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ]

        if let data = try? JSONSerialization.data(withJSONObject: message),
           let string = String(data: data, encoding: .utf8) {
            writer.write(Data((string + "\n").utf8))
        }
    }

    private static func writeAttachmentsToTemp(_ attachments: [Attachment]) -> [URL] {
        let manager = FileManager.default
        let tempDir = manager.temporaryDirectory.appendingPathComponent("flowx-attachments", isDirectory: true)
        try? manager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        var paths: [URL] = []
        for attachment in attachments where attachment.isImage {
            let ext = attachment.mimeType.components(separatedBy: "/").last ?? "png"
            let filename = "\(attachment.id.uuidString).\(ext)"
            let url = tempDir.appendingPathComponent(filename)
            if manager.createFile(atPath: url.path, contents: attachment.data) {
                paths.append(url)
            }
        }
        return paths
    }

    private static func cleanupAttachments(at paths: [URL]) {
        guard !paths.isEmpty else { return }
        let manager = FileManager.default
        for path in paths {
            try? manager.removeItem(at: path)
        }
    }

    private func clearActiveAttachments() {
        Self.cleanupAttachments(at: activeAttachmentPaths)
        activeAttachmentPaths.removeAll()
    }
}

private actor CodexSessionReference {
    private var session: CodexSession?

    func set(_ session: CodexSession) {
        self.session = session
    }

    func get() -> CodexSession? {
        session
    }
}

public final class CodexProvider: AIProvider, Sendable {
    public let id = "codex"
    public let displayName = "Codex (OpenAI)"
    public let availableModels: [AIModel] = [
        AIModel(id: "gpt-5.4", name: "GPT-5.4", contextWindow: 200_000),
    ]

    private let store = CodexSessionStore()
    private let discovery: RuntimeDiscovery

    public init(discovery: RuntimeDiscovery) {
        self.discovery = discovery
    }

    static func codexParams(for access: AgentAccess) -> (approvalPolicy: String, sandbox: String) {
        switch access {
        case .supervised:
            ("untrusted", "workspace-write")
        case .acceptEdits:
            ("on-request", "workspace-write")
        case .fullAccess:
            ("never", "danger-full-access")
        }
    }

    public func sendMessage(
        prompt: String,
        attachments: [Attachment],
        messages: [ConversationMessage],
        model: String,
        effort: String?,
        systemPrompt: String?,
        agentMode: AgentMode?,
        agentAccess: AgentAccess?,
        workingDirectory: URL?,
        resumeSessionID: String?
    ) -> ProviderStreamHandle {
        let reference = CodexSessionReference()

        let stream = AsyncThrowingStream<StreamEvent, Error> { continuation in
            let task = Task {
                do {
                    let session = await store.session(
                        for: resumeSessionID,
                        workingDirectory: workingDirectory,
                        systemPrompt: systemPrompt,
                        agentMode: agentMode,
                        agentAccess: agentAccess,
                        discovery: discovery
                    )
                    await reference.set(session)
                    let threadID = try await session.startTurn(
                        prompt: prompt,
                        attachments: attachments,
                        model: model,
                        effort: effort,
                        workingDirectory: workingDirectory,
                        systemPrompt: systemPrompt,
                        continuation: continuation
                    )
                    await store.register(session, for: threadID)
                } catch {
                    continuation.yield(.error(error.localizedDescription))
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
                Task {
                    await reference.get()?.interruptCurrentTurn()
                }
            }
        }

        return ProviderStreamHandle(
            stream: stream,
            cancel: {
                await reference.get()?.interruptCurrentTurn()
            },
            respondToApproval: { approvalID, approved in
                await reference.get()?.respondToApproval(approvalID, approved: approved)
            }
        )
    }
}
