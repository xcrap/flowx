import Foundation
import os
import FXCore

final class ClaudeProducerTaskReference: @unchecked Sendable {
    private struct State {
        var task: Task<Void, Never>?
        var cancellationRequested = false
    }

    private let storage = OSAllocatedUnfairLock(initialState: State())

    func set(_ task: Task<Void, Never>) {
        let shouldCancel = storage.withLock { state -> Bool in
            state.task = task
            return state.cancellationRequested
        }
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        let task = storage.withLock { state -> Task<Void, Never>? in
            state.cancellationRequested = true
            return state.task
        }
        task?.cancel()
    }
}

private final class ClaudeProcessReference: @unchecked Sendable {
    private struct State {
        var process: Process?
        var cancellationRequested = false
    }

    private let storage = OSAllocatedUnfairLock(initialState: State())

    func set(_ process: Process?) {
        let shouldStop = storage.withLock { state -> Bool in
            state.process = process
            return state.cancellationRequested && process != nil
        }
        if shouldStop, let process {
            Self.stop(process)
        }
    }

    func stop() {
        let process = storage.withLock { state -> Process? in
            state.cancellationRequested = true
            return state.process
        }
        guard let process else { return }
        Self.stop(process)
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.interrupt()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            if process.isRunning { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.75) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
}

private final class ClaudeOutputState: @unchecked Sendable {
    private struct State {
        var lineBuffer = ProviderJSONLineBuffer(maximumBytes: 32 * 1_024 * 1_024)
        var stderr = Data()
    }

    private let storage = OSAllocatedUnfairLock(initialState: State())
    private static let maximumStderrBytes = 256 * 1_024

    func appendOutput(_ data: Data) -> (lines: [String], overflow: Bool) {
        storage.withLock { $0.lineBuffer.append(data) }
    }

    func flushOutput() -> [String] {
        storage.withLock { value in
            value.lineBuffer.flush().map { [$0] } ?? []
        }
    }

    func appendStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        storage.withLock { value in
            value.stderr.append(data)
            if value.stderr.count > Self.maximumStderrBytes {
                value.stderr.removeFirst(value.stderr.count - Self.maximumStderrBytes)
            }
        }
    }

    var stderrText: String {
        storage.withLock { String(decoding: $0.stderr, as: UTF8.self) }
    }

}

final class ClaudeTurnController: @unchecked Sendable {
    private enum PendingControl: @unchecked Sendable {
        case approval(requestID: String, toolUseID: String)
        case userInput(
            requestID: String,
            toolUseID: String,
            originalQuestions: [[String: Any]],
            questionTextByID: [String: String]
        )
    }

    private struct State: @unchecked Sendable {
        var writer: FileHandle?
        var pending: [UUID: PendingControl] = [:]
    }

    private let storage = OSAllocatedUnfairLock(initialState: State())
    private let autoApproveTools: Bool

    init(autoApproveTools: Bool = false) {
        self.autoApproveTools = autoApproveTools
    }

    func setWriter(_ writer: FileHandle?) {
        storage.withLock { $0.writer = writer }
    }

    func sendInitialPrompt(_ prompt: String, imageFiles: [URL] = []) throws {
        try sendUserMessage(prompt, imageFiles: imageFiles)
    }

    func sendFollowUpPrompt(_ prompt: String, imageFiles: [URL] = []) throws {
        try sendUserMessage(prompt, imageFiles: imageFiles)
    }

    private func sendUserMessage(_ prompt: String, imageFiles: [URL]) throws {
        var content: [[String: Any]] = []
        if !prompt.isEmpty {
            content.append(["type": "text", "text": prompt])
        }
        for imageFile in imageFiles {
            content.append(try Self.imageContentBlock(for: imageFile))
        }

        let message: [String: Any] = [
            "type": "user",
            "session_id": "",
            "message": [
                "role": "user",
                "content": content,
            ],
            "parent_tool_use_id": NSNull(),
        ]
        try write(message)
    }

    private static func imageContentBlock(for url: URL) throws -> [String: Any] {
        let mediaType: String
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg":
            mediaType = "image/jpeg"
        case "png":
            mediaType = "image/png"
        case "webp":
            mediaType = "image/webp"
        case "gif":
            mediaType = "image/gif"
        default:
            throw NSError(
                domain: "ClaudeCodeProvider",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Claude cannot send the prepared image format '\(url.pathExtension)'."]
            )
        }

        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard !data.isEmpty, data.count <= ProviderAttachmentStore.maximumAttachmentBytes else {
            throw NSError(
                domain: "ClaudeCodeProvider",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Claude cannot send an empty or oversized prepared image."]
            )
        }
        return [
            "type": "image",
            "source": [
                "type": "base64",
                "media_type": mediaType,
                "data": data.base64EncodedString(),
            ],
        ]
    }

    func event(forControlEnvelope envelope: [String: Any]) -> StreamEvent? {
        guard let requestID = Self.nonEmpty(envelope["request_id"] as? String),
              let request = envelope["request"] as? [String: Any],
              request["subtype"] as? String == "can_use_tool",
              let toolName = Self.nonEmpty(request["tool_name"] as? String) else {
            return nil
        }
        let input = request["input"] as? [String: Any] ?? [:]
        let toolUseID = Self.nonEmpty(request["tool_use_id"] as? String) ?? UUID().uuidString

        if toolName == "AskUserQuestion",
           let originalQuestions = input["questions"] as? [[String: Any]] {
            let requestUUID = UUID()
            var questionTextByID: [String: String] = [:]
            let questions = originalQuestions.prefix(4).enumerated().compactMap { index, raw -> ProviderUserInputQuestion? in
                guard let question = Self.nonEmpty(raw["question"] as? String) else { return nil }
                let questionID = "question-\(index + 1)"
                questionTextByID[questionID] = question
                let options = (raw["options"] as? [[String: Any]] ?? []).prefix(10).compactMap { option -> ProviderUserInputOption? in
                    guard let label = Self.nonEmpty(option["label"] as? String) else { return nil }
                    return ProviderUserInputOption(
                        label: Self.bounded(label, maximum: 256),
                        description: Self.bounded(option["description"] as? String ?? "", maximum: 2_048)
                    )
                }
                return ProviderUserInputQuestion(
                    id: questionID,
                    header: Self.bounded(raw["header"] as? String ?? "Question", maximum: 256),
                    question: Self.bounded(question, maximum: 8_192),
                    options: options,
                    allowsOther: true,
                    allowsMultiple: raw["multiSelect"] as? Bool ?? false,
                    isSecret: false
                )
            }
            guard !questions.isEmpty else {
                respondDirectly(
                    requestID: requestID,
                    response: Self.permissionDecision(
                        approved: false,
                        toolUseID: toolUseID,
                        updatedInput: nil,
                        denialMessage: "FlowX could not decode Claude's question payload."
                    )
                )
                return .toolResult(
                    id: toolUseID,
                    content: "FlowX could not decode Claude's AskUserQuestion payload.",
                    isError: true
                )
            }
            let pending = PendingControl.userInput(
                requestID: requestID,
                toolUseID: toolUseID,
                originalQuestions: originalQuestions,
                questionTextByID: questionTextByID
            )
            storage.withLock { $0.pending[requestUUID] = pending }
            return .userInputRequest(ProviderUserInputRequest(id: requestUUID, questions: questions))
        }

        if autoApproveTools {
            respondDirectly(
                requestID: requestID,
                response: Self.permissionDecision(
                    approved: true,
                    toolUseID: toolUseID,
                    updatedInput: input,
                    denialMessage: ""
                )
            )
            return nil
        }

        let approvalID = UUID()
        storage.withLock {
            $0.pending[approvalID] = .approval(requestID: requestID, toolUseID: toolUseID)
        }
        let description = Self.nonEmpty(request["title"] as? String)
            ?? Self.nonEmpty(request["description"] as? String)
            ?? Self.nonEmpty(request["decision_reason"] as? String)
            ?? "Claude wants to use \(toolName)."
        return .approvalRequest(ProviderApprovalRequest(
            id: approvalID,
            toolName: toolName,
            description: Self.bounded(description, maximum: 8_192),
            parameters: Self.parameters(from: input),
            riskLevel: Self.riskLevel(toolName: toolName, input: input)
        ))
    }

    func respondToApproval(_ id: UUID, approved: Bool) {
        let pending = storage.withLock { $0.pending.removeValue(forKey: id) }
        guard case .approval(let requestID, let toolUseID) = pending else { return }
        respondDirectly(
            requestID: requestID,
            response: Self.permissionDecision(
                approved: approved,
                toolUseID: toolUseID,
                updatedInput: nil,
                denialMessage: "The user denied this tool request in FlowX."
            )
        )
    }

    func respondToUserInput(_ id: UUID, answers: ProviderUserInputAnswers) {
        let pending = storage.withLock { $0.pending.removeValue(forKey: id) }
        guard case .userInput(
            let requestID,
            let toolUseID,
            let originalQuestions,
            let questionTextByID
        ) = pending else { return }

        var claudeAnswers: [String: String] = [:]
        for (questionID, questionText) in questionTextByID {
            let answer = (answers[questionID] ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
            if !answer.isEmpty { claudeAnswers[questionText] = Self.bounded(answer, maximum: 65_536) }
        }
        let approved = !claudeAnswers.isEmpty
        let updatedInput: [String: Any]? = approved ? [
            "questions": originalQuestions,
            "answers": claudeAnswers,
        ] : nil
        respondDirectly(
            requestID: requestID,
            response: Self.permissionDecision(
                approved: approved,
                toolUseID: toolUseID,
                updatedInput: updatedInput,
                denialMessage: "The user cancelled Claude's question in FlowX."
            )
        )
    }

    func cancelPendingAndClose(message: String) {
        let pending: [PendingControl] = storage.withLock { state in
            let pending = Array(state.pending.values)
            state.pending.removeAll()
            return pending
        }
        for control in pending {
            let identifiers: (String, String) = switch control {
            case .approval(let requestID, let toolUseID): (requestID, toolUseID)
            case .userInput(let requestID, let toolUseID, _, _): (requestID, toolUseID)
            }
            respondDirectly(
                requestID: identifiers.0,
                response: Self.permissionDecision(
                    approved: false,
                    toolUseID: identifiers.1,
                    updatedInput: nil,
                    denialMessage: message
                )
            )
        }
        closeInput()
    }

    func closeInput() {
        let writer = storage.withLock { state -> FileHandle? in
            defer { state.writer = nil }
            return state.writer
        }
        try? writer?.close()
    }

    static func permissionDecision(
        approved: Bool,
        toolUseID: String,
        updatedInput: [String: Any]?,
        denialMessage: String
    ) -> [String: Any] {
        if approved {
            var decision: [String: Any] = [
                "behavior": "allow",
                "toolUseID": toolUseID,
                "decisionClassification": "user_temporary",
            ]
            if let updatedInput { decision["updatedInput"] = updatedInput }
            return decision
        }
        return [
            "behavior": "deny",
            "message": denialMessage,
            "toolUseID": toolUseID,
            "decisionClassification": "user_reject",
        ]
    }

    private func respondDirectly(requestID: String, response: [String: Any]) {
        try? write([
            "type": "control_response",
            "response": [
                "subtype": "success",
                "request_id": requestID,
                "response": response,
            ],
        ])
    }

    private func write(_ message: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(message) else {
            throw ProviderSteeringError.unavailable("Claude could not encode the guidance message.")
        }
        let data = try JSONSerialization.data(withJSONObject: message)
        try storage.withLock { state in
            guard let writer = state.writer else {
                throw ProviderSteeringError.unavailable(
                    "Claude's live input is closed, so this turn can no longer be steered."
                )
            }
            try writer.write(contentsOf: data + Data([0x0A]))
        }
    }

    private static func parameters(from input: [String: Any]) -> [String: String] {
        var parameters: [String: String] = [:]
        for (key, value) in input.prefix(20) {
            if let value = value as? String {
                parameters[key] = bounded(value, maximum: 4_096)
            } else if JSONSerialization.isValidJSONObject(value),
                      let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
                parameters[key] = bounded(String(decoding: data, as: UTF8.self), maximum: 4_096)
            }
        }
        return parameters
    }

    private static func riskLevel(toolName: String, input: [String: Any]) -> ToolRiskLevel {
        let tool = toolName.lowercased()
        let command = (input["command"] as? String ?? "").lowercased()
        if ["rm ", "sudo ", "git push", "git reset", "chmod ", "chown "]
            .contains(where: { command.contains($0) }) {
            return .dangerous
        }
        if ["bash", "write", "edit", "notebookedit"].contains(where: tool.contains) {
            return .moderate
        }
        return .safe
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private static func bounded(_ value: String, maximum: Int) -> String {
        guard value.utf8.count > maximum else { return value }
        var bytes = 0
        var end = value.startIndex
        while end < value.endIndex {
            let next = value.index(after: end)
            let characterBytes = value[end..<next].utf8.count
            guard bytes + characterBytes <= maximum else { break }
            bytes += characterBytes
            end = next
        }
        return String(value[..<end]) + "…"
    }
}

final class ClaudeStreamParser: @unchecked Sendable {
    private var sawTextDelta = false
    private var seenToolIDs: Set<String> = []
    private var didFinish = false
    private let controller: ClaudeTurnController

    init(controller: ClaudeTurnController = ClaudeTurnController()) {
        self.controller = controller
    }

    func events(for line: String) -> [StreamEvent] {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return []
        }

        switch type {
        case "control_request":
            return controller.event(forControlEnvelope: json).map { [$0] } ?? []

        case "system":
            let subtype = json["subtype"] as? String
            if subtype == nil || subtype == "init" {
                return [.initialized(
                    sessionID: json["session_id"] as? String ?? "",
                    model: json["model"] as? String
                )]
            }
            if subtype == "status", json["status"] as? String == "compacting" {
                return [.lifecycle(.phaseChanged(.compacting))]
            }
            if subtype == "compact_boundary" { return [.lifecycle(.phaseChanged(.compacted))] }
            return []

        case "stream_event":
            guard let event = json["event"] as? [String: Any],
                  event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else {
                return []
            }
            sawTextDelta = true
            return [.textDelta(text)]

        case "assistant":
            guard let message = json["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return [] }
            var events: [StreamEvent] = []
            for block in content {
                switch block["type"] as? String {
                case "text" where !sawTextDelta:
                    if let text = block["text"] as? String, !text.isEmpty { events.append(.text(text)) }
                case "tool_use":
                    let id = block["id"] as? String ?? UUID().uuidString
                    guard seenToolIDs.insert(id).inserted else { continue }
                    events.append(.toolUse(
                        id: id,
                        name: block["name"] as? String ?? "Tool",
                        input: Self.jsonString(block["input"]) ?? "{}"
                    ))
                default:
                    continue
                }
            }
            return events

        case "user":
            let message = json["message"] as? [String: Any]
            let content = message?["content"] as? [[String: Any]] ?? []
            return content.compactMap { block in
                guard block["type"] as? String == "tool_result" else { return nil }
                return .toolResult(
                    id: block["tool_use_id"] as? String ?? "",
                    content: Self.contentString(block["content"]),
                    isError: block["is_error"] as? Bool ?? false
                )
            }

        case "result":
            guard !didFinish else { return [] }
            didFinish = true
            controller.closeInput()
            if json["is_error"] as? Bool == true {
                return [.error(json["result"] as? String ?? "Claude Code returned an error.")]
            }
            var inputTokens = 0
            var outputTokens = 0
            if let usage = json["usage"] as? [String: Any] {
                inputTokens += Self.int(usage["input_tokens"])
                outputTokens += Self.int(usage["output_tokens"])
            }
            if let modelUsage = json["modelUsage"] as? [String: Any] {
                inputTokens = 0
                outputTokens = 0
                for value in modelUsage.values {
                    if let model = value as? [String: Any] {
                        inputTokens += Self.int(model["inputTokens"])
                        outputTokens += Self.int(model["outputTokens"])
                    }
                }
            }
            return [
                .usage(inputTokens: inputTokens, outputTokens: outputTokens, costUSD: json["total_cost_usd"] as? Double),
                .done(stopReason: json["subtype"] as? String ?? "end_turn"),
            ]

        default:
            return []
        }
    }

    private static func int(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return 0
    }

    private static func jsonString(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let value = value as? String { return value }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func contentString(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let blocks = value as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return jsonString(value) ?? ""
    }
}

public final class ClaudeCodeProvider: AIProvider, AIProviderNativeThreads, AIProviderNativeThreadTrashManaging, Sendable {
    public let id = "claude"
    public let displayName = "Claude Code"
    public var availableModels: [AIModel] { modelCatalog.models }
    public let capabilities = AIProviderCapabilities(
        supportedAttachments: [.image],
        supportsApprovals: true,
        supportsThreadControls: false,
        supportsModelDiscovery: true
    )

    private let discovery: RuntimeDiscovery
    private let modelCatalog = ProviderModelCatalog(ClaudeCodeProvider.fallbackModels)
    private let nativeStore = ClaudeNativeThreadStore()
    private let sessionLeases = ClaudeSessionLeaseRegistry()

    public init(discovery: RuntimeDiscovery) {
        self.discovery = discovery
    }

    @discardableResult
    public func refreshAvailableModels() async -> [AIModel] {
        guard let result = try? await discovery.run(binaryID: "claude", arguments: ["--help"], timeout: 10),
              result.terminationStatus == 0 else { return availableModels }
        let help = result.standardOutputString.lowercased()
        // Claude's help text documents a few aliases as examples; it is not a
        // complete model-list endpoint (Haiku is valid but is not named in the
        // current examples). Only use the probe to verify model selection is
        // supported, then retain the complete curated catalog.
        if help.contains("--model") { modelCatalog.replace(with: Self.fallbackModels) }
        return availableModels
    }

    public func sendMessage(
        prompt: String,
        attachments: [Attachment],
        messages: [ConversationMessage],
        model: String?,
        effort: String?,
        systemPrompt: String?,
        agentMode: AgentMode?,
        agentAccess: AgentAccess?,
        workingDirectory: URL?,
        resumeSessionID: String?
    ) -> ProviderStreamHandle {
        let processReference = ClaudeProcessReference()
        let producerTaskReference = ClaudeProducerTaskReference()
        // Claude's native bypass mode suppresses every permission callback,
        // including AskUserQuestion. Keep the stdio permission channel active
        // for Full Access and let the controller auto-allow ordinary tools so
        // user questions can still be surfaced in FlowX.
        let controller = ClaudeTurnController(
            autoApproveTools: agentAccess == .fullAccess && agentMode != .plan
        )
        let stream = AsyncThrowingStream<StreamEvent, Error> { continuation in
            let task = Task {
                do {
                    try await self.runClaude(
                        prompt: prompt,
                        attachments: attachments,
                        model: model,
                        effort: effort,
                        systemPrompt: systemPrompt,
                        agentMode: agentMode,
                        agentAccess: agentAccess,
                        workingDirectory: workingDirectory,
                        resumeSessionID: resumeSessionID,
                        processReference: processReference,
                        controller: controller,
                        continuation: continuation
                    )
                } catch {
                    if !Task.isCancelled {
                        continuation.yield(.error(error.localizedDescription))
                        continuation.finish(throwing: error)
                    }
                }
            }
            producerTaskReference.set(task)
            continuation.onTermination = { @Sendable _ in
                producerTaskReference.cancel()
                controller.cancelPendingAndClose(message: "The FlowX turn was cancelled.")
                processReference.stop()
            }
        }
        return ProviderStreamHandle(
            stream: stream,
            cancel: {
                producerTaskReference.cancel()
                controller.cancelPendingAndClose(message: "The FlowX turn was cancelled.")
                processReference.stop()
            },
            steer: { prompt, attachments in
                let prepared = try ProviderAttachmentStore.prepare(attachments)
                defer { prepared.remove() }
                try controller.sendFollowUpPrompt(prompt, imageFiles: prepared.files)
            },
            respondToApproval: { id, approved in
                controller.respondToApproval(id, approved: approved)
            },
            respondToUserInput: { id, answers in
                controller.respondToUserInput(id, answers: answers)
            }
        )
    }

    public func listNativeThreads(
        workingDirectory: URL,
        limit: Int = 100
    ) async throws -> [ProviderNativeThreadSummary] {
        try await nativeStore.list(workingDirectory: workingDirectory, limit: limit)
    }

    public func readNativeThread(
        id: String,
        workingDirectory: URL?
    ) async throws -> ProviderNativeThread {
        try await nativeStore.read(id: id, workingDirectory: workingDirectory)
    }

    public func moveNativeThreadToTrash(
        id: String,
        workingDirectory: URL
    ) async throws {
        try await nativeStore.moveToTrash(id: id, workingDirectory: workingDirectory)
    }

    static let fallbackModels: [AIModel] = [
        AIModel(id: "claude-fable-5", name: "Claude Fable 5", contextWindow: 200_000, maxContextWindow: 200_000, defaultReasoningEffort: "high", supportedReasoningEfforts: ["low", "medium", "high", "xhigh", "max"], isDefault: true),
        AIModel(id: "claude-opus-4-8", name: "Claude Opus 4.8", contextWindow: 200_000, maxContextWindow: 200_000, defaultReasoningEffort: "high", supportedReasoningEfforts: ["low", "medium", "high", "xhigh", "max"]),
        AIModel(id: "claude-sonnet-5", name: "Claude Sonnet 5", contextWindow: 200_000, maxContextWindow: 200_000, defaultReasoningEffort: "high", supportedReasoningEfforts: ["low", "medium", "high", "xhigh", "max"]),
        AIModel(id: "claude-haiku-4-5", name: "Claude Haiku 4.5", contextWindow: 200_000, maxContextWindow: 200_000),
    ]

    static func buildArguments(
        model: String?,
        effort: String?,
        systemPrompt: String?,
        agentMode: AgentMode?,
        agentAccess: AgentAccess?,
        resumeSessionID: String?,
        attachmentDirectory: URL?
    ) -> [String] {
        var arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--permission-prompt-tool", "stdio",
            "--verbose",
            "--include-partial-messages",
        ]
        if let model = nonEmpty(model) { arguments += ["--model", model] }
        if let effort = nonEmpty(effort)?.lowercased() { arguments += ["--effort", effort] }
        if let systemPrompt = nonEmpty(systemPrompt) {
            arguments += ["--append-system-prompt", systemPrompt]
        }
        if agentMode == .plan {
            arguments += ["--permission-mode", "plan"]
        } else if let agentAccess {
            switch agentAccess {
            case .supervised:
                arguments += ["--permission-mode", "manual"]
            case .acceptEdits:
                arguments += ["--permission-mode", "acceptEdits"]
            case .fullAccess:
                // Do not use --dangerously-skip-permissions here: Claude then
                // executes AskUserQuestion without emitting can_use_tool, so
                // FlowX cannot present the question. Manual mode keeps the
                // callback alive; ClaudeTurnController auto-approves every
                // non-question tool request for Full Access.
                arguments += ["--permission-mode", "manual"]
            }
        }
        if let resumeSessionID = nonEmpty(resumeSessionID) {
            arguments += ["--resume", resumeSessionID]
        }
        if let attachmentDirectory {
            arguments += ["--add-dir", attachmentDirectory.path]
        }
        return arguments
    }

    private func runClaude(
        prompt: String,
        attachments: [Attachment],
        model: String?,
        effort: String?,
        systemPrompt: String?,
        agentMode: AgentMode?,
        agentAccess: AgentAccess?,
        workingDirectory: URL?,
        resumeSessionID: String?,
        processReference: ClaudeProcessReference,
        controller: ClaudeTurnController,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        let resumedSessionID = Self.nonEmpty(resumeSessionID)
        if let resumedSessionID {
            try sessionLeases.acquire(resumedSessionID)
        }
        defer {
            if let resumedSessionID {
                sessionLeases.release(resumedSessionID)
            }
        }

        guard let executable = await discovery.resolvedPath(for: "claude") else {
            let hint = await discovery.spec(for: "claude")?.installHint ?? "npm install -g @anthropic-ai/claude-code"
            throw Self.error("Claude Code CLI not found. Install with: \(hint)")
        }
        if let resumedSessionID {
            try await ensureSessionIsNotActiveElsewhere(resumedSessionID)
        }
        let prepared = try ProviderAttachmentStore.prepare(attachments)
        defer { prepared.remove() }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let outputState = ClaudeOutputState()
        let parser = ClaudeStreamParser(controller: controller)

        process.executableURL = executable
        process.arguments = Self.buildArguments(
            model: model,
            effort: effort,
            systemPrompt: systemPrompt,
            agentMode: agentMode,
            agentAccess: agentAccess,
            resumeSessionID: resumeSessionID,
            attachmentDirectory: prepared.directory
        )
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = Self.runtimeEnvironment
        if let workingDirectory {
            let resolved = workingDirectory.standardizedFileURL
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw Self.error("The workspace path does not exist or is not a directory: \(resolved.path)")
            }
            process.currentDirectoryURL = resolved
        }

        let (outputStream, outputContinuation) = AsyncStream<Data>.makeStream()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                outputContinuation.finish()
            } else {
                outputContinuation.yield(data)
            }
        }
        outputContinuation.onTermination = { @Sendable _ in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { outputState.appendStderr(data) }
        }

        let readerTask = Task { () -> Bool in
            for await data in outputStream {
                let output = outputState.appendOutput(data)
                if output.overflow { return false }
                for line in output.lines {
                    for event in parser.events(for: line) { continuation.yield(event) }
                }
            }
            for line in outputState.flushOutput() {
                for event in parser.events(for: line) { continuation.yield(event) }
            }
            return true
        }

        let (terminationStream, terminationContinuation) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { completed in
            terminationContinuation.yield(completed.terminationStatus)
            terminationContinuation.finish()
        }

        try Task.checkCancellation()
        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            outputContinuation.finish()
            terminationContinuation.finish()
            _ = await readerTask.value
            throw error
        }

        processReference.set(process)
        controller.setWriter(stdinPipe.fileHandleForWriting)
        if Task.isCancelled {
            processReference.stop()
            controller.closeInput()
        } else {
            continuation.yield(.lifecycle(.turnStarted(turnID: nil)))
            try controller.sendInitialPrompt(prompt, imageFiles: prepared.files)
        }

        var terminationIterator = terminationStream.makeAsyncIterator()
        let terminationStatus = await terminationIterator.next() ?? -1

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        let stdoutTail = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        if !stdoutTail.isEmpty { outputContinuation.yield(stdoutTail) }
        outputContinuation.finish()
        let validStream = await readerTask.value

        stderrPipe.fileHandleForReading.readabilityHandler = nil
        outputState.appendStderr(stderrPipe.fileHandleForReading.readDataToEndOfFile())
        processReference.set(nil)
        controller.cancelPendingAndClose(message: "Claude Code ended before the request was answered.")

        guard validStream else {
            throw Self.error("Claude emitted a stream event larger than FlowX's 32 MB safety limit.")
        }
        guard terminationStatus == 0 || Task.isCancelled else {
            let detail = outputState.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Self.error(detail.isEmpty ? "Claude Code exited with status \(terminationStatus)." : detail)
        }
        if !Task.isCancelled { continuation.finish() }
    }

    /// Claude Code 2.1.145+ exposes live foreground/background sessions through
    /// this command. An exact full-session-ID match is authoritative. Older
    /// versions remain compatible: when neither the query nor command help can
    /// establish support, FlowX falls back to the cross-process lease alone.
    /// Once command help demonstrates `agents --json` support, query, timeout,
    /// truncation, and decode failures are closed rather than risking a second
    /// writer for the same provider transcript.
    private func ensureSessionIsNotActiveElsewhere(_ sessionID: String) async throws {
        let result: RuntimeCommandResult?
        do {
            result = try await discovery.run(
                binaryID: "claude",
                arguments: ["agents", "--json"],
                timeout: 3
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            result = nil
        }

        if let result,
           result.terminationStatus == 0,
           !result.timedOut,
           !result.outputWasTruncated,
           let containsSession = ClaudeSessionActivitySnapshot.contains(
               sessionID: sessionID,
               in: result.standardOutput
           ) {
            if containsSession {
                throw ClaudeSessionConcurrencyError.alreadyActiveInClaudeCode(sessionID: sessionID)
            }
            return
        }

        guard try await claudeSupportsAgentJSONStatus() else {
            // Compatibility fallback for Claude versions that predate the
            // optional `agents --json` API or installations where capability
            // support cannot be established.
            return
        }
        throw ClaudeSessionConcurrencyError.activityStatusUnavailable(sessionID: sessionID)
    }

    private func claudeSupportsAgentJSONStatus() async throws -> Bool {
        let installedVersion = await discovery.health(for: "claude").version
        if ClaudeSessionActivitySnapshot.versionSupportsJSONListing(installedVersion) {
            return true
        }

        let help: RuntimeCommandResult
        do {
            help = try await discovery.run(
                binaryID: "claude",
                arguments: ["agents", "--help"],
                timeout: 3
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return false
        }

        guard help.terminationStatus == 0,
              !help.timedOut,
              !help.outputWasTruncated else {
            return false
        }
        var output = help.standardOutput
        output.append(help.standardError)
        return ClaudeSessionActivitySnapshot.helpAdvertisesJSONListing(output)
    }

    private static var runtimeEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [
            "\(NSHomeDirectory())/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            environment["PATH"] ?? "/usr/bin:/bin",
        ].joined(separator: ":")
        return environment
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "ClaudeCodeProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
