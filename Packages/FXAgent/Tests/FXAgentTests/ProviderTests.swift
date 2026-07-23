import Foundation
import Testing
@testable import FXAgent
@testable import FXCore

private struct ImmediateTestProvider: AIProvider {
    let id = "start-callback-test"
    let displayName = "Start Callback Test"
    let availableModels: [AIModel] = []

    func sendMessage(
        prompt: String,
        attachments: [FXCore.Attachment],
        messages: [ConversationMessage],
        model: String?,
        effort: String?,
        systemPrompt: String?,
        agentMode: AgentMode?,
        agentAccess: AgentAccess?,
        workingDirectory: URL?,
        resumeSessionID: String?
    ) -> ProviderStreamHandle {
        ProviderStreamHandle(
            stream: AsyncThrowingStream { continuation in
                continuation.yield(.initialized(sessionID: "session-ready-test", model: nil))
                continuation.yield(.done(stopReason: "complete"))
                continuation.finish()
            },
            cancel: {}
        )
    }
}

private final class BlockingContinuationStore: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation?

    func set(_ continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func finish() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.finish()
    }
}

private struct BlockingTestProvider: AIProvider {
    let id = "blocking-test"
    let displayName = "Blocking Test"
    let availableModels: [AIModel] = []
    let continuationStore: BlockingContinuationStore

    func sendMessage(
        prompt: String,
        attachments: [FXCore.Attachment],
        messages: [ConversationMessage],
        model: String?,
        effort: String?,
        systemPrompt: String?,
        agentMode: AgentMode?,
        agentAccess: AgentAccess?,
        workingDirectory: URL?,
        resumeSessionID: String?
    ) -> ProviderStreamHandle {
        ProviderStreamHandle(
            stream: AsyncThrowingStream { continuation in
                continuationStore.set(continuation)
                continuation.yield(.initialized(sessionID: "blocking-session", model: nil))
            },
            cancel: {
                continuationStore.finish()
            }
        )
    }
}

private actor SteeringInvocationStore {
    let acceptsGuidance: Bool
    private(set) var prompts: [String] = []

    init(acceptsGuidance: Bool) {
        self.acceptsGuidance = acceptsGuidance
    }

    func steer(prompt: String) throws {
        prompts.append(prompt)
        guard acceptsGuidance else {
            throw ProviderSteeringError.unavailable("The test turn is not steerable.")
        }
    }
}

private struct SteeringTestProvider: AIProvider {
    let id: String
    let displayName = "Steering Test"
    let availableModels: [AIModel] = []
    let continuationStore: BlockingContinuationStore
    let steeringStore: SteeringInvocationStore

    func sendMessage(
        prompt: String,
        attachments: [FXCore.Attachment],
        messages: [ConversationMessage],
        model: String?,
        effort: String?,
        systemPrompt: String?,
        agentMode: AgentMode?,
        agentAccess: AgentAccess?,
        workingDirectory: URL?,
        resumeSessionID: String?
    ) -> ProviderStreamHandle {
        ProviderStreamHandle(
            stream: AsyncThrowingStream { continuation in
                continuationStore.set(continuation)
                continuation.yield(.initialized(sessionID: "steering-session", model: nil))
                continuation.yield(.lifecycle(.turnStarted(turnID: "turn-1")))
            },
            cancel: {
                continuationStore.finish()
            },
            steer: { prompt, _ in
                try await steeringStore.steer(prompt: prompt)
            }
        )
    }
}

private actor CancellationFlag {
    private(set) var wasCancelled = false

    func markCancelled() {
        wasCancelled = true
    }
}

private actor CleanupInvocationCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

@Test func claudeProducerCancellationBeforeTaskRegistrationStillCancelsTask() async {
    let reference = ClaudeProducerTaskReference()
    let flag = CancellationFlag()
    reference.cancel()
    let task = Task {
        do {
            try await Task.sleep(for: .seconds(30))
        } catch is CancellationError {
            await flag.markCancelled()
        } catch {}
    }
    reference.set(task)
    await task.value

    let wasCancelled = await flag.wasCancelled
    #expect(wasCancelled)
}

@Test func codexUnregisteredSessionLeaseCleansOnceAndPreservesRegisteredSessions() async {
    let cleanupCounter = CleanupInvocationCounter()
    let unregisteredLease = CodexUnregisteredSessionLease(
        isAlreadyTracked: false,
        cleanup: {
            await cleanupCounter.increment()
        }
    )

    await unregisteredLease.cleanupIfNeeded()
    await unregisteredLease.cleanupIfNeeded()
    #expect(await cleanupCounter.count == 1)

    let registeredLease = CodexUnregisteredSessionLease(
        isAlreadyTracked: false,
        cleanup: {
            await cleanupCounter.increment()
        }
    )
    await registeredLease.markRegistered()
    await registeredLease.cleanupIfNeeded()
    #expect(await cleanupCounter.count == 1)

    let resumedLease = CodexUnregisteredSessionLease(
        isAlreadyTracked: true,
        cleanup: {
            await cleanupCounter.increment()
        }
    )
    await resumedLease.cleanupIfNeeded()
    #expect(await cleanupCounter.count == 1)
}

@MainActor
@Test func conversationStartCallbackSeesImageBeforeLongTurnCanTrimIt() {
    let registry = ProviderRegistry()
    registry.register(ImmediateTestProvider())
    let service = ConversationService(registry: registry)
    let state = ConversationState(agentID: UUID())
    let attachment = Attachment(
        data: Data([1, 2, 3]),
        mimeType: "image/png",
        filename: "test.png"
    )
    var imageSeenAtStart = false

    service.send(
        prompt: "inspect",
        attachments: [attachment],
        to: state,
        providerID: "start-callback-test",
        model: nil,
        onStart: {
            imageSeenAtStart = state.messages.last?.content.contains { content in
                if case .image(let data, _) = content { return data == attachment.data }
                return false
            } == true
        }
    )

    #expect(imageSeenAtStart)
}

@MainActor
@Test func conversationSessionReadyCallbackCanPersistFreshThreadImageCorrelation() async {
    let registry = ProviderRegistry()
    registry.register(ImmediateTestProvider())
    let service = ConversationService(registry: registry)
    let state = ConversationState(agentID: UUID())
    let attachment = Attachment(
        data: Data([4, 5, 6]),
        mimeType: "image/png",
        filename: "fresh.png"
    )
    var imageAndSessionWereAvailable = false

    await withCheckedContinuation { continuation in
        service.send(
            prompt: "fresh thread",
            attachments: [attachment],
            to: state,
            providerID: "start-callback-test",
            model: nil,
            onSessionReady: {
                imageAndSessionWereAvailable = state.sessionID == "session-ready-test"
                    && state.messages.last?.content.contains { content in
                        if case .image(let data, _) = content { return data == attachment.data }
                        return false
                    } == true
                continuation.resume()
            }
        )
    }

    #expect(imageAndSessionWereAvailable)
}

@MainActor
@Test func conversationSendReportsQueueRejectionWithoutAcceptingThePrompt() {
    let continuationStore = BlockingContinuationStore()
    let registry = ProviderRegistry()
    registry.register(BlockingTestProvider(continuationStore: continuationStore))
    let service = ConversationService(registry: registry)
    let state = ConversationState(agentID: UUID())

    #expect(service.send(prompt: "active", to: state, providerID: "blocking-test", model: nil))
    for index in 0..<20 {
        #expect(service.send(prompt: "queued \(index)", to: state, providerID: "blocking-test", model: nil))
    }

    #expect(!service.send(prompt: "must remain in composer", to: state, providerID: "blocking-test", model: nil))
    #expect(state.queuedPromptCount == 20)

    service.cancelStreaming(for: state.agentID)
}

@MainActor
@Test func conversationSteerAppendsAndPersistsOnlyAfterProviderAcceptance() async {
    let continuationStore = BlockingContinuationStore()
    let steeringStore = SteeringInvocationStore(acceptsGuidance: true)
    let provider = SteeringTestProvider(
        id: "steering-accept",
        continuationStore: continuationStore,
        steeringStore: steeringStore
    )
    let registry = ProviderRegistry()
    registry.register(provider)
    let service = ConversationService(registry: registry)
    let state = ConversationState(agentID: UUID())
    var acceptedCallbacks = 0

    #expect(service.send(prompt: "Initial", to: state, providerID: provider.id, model: nil))
    let accepted = await service.steer(
        prompt: "Use the smaller fix",
        conversationState: state,
        onAccepted: { acceptedCallbacks += 1 }
    )

    #expect(accepted)
    #expect(state.messages.map(\.textContent) == ["Initial", "Use the smaller fix"])
    #expect(state.queuedPromptCount == 0)
    #expect(acceptedCallbacks == 1)
    #expect(await steeringStore.prompts == ["Use the smaller fix"])
    #expect(state.runtimeActivities.contains {
        $0.summary == "Guidance sent" && $0.state == "steered"
    })

    service.cancelStreaming(for: state.agentID)
}

@MainActor
@Test func conversationRejectedSteerLeavesTranscriptAndCallbackUntouched() async {
    let continuationStore = BlockingContinuationStore()
    let steeringStore = SteeringInvocationStore(acceptsGuidance: false)
    let provider = SteeringTestProvider(
        id: "steering-reject",
        continuationStore: continuationStore,
        steeringStore: steeringStore
    )
    let registry = ProviderRegistry()
    registry.register(provider)
    let service = ConversationService(registry: registry)
    let state = ConversationState(agentID: UUID())
    var acceptedCallbacks = 0

    #expect(service.send(prompt: "Initial", to: state, providerID: provider.id, model: nil))
    let accepted = await service.steer(
        prompt: "Keep this draft",
        conversationState: state,
        onAccepted: { acceptedCallbacks += 1 }
    )

    #expect(!accepted)
    #expect(state.messages.map(\.textContent) == ["Initial"])
    #expect(state.queuedPromptCount == 0)
    #expect(acceptedCallbacks == 0)
    #expect(await steeringStore.prompts == ["Keep this draft"])
    #expect(state.error?.contains("retry or queue it") == true)
    #expect(state.runtimeActivities.contains { $0.summary == "Guidance not sent" })

    service.cancelStreaming(for: state.agentID)
}

@Test func aiModelDecodesLegacyPersistence() throws {
    let model = try JSONDecoder().decode(AIModel.self, from: Data(#"""
    {
        "id":"legacy-model",
        "name":"Legacy",
        "contextWindow":200000,
        "availableContextWindows":[200000],
        "supportsTools":true,
        "supportsVision":false
    }
    """#.utf8))

    #expect(model.id == "legacy-model")
    #expect(model.maxContextWindow == 200_000)
    #expect(model.inputModalities == [.text])
    #expect(model.supportedReasoningEfforts.isEmpty)
}

@Test func codexCatalogParsesRuntimeMetadata() throws {
    #expect(CodexProvider.fallbackModels.allSatisfy { $0.maxContextWindow == 272_000 })
    #expect(CodexProvider.fallbackModels.allSatisfy { $0.availableContextWindows == [272_000] })
    let data = Data(#"""
    {
      "models":[{
        "slug":"gpt-5.6-sol",
        "display_name":"GPT-5.6-Sol",
        "description":"Frontier",
        "visibility":"list",
        "context_window":272000,
        "max_context_window":1000000,
        "default_reasoning_level":"low",
        "supported_reasoning_levels":[{"effort":"low"},{"effort":"ultra"}],
        "input_modalities":["text","image"],
        "service_tiers":[{"id":"priority","name":"Fast","description":"Faster"}]
      }]
    }
    """#.utf8)

    let models = try #require(CodexProvider.parseModelCatalog(data))
    let sol = try #require(models.first)
    #expect(sol.id == "gpt-5.6-sol")
    #expect(sol.contextWindow == 272_000)
    #expect(sol.maxContextWindow == 1_000_000)
    #expect(sol.supportedReasoningEfforts == ["low", "ultra"])
    #expect(sol.inputModalities == [.text, .image])
    #expect(sol.serviceTiers.first?.id == "priority")
}

@Test func codexApprovalResponsesMatchCurrentAndLegacyProtocols() {
    #expect(CodexProvider.codexParams(for: .supervised).approvalPolicy == "untrusted")
    #expect(CodexProvider.codexParams(for: .acceptEdits).approvalPolicy == "on-request")
    #expect(CodexProvider.codexParams(for: .fullAccess).approvalPolicy == "never")
    #expect(CodexProvider.codexParams(for: .fullAccess).sandbox == "danger-full-access")

    #expect(CodexProvider.approvalResult(kind: "modern", approved: true)["decision"] as? String == "accept")
    #expect(CodexProvider.approvalResult(kind: "modern", approved: false)["decision"] as? String == "decline")
    #expect(CodexProvider.approvalResult(kind: "legacy", approved: true)["decision"] as? String == "approved")
    #expect(CodexProvider.approvalResult(kind: "legacy", approved: false)["decision"] as? String == "denied")

    let requested: [String: Any] = ["network": ["enabled": true]]
    let permission = CodexProvider.approvalResult(
        kind: "permissions",
        approved: true,
        requestedPermissions: requested
    )
    #expect(permission["scope"] as? String == "turn")
    #expect((permission["permissions"] as? [String: Any])?["network"] != nil)
}

@Test func codexStructuredUserInputMatchesCurrentProtocol() throws {
    let request = try #require(CodexProvider.userInputRequestForTesting([
        "threadId": "thread-1",
        "turnId": "turn-1",
        "itemId": "item-1",
        "autoResolutionMs": 60_000,
        "questions": [[
            "id": "deployment",
            "header": "Deploy",
            "question": "Where should this deploy?",
            "isOther": true,
            "options": [
                ["label": "Staging", "description": "Deploy to staging"],
                ["label": "Production", "description": "Deploy to production"],
            ],
        ], [
            "id": "token",
            "header": "Token",
            "question": "Enter the token",
            "isSecret": true,
        ]],
    ]))
    #expect(request.questions.count == 2)
    #expect(request.questions[0].allowsOther)
    #expect(request.questions[0].options.map(\.label) == ["Staging", "Production"])
    #expect(request.questions[1].isSecret)
    #expect(request.autoResolutionMilliseconds == 60_000)

    let response = CodexProvider.userInputResponseForTesting(
        questionIDs: request.questions.map(\.id),
        answers: ["deployment": ["Staging"], "token": ["secret"]]
    )
    let answers = try #require(response["answers"] as? [String: Any])
    #expect((answers["deployment"] as? [String: [String]])?["answers"] == ["Staging"])
    #expect((answers["token"] as? [String: [String]])?["answers"] == ["secret"])
}

@Test func codexMCPFormElicitationPreservesTypesConstraintsAndNativeEnumValues() throws {
    let request = try #require(CodexProvider.mcpUserInputRequestForTesting([
        "mode": "form",
        "serverName": "Deploy MCP",
        "message": "Configure the release.",
        "requestedSchema": [
            "type": "object",
            "required": ["name", "retries", "enabled", "target", "checks"],
            "properties": [
                "name": [
                    "type": "string",
                    "title": "Release name",
                    "description": "Name this release.",
                    "minLength": 3,
                    "maxLength": 20,
                    "default": "FlowX",
                ],
                "retries": [
                    "type": "integer",
                    "minimum": 0,
                    "maximum": 5,
                    "default": 2,
                ],
                "ratio": [
                    "type": "number",
                    "minimum": 0.0,
                    "maximum": 1.0,
                ],
                "enabled": [
                    "type": "boolean",
                    "default": false,
                ],
                "target": [
                    "type": "string",
                    "oneOf": [
                        ["const": "stg", "title": "Staging"],
                        ["const": "prod", "title": "Production"],
                    ],
                    "default": "stg",
                ],
                "checks": [
                    "type": "array",
                    "minItems": 1,
                    "maxItems": 2,
                    "items": [
                        "anyOf": [
                            ["const": "unit", "title": "Unit tests"],
                            ["const": "smoke", "title": "Smoke tests"],
                            ["const": "ui", "title": "UI checks"],
                        ],
                    ],
                ],
            ],
        ],
    ]))

    #expect(request.title == "Deploy MCP needs input")
    #expect(request.message == "Configure the release.")
    #expect(request.cancellationBehavior == .respondToProvider)
    #expect(request.questions.count == 6)

    let target = try #require(request.questions.first { $0.id == "target" })
    #expect(target.options.map(\.label) == ["Staging", "Production"])
    #expect(target.options.map(\.value) == ["stg", "prod"])
    #expect(target.defaultAnswers == ["stg"])

    let checks = try #require(request.questions.first { $0.id == "checks" })
    #expect(checks.allowsMultiple)
    #expect(checks.minimumSelectionCount == 1)
    #expect(checks.maximumSelectionCount == 2)

    let ratio = try #require(request.questions.first { $0.id == "ratio" })
    #expect(!ratio.isRequired)
    #expect(ratio.valueType == .number)

    let response = try #require(CodexProvider.mcpFormResponseForTesting(
        fields: request.questions,
        answers: [
            "name": ["FlowX 2"],
            "retries": ["3"],
            "enabled": ["false"],
            "target": ["prod"],
            "checks": ["unit", "smoke"],
        ]
    ))
    #expect(response["action"] as? String == "accept")
    let content = try #require(response["content"] as? [String: Any])
    #expect(content["name"] as? String == "FlowX 2")
    #expect(content["retries"] as? Int64 == 3)
    #expect(content["enabled"] as? Bool == false)
    #expect(content["target"] as? String == "prod")
    #expect(content["checks"] as? [String] == ["unit", "smoke"])
    #expect(content["ratio"] == nil)

    #expect(CodexProvider.mcpFormResponseForTesting(
        fields: request.questions,
        answers: ["name": ["x"]]
    ) == nil)
}

@Test func codexMCPURLOnlyAcceptsCredentialFreeHTTPS() throws {
    let request = try #require(CodexProvider.mcpUserInputRequestForTesting([
        "mode": "url",
        "serverName": "Accounts",
        "message": "Authorize the connection.",
        "url": "https://example.com/connect?state=opaque",
        "elicitationId": "elicit-1",
    ]))
    #expect(request.title == "Accounts needs confirmation")
    #expect(request.questions.isEmpty)
    #expect(request.presentation == .externalURL("https://example.com/connect?state=opaque"))
    #expect(request.cancellationBehavior == .respondToProvider)

    let unsafeHTTP = try #require(CodexProvider.mcpUserInputRequestForTesting([
        "mode": "url",
        "serverName": "Accounts",
        "message": "Unsafe",
        "url": "http://example.com/connect",
        "elicitationId": "elicit-2",
    ]))
    #expect(unsafeHTTP.title == "Accounts needs a decision")
    #expect(unsafeHTTP.presentation == .decision(actionLabel: "Decline request"))
    #expect(unsafeHTTP.cancellationBehavior == .respondToProvider)
    #expect(unsafeHTTP.message?.contains("only opens explicit HTTPS links") == true)

    let embeddedCredentials = try #require(CodexProvider.mcpUserInputRequestForTesting([
        "mode": "url",
        "message": "Unsafe",
        "url": "https://user:secret@example.com/connect",
        "elicitationId": "elicit-3",
    ]))
    #expect(embeddedCredentials.presentation == .decision(actionLabel: "Decline request"))

    let opaqueForm = try #require(CodexProvider.mcpUserInputRequestForTesting([
        "mode": "openai/form",
        "message": "Opaque",
        "requestedSchema": [:],
    ]))
    #expect(opaqueForm.presentation == .decision(actionLabel: "Decline request"))
    #expect(opaqueForm.message?.contains("No response will be sent until you choose an action.") == true)
}

@Test func codexUnsupportedMCPElicitationsRequireAnExplicitDecision() throws {
    let unsupportedForm = try #require(CodexProvider.mcpUserInputRequestForTesting([
        "mode": "form",
        "serverName": "Schema MCP",
        "message": "Complete this custom widget.",
        "requestedSchema": [
            "type": "object",
            "properties": [
                "custom": ["type": "unsupported-widget"],
            ],
        ],
    ]))
    #expect(unsupportedForm.questions.isEmpty)
    #expect(unsupportedForm.title == "Schema MCP needs a decision")
    #expect(unsupportedForm.presentation == .decision(actionLabel: "Decline request"))
    #expect(unsupportedForm.cancellationBehavior == .respondToProvider)
    #expect(unsupportedForm.message?.contains("invalid or unsupported schema") == true)

    let unknownMode = try #require(CodexProvider.mcpUserInputRequestForTesting([
        "mode": "future-mode",
        "serverName": "Future MCP",
        "message": "Use a future interaction.",
    ]))
    #expect(unknownMode.questions.isEmpty)
    #expect(unknownMode.presentation == .decision(actionLabel: "Decline request"))
    #expect(unknownMode.message?.contains("future-mode") == true)
}

@Test func codexMCPFormAllowsExplicitEmptyAndWhitespaceValues() throws {
    let request = try #require(CodexProvider.mcpUserInputRequestForTesting([
        "mode": "form",
        "message": "Empty values are valid here.",
        "requestedSchema": [
            "type": "object",
            "required": ["empty", "whitespace", "choices"],
            "properties": [
                "empty": ["type": "string", "minLength": 0],
                "whitespace": ["type": "string", "minLength": 2],
                "choices": [
                    "type": "array",
                    "minItems": 0,
                    "items": ["type": "string", "enum": ["a", "b"]],
                ],
            ],
        ],
    ]))
    let empty = try #require(request.questions.first { $0.id == "empty" })
    let choices = try #require(request.questions.first { $0.id == "choices" })
    #expect(empty.allowsEmptyValue)
    #expect(empty.preservesWhitespace)
    #expect(choices.allowsEmptyValue)

    let response = try #require(CodexProvider.mcpFormResponseForTesting(
        fields: request.questions,
        answers: [
            "empty": [""],
            "whitespace": ["  "],
            "choices": [],
        ]
    ))
    let content = try #require(response["content"] as? [String: Any])
    #expect(content["empty"] as? String == "")
    #expect(content["whitespace"] as? String == "  ")
    #expect(content["choices"] as? [String] == [])
}

@Test func codexMCPFormAcceptsNullableSchemaKeywords() throws {
    let request = try #require(CodexProvider.mcpUserInputRequestForTesting([
        "mode": "form",
        "message": "Nullable schema annotations are omitted.",
        "requestedSchema": [
            "type": "object",
            "required": NSNull(),
            "properties": [
                "text": [
                    "type": "string",
                    "title": NSNull(),
                    "description": NSNull(),
                    "format": NSNull(),
                    "minLength": NSNull(),
                    "maxLength": NSNull(),
                    "default": NSNull(),
                ],
                "amount": [
                    "type": "number",
                    "minimum": NSNull(),
                    "maximum": NSNull(),
                    "default": NSNull(),
                ],
                "enabled": [
                    "type": "boolean",
                    "default": NSNull(),
                ],
                "tags": [
                    "type": "array",
                    "minItems": NSNull(),
                    "maxItems": NSNull(),
                    "default": NSNull(),
                    "items": ["type": "string", "enum": ["one"]],
                ],
            ],
        ],
    ]))
    #expect(request.questions.count == 4)
    #expect(request.questions.allSatisfy { !$0.isRequired })
    #expect(CodexProvider.mcpFormResponseForTesting(fields: request.questions, answers: [:]) != nil)
}

@Test func codexNativeThreadDiscoverySeparatesRepairFromFrequentPolling() {
    let indexed = CodexProvider.nativeThreadListParametersForTesting(
        cwdFilters: ["/workspace"],
        limit: 250,
        cursor: "next",
        discoveryMode: .indexed
    )
    #expect(indexed["useStateDbOnly"] as? Bool == true)
    #expect(indexed["limit"] as? Int == 100)
    #expect(indexed["cwd"] as? String == "/workspace")
    #expect(indexed["cursor"] as? String == "next")

    let repair = CodexProvider.nativeThreadListParametersForTesting(
        cwdFilters: ["/configured", "/canonical"],
        limit: 25,
        discoveryMode: .repair
    )
    #expect(repair["useStateDbOnly"] as? Bool == false)
    #expect(repair["cwd"] as? [String] == ["/configured", "/canonical"])
}

@Test func codexControlRPCsHaveBoundedTimeouts() {
    #expect(CodexProvider.controlRequestTimeoutSecondsForTesting == 30)
}

@Test func codexRuntimePrefersTheDesktopAgentsSignedBinary() {
    #expect(BinarySpec.codex.searchPaths.prefix(4).contains(
        "/Applications/ChatGPT.app/Contents/Resources/codex"
    ))
    let desktopIndex = BinarySpec.codex.searchPaths.firstIndex(
        of: "/Applications/ChatGPT.app/Contents/Resources/codex"
    )
    let homebrewIndex = BinarySpec.codex.searchPaths.firstIndex(of: "/opt/homebrew/bin/codex")
    #expect(desktopIndex != nil)
    #expect(homebrewIndex != nil)
    if let desktopIndex, let homebrewIndex {
        #expect(desktopIndex < homebrewIndex)
    }
}

@Test func codexInitializationFailureExplainsQuarantineAndProcessExit() {
    let message = CodexProvider.initializationFailureMessageForTesting(
        executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
        stderr: "Gatekeeper rejected the executable",
        terminationStatus: 9,
        terminatedBySignal: true,
        isQuarantined: true
    )

    #expect(message.contains("did not complete initialization"))
    #expect(message.contains("quarantined Codex executable"))
    #expect(message.contains("/opt/homebrew/bin/codex"))
    #expect(message.contains("does not bypass Gatekeeper"))
    #expect(message.contains("signal 9"))
    #expect(message.contains("Gatekeeper rejected the executable"))
}

@Test func codexCancellationBeforeSessionCreationIsRemembered() async {
    #expect(await CodexProvider.preSessionCancellationIsRememberedForTesting())
}

@Test func codexNativeMappingIsStableBoundedAndForwardCompatible() throws {
    let oversizedText = String(repeating: "é", count: 200_000)
    let thread: [String: Any] = [
        "id": "thread-opaque",
        "turns": [[
            "id": "turn-opaque",
            "startedAt": 1,
            "completedAt": 2,
            "items": [
                ["id": "message-opaque", "type": "agentMessage", "text": oversizedText],
                ["id": "future-opaque", "type": "futureTool", "input": ["value": "ok"], "status": "completed"],
            ],
        ]],
    ]

    let first = CodexProvider.mapNativeMessagesForTesting(thread)
    let second = CodexProvider.mapNativeMessagesForTesting(thread)
    #expect(first.map(\.id) == second.map(\.id))
    #expect(first.count == 2)
    let text = try #require(first.first?.textContent)
    #expect(text.utf8.count < 270_000)
    if case .toolUse(_, let name, _) = first.last?.content.first {
        #expect(name == "futureTool")
    } else {
        Issue.record("Unknown native item was not preserved as a lossy tool summary")
    }
}

@Test func codexNativeMappingKeepsDialogueAheadOfLifecycleNoise() throws {
    let noise: [[String: Any]] = (0..<400).map { index in
        [
            "id": "activity-\(index)",
            "type": "subAgentActivity",
            "status": "completed",
            "message": "worker update",
        ]
    }
    let thread: [String: Any] = [
        "id": "thread-noise",
        "turns": [[
            "id": "turn-noise",
            "startedAt": 1,
            "completedAt": 2,
            "items": [
                ["id": "user-real", "type": "userMessage", "content": [["type": "text", "text": "Keep me"]]],
            ] + noise + [
                ["id": "agent-real", "type": "agentMessage", "text": "Still here"],
            ],
        ]],
    ]

    let messages = CodexProvider.mapNativeMessagesForTesting(thread)
    #expect(messages.count == 2)
    #expect(messages.first?.textContent == "Keep me")
    #expect(messages.last?.textContent == "Still here")
}

@Test func codexTurnPaginationIsBoundedAndRejectsRepeatedCursors() {
    var pages = CodexNativeTurnPageAccumulator(maximumTurns: 3)
    let first = pages.append(
        page: [["id": "newest"], ["id": "middle"]],
        nextCursor: "cursor-1"
    )
    #expect(first == "cursor-1")
    let repeated = pages.append(page: [["id": "oldest"]], nextCursor: "cursor-1")
    #expect(repeated == nil)
    #expect(pages.newestFirstTurns.count == 3)
    #expect((pages.chronologicalTurns.first?["id"] as? String) == "oldest")
}

@Test func codexJSONLineBufferFramesLargeChunkedMessagesOnce() throws {
    var buffer = ProviderJSONLineBuffer(maximumBytes: 2 * 1_024 * 1_024)
    let payload = String(repeating: "x", count: 1 * 1_024 * 1_024)
    let data = Data(payload.utf8)
    for start in stride(from: 0, to: data.count, by: 1_024) {
        let output = buffer.append(data.subdata(in: start..<min(start + 1_024, data.count)))
        #expect(!output.overflow)
        #expect(output.lines.isEmpty)
    }
    let output = buffer.append(Data("\r\nnext\n".utf8))
    #expect(output.lines == [payload, "next"])
    #expect(buffer.flush() == nil)
}

@Test func claudeArgumentsPreserveNativeDefaultsAndUseAcceptedModes() {
    #expect(ClaudeCodeProvider.fallbackModels.map(\.id) == [
        "claude-fable-5",
        "claude-opus-4-8",
        "claude-sonnet-5",
        "claude-haiku-4-5",
    ])
    #expect(ClaudeCodeProvider.fallbackModels.prefix(3).allSatisfy { $0.defaultReasoningEffort == "high" })
    #expect(ClaudeCodeProvider.fallbackModels.last?.supportedReasoningEfforts.isEmpty == true)

    let automatic = ClaudeCodeProvider.buildArguments(
        model: nil,
        effort: nil,
        systemPrompt: nil,
        agentMode: nil,
        agentAccess: nil,
        resumeSessionID: "session-id",
        attachmentDirectory: nil
    )
    #expect(!automatic.contains("--model"))
    #expect(!automatic.contains("--effort"))
    #expect(!automatic.contains("--permission-mode"))
    #expect(automatic.contains("--resume"))

    let supervised = ClaudeCodeProvider.buildArguments(
        model: "claude-fable-5",
        effort: "max",
        systemPrompt: "Extra guidance",
        agentMode: .auto,
        agentAccess: .supervised,
        resumeSessionID: nil,
        attachmentDirectory: nil
    )
    #expect(supervised.contains("manual"))
    #expect(!supervised.contains("dontAsk"))
    #expect(!supervised.contains("default"))
    #expect(supervised.contains("--append-system-prompt"))
    #expect(!supervised.contains("--system-prompt"))
    #expect(supervised.contains("--input-format"))
    #expect(supervised.contains("--permission-prompt-tool"))

    let fullAccess = ClaudeCodeProvider.buildArguments(
        model: nil,
        effort: nil,
        systemPrompt: nil,
        agentMode: .auto,
        agentAccess: .fullAccess,
        resumeSessionID: nil,
        attachmentDirectory: nil
    )
    #expect(!fullAccess.contains("--dangerously-skip-permissions"))
    #expect(fullAccess.contains("--permission-mode"))
    #expect(fullAccess.contains("manual"))
    #expect(fullAccess.contains("--permission-prompt-tool"))

    let acceptEdits = ClaudeCodeProvider.buildArguments(
        model: nil,
        effort: nil,
        systemPrompt: nil,
        agentMode: .auto,
        agentAccess: .acceptEdits,
        resumeSessionID: nil,
        attachmentDirectory: nil
    )
    #expect(acceptEdits.contains("acceptEdits"))
    #expect(!acceptEdits.contains("--dangerously-skip-permissions"))
}

@Test func claudeStreamParserPreservesToolsResultsAndOptionalModel() throws {
    let parser = ClaudeStreamParser()
    let initialization = parser.events(for: #"{"type":"system","subtype":"init","session_id":"s1"}"#)
    if case .initialized(let sessionID, let model) = try #require(initialization.first) {
        #expect(sessionID == "s1")
        #expect(model == nil)
    } else {
        Issue.record("Missing Claude initialization event")
    }

    let tools = parser.events(for: #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"path":"a"}},{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"pwd"}}]}}"#)
    #expect(tools.count == 2)
    let results = parser.events(for: #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"},{"type":"tool_result","tool_use_id":"t2","content":"done"}]}}"#)
    #expect(results.count == 2)
    let completion = parser.events(for: #"{"type":"result","subtype":"success","total_cost_usd":0.1,"usage":{"input_tokens":3,"output_tokens":4}}"#)
    #expect(completion.count == 2)
    if case .done(let reason) = completion.last { #expect(reason == "success") }
    else { Issue.record("Claude result did not finish the turn") }
}

@Test func claudeControlProtocolSurfacesApprovalsAndQuestions() throws {
    let controller = ClaudeTurnController()
    let parser = ClaudeStreamParser(controller: controller)
    let approvalEvents = parser.events(for: #"{"type":"control_request","request_id":"request-1","request":{"subtype":"can_use_tool","tool_name":"Bash","tool_use_id":"tool-1","title":"Run command?","input":{"command":"git status"}}}"#)
    if case .approvalRequest(let approval) = try #require(approvalEvents.first) {
        #expect(approval.toolName == "Bash")
        #expect(approval.parameters["command"] == "git status")
    } else {
        Issue.record("Claude permission control request was not surfaced")
    }

    let questionEvents = parser.events(for: #"{"type":"control_request","request_id":"request-2","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","tool_use_id":"tool-2","input":{"questions":[{"question":"Choose targets","header":"Targets","multiSelect":true,"options":[{"label":"Web","description":"Web app"},{"label":"API","description":"API service"}]}]}}}"#)
    if case .userInputRequest(let request) = try #require(questionEvents.first) {
        #expect(request.questions.first?.question == "Choose targets")
        #expect(request.questions.first?.allowsMultiple == true)
        #expect(request.questions.first?.allowsOther == true)
        #expect(request.questions.first?.options.map(\.label) == ["Web", "API"])
    } else {
        Issue.record("Claude AskUserQuestion was not surfaced")
    }

    let allow = ClaudeTurnController.permissionDecision(
        approved: true,
        toolUseID: "tool-2",
        updatedInput: ["answers": ["Choose targets": "Web, API"]],
        denialMessage: ""
    )
    #expect(allow["behavior"] as? String == "allow")
    #expect(allow["decisionClassification"] as? String == "user_temporary")
    #expect((allow["updatedInput"] as? [String: Any])?["answers"] != nil)
}

@Test func claudeFullAccessAutoApprovesToolsButNeverQuestions() throws {
    let controller = ClaudeTurnController(autoApproveTools: true)
    let responsePipe = Pipe()
    controller.setWriter(responsePipe.fileHandleForWriting)
    let parser = ClaudeStreamParser(controller: controller)
    let toolEvents = parser.events(for: #"{"type":"control_request","request_id":"request-tool","request":{"subtype":"can_use_tool","tool_name":"Bash","tool_use_id":"tool-1","input":{"command":"pwd"}}}"#)
    #expect(toolEvents.isEmpty)
    controller.closeInput()

    let responseData = responsePipe.fileHandleForReading.readDataToEndOfFile()
    let responseEnvelope = try #require(
        JSONSerialization.jsonObject(with: responseData) as? [String: Any]
    )
    #expect(responseEnvelope["type"] as? String == "control_response")
    let response = try #require(responseEnvelope["response"] as? [String: Any])
    #expect(response["request_id"] as? String == "request-tool")
    let decision = try #require(response["response"] as? [String: Any])
    #expect(decision["behavior"] as? String == "allow")
    #expect(decision["toolUseID"] as? String == "tool-1")
    #expect((decision["updatedInput"] as? [String: Any])?["command"] as? String == "pwd")

    let questionController = ClaudeTurnController(autoApproveTools: true)
    let questionParser = ClaudeStreamParser(controller: questionController)
    let questionEvents = questionParser.events(for: #"{"type":"control_request","request_id":"request-question","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","tool_use_id":"tool-2","input":{"questions":[{"question":"Continue?","header":"Continue","multiSelect":false,"options":[{"label":"Yes","description":"Continue"},{"label":"No","description":"Stop"}]}]}}}"#)
    if case .userInputRequest(let request) = try #require(questionEvents.first) {
        // Expected: user-dialog tools always wait for explicit UI input.
        #expect(request.questions.first?.question == "Continue?")
    } else {
        Issue.record("Full access auto-answered AskUserQuestion")
    }
}

@Test func claudeControllerWritesASecondLiveUserMessageAndRejectsClosedInput() throws {
    let controller = ClaudeTurnController()
    let inputPipe = Pipe()
    controller.setWriter(inputPipe.fileHandleForWriting)
    try controller.sendInitialPrompt("First")
    try controller.sendFollowUpPrompt("Steer this")
    controller.closeInput()

    let data = inputPipe.fileHandleForReading.readDataToEndOfFile()
    let envelopes = String(decoding: data, as: UTF8.self)
        .split(separator: "\n")
        .compactMap { line -> [String: Any]? in
            guard let lineData = line.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
        }
    #expect(envelopes.count == 2)
    let textMessages = envelopes.compactMap { envelope -> String? in
        let message = envelope["message"] as? [String: Any]
        let content = message?["content"] as? [[String: Any]]
        return content?.first(where: { $0["type"] as? String == "text" })?["text"] as? String
    }
    #expect(textMessages == ["First", "Steer this"])

    do {
        try controller.sendFollowUpPrompt("Too late")
        Issue.record("Closed Claude input accepted another message")
    } catch {
        #expect(error.localizedDescription.contains("closed"))
    }
}

@Test func codexSteerParametersUseExpectedTurnAndNativeInputs() throws {
    let image = URL(fileURLWithPath: "/tmp/flowx-steer.png")
    let params = CodexProvider.turnSteerParametersForTesting(
        threadID: "thread-1",
        expectedTurnID: "turn-1",
        prompt: "Change direction",
        imagePaths: [image]
    )

    #expect(params["threadId"] as? String == "thread-1")
    #expect(params["expectedTurnId"] as? String == "turn-1")
    let input = try #require(params["input"] as? [[String: String]])
    #expect(input == [
        ["type": "localImage", "path": image.path],
        ["type": "text", "text": "Change direction"],
    ])
}

@Test func promptFollowUpModeProvidesStablePersistenceAndOppositeShortcut() {
    #expect(PromptFollowUpMode.allCases == [.steer, .queue])
    #expect(PromptFollowUpMode.steer.rawValue == "steer")
    #expect(PromptFollowUpMode.steer.label == "Steer")
    #expect(PromptFollowUpMode.steer.opposite == .queue)
    #expect(PromptFollowUpMode.queue.opposite == .steer)
}

@Test func attachmentStoreWritesValidatedPrivateImage() throws {
    let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
    let prepared = try ProviderAttachmentStore.prepare([
        Attachment(data: png, mimeType: "image/png", filename: "pixel.png"),
    ])
    defer { prepared.remove() }
    let file = try #require(prepared.files.first)
    #expect(FileManager.default.fileExists(atPath: file.path))
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

    #expect(throws: ProviderAttachmentError.self) {
        try ProviderAttachmentStore.prepare([
            Attachment(data: Data("pdf".utf8), mimeType: "application/pdf", filename: "file.pdf"),
        ])
    }
}

@Test func claudeNativeStoreUsesExactWorkspaceAndMapsTranscript() async throws {
    let manager = FileManager.default
    let container = manager.temporaryDirectory
        .appendingPathComponent("flowx-claude-native-\(UUID().uuidString)", isDirectory: true)
    let workspace = container.appendingPathComponent("workspace", isDirectory: true)
    let config = container.appendingPathComponent("claude-config", isDirectory: true)
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

    let sessionID = "11111111-2222-4333-8444-555555555555"
    let records = [
        #"{"type":"user","uuid":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","sessionId":"11111111-2222-4333-8444-555555555555","cwd":"WORKSPACE","timestamp":"2026-07-23T01:00:00.000Z","message":{"content":"Build it"}}"#,
        #"{"type":"assistant","uuid":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","sessionId":"11111111-2222-4333-8444-555555555555","cwd":"WORKSPACE","timestamp":"2026-07-23T01:00:01.000Z","message":{"model":"claude-fable-5","content":[{"type":"text","text":"Built"},{"type":"tool_use","id":"tool-1","name":"Read","input":{"path":"README.md"}}]}}"#,
        #"{"type":"last-prompt","sessionId":"11111111-2222-4333-8444-555555555555","lastPrompt":"Build it"}"#,
    ]
    .map { $0.replacingOccurrences(of: "WORKSPACE", with: canonical) }
    .joined(separator: "\n") + "\n"
    try Data(records.utf8).write(to: project.appendingPathComponent(sessionID).appendingPathExtension("jsonl"))

    let store = ClaudeNativeThreadStore(configRoot: config)
    let summaries = try await store.list(workingDirectory: workspace, limit: 10)
    #expect(summaries.count == 1)
    #expect(summaries.first?.id == sessionID)
    #expect(summaries.first?.model == "claude-fable-5")

    let thread = try await store.read(id: sessionID, workingDirectory: workspace)
    #expect(thread.messages.count == 2)
    #expect(thread.messages.first?.textContent == "Build it")
    #expect(thread.messages.last?.textContent == "Built")
    #expect(thread.messages.last?.content.count == 2)
}

@Test func claudeNativeSummaryCacheReusesAndInvalidatesMetadata() async throws {
    let manager = FileManager.default
    let container = manager.temporaryDirectory
        .appendingPathComponent("flowx-claude-cache-\(UUID().uuidString)", isDirectory: true)
    let workspace = container.appendingPathComponent("workspace", isDirectory: true)
    let config = container.appendingPathComponent("claude-config", isDirectory: true)
    try manager.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: container) }

    let canonical = workspace.standardizedFileURL.resolvingSymlinksInPath().path
    let projectKey = canonical.unicodeScalars.map { scalar -> Character in
        CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
    }
    let project = config.appendingPathComponent("projects", isDirectory: true)
        .appendingPathComponent(String(projectKey), isDirectory: true)
    try manager.createDirectory(at: project, withIntermediateDirectories: true)
    let sessionID = "21111111-2222-4333-8444-555555555555"
    let file = project.appendingPathComponent(sessionID).appendingPathExtension("jsonl")
    let base = [
        #"{"type":"user","sessionId":"SESSION","cwd":"WORKSPACE","timestamp":"2026-07-23T01:00:00.000Z","message":{"content":"Original prompt"}}"#,
        #"{"type":"ai-title","sessionId":"SESSION","cwd":"WORKSPACE","timestamp":"2026-07-23T01:00:01.000Z","aiTitle":"Native Claude title"}"#,
    ]
    .map { $0.replacingOccurrences(of: "SESSION", with: sessionID).replacingOccurrences(of: "WORKSPACE", with: canonical) }
    .joined(separator: "\n") + "\n"
    try Data(base.utf8).write(to: file)

    let store = ClaudeNativeThreadStore(configRoot: config)
    let first = try await store.list(workingDirectory: workspace, limit: 10)
    #expect(first.first?.title == "Native Claude title")
    var statistics = await store.summaryCacheStatisticsForTesting()
    #expect(statistics.parses == 1)
    _ = try await store.list(workingDirectory: workspace, limit: 10)
    statistics = await store.summaryCacheStatisticsForTesting()
    #expect(statistics.parses == 1)

    let changed = base + #"{"type":"ai-title","sessionId":"SESSION","cwd":"WORKSPACE","timestamp":"2026-07-23T01:00:02.000Z","aiTitle":"Renamed natively"}"#
        .replacingOccurrences(of: "SESSION", with: sessionID)
        .replacingOccurrences(of: "WORKSPACE", with: canonical) + "\n"
    try Data(changed.utf8).write(to: file, options: [.atomic])
    let refreshed = try await store.list(workingDirectory: workspace, limit: 10)
    #expect(refreshed.first?.title == "Renamed natively")
    statistics = await store.summaryCacheStatisticsForTesting()
    #expect(statistics.parses == 2)

    try manager.removeItem(at: file)
    let afterRemoval = try await store.list(workingDirectory: workspace, limit: 10)
    #expect(afterRemoval.isEmpty)
    statistics = await store.summaryCacheStatisticsForTesting()
    #expect(statistics.entries == 0)
}

@Test func claudeNativeSummaryCacheIsGloballyLRUBoundedAcrossWorkspaces() async throws {
    let manager = FileManager.default
    let container = manager.temporaryDirectory
        .appendingPathComponent("flowx-claude-cache-cap-\(UUID().uuidString)", isDirectory: true)
    let config = container.appendingPathComponent("claude-config", isDirectory: true)
    defer { try? manager.removeItem(at: container) }

    func makeWorkspace(_ index: Int) throws -> URL {
        let workspace = container.appendingPathComponent("workspace-\(index)", isDirectory: true)
        try manager.createDirectory(at: workspace, withIntermediateDirectories: true)
        let canonical = workspace.resolvingSymlinksInPath().standardizedFileURL.path
        let key = canonical.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let project = config.appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(String(key), isDirectory: true)
        try manager.createDirectory(at: project, withIntermediateDirectories: true)
        let sessionID = "7\(index)111111-2222-4333-8444-555555555555"
        let record = #"{"type":"user","sessionId":"SESSION","cwd":"WORKSPACE","timestamp":"2026-07-23T01:00:00.000Z","message":{"content":"Cache entry"}}"#
            .replacingOccurrences(of: "SESSION", with: sessionID)
            .replacingOccurrences(of: "WORKSPACE", with: canonical) + "\n"
        try Data(record.utf8).write(
            to: project.appendingPathComponent(sessionID).appendingPathExtension("jsonl")
        )
        return workspace
    }

    let first = try makeWorkspace(1)
    let second = try makeWorkspace(2)
    let third = try makeWorkspace(3)
    let store = ClaudeNativeThreadStore(configRoot: config, maximumSummaryCacheEntries: 2)

    _ = try await store.list(workingDirectory: first, limit: 1)
    _ = try await store.list(workingDirectory: second, limit: 1)
    _ = try await store.list(workingDirectory: first, limit: 1)
    _ = try await store.list(workingDirectory: third, limit: 1)
    var statistics = await store.summaryCacheStatisticsForTesting()
    #expect(statistics.entries == 2)
    #expect(statistics.parses == 3)

    _ = try await store.list(workingDirectory: first, limit: 1)
    statistics = await store.summaryCacheStatisticsForTesting()
    #expect(statistics.parses == 3)
    _ = try await store.list(workingDirectory: second, limit: 1)
    statistics = await store.summaryCacheStatisticsForTesting()
    #expect(statistics.entries == 2)
    #expect(statistics.parses == 4)
}

@Test func claudeNativeReadKeepsOriginalTitleWhenTranscriptIsTailBounded() async throws {
    let manager = FileManager.default
    let container = manager.temporaryDirectory
        .appendingPathComponent("flowx-claude-tail-\(UUID().uuidString)", isDirectory: true)
    let workspace = container.appendingPathComponent("workspace", isDirectory: true)
    let config = container.appendingPathComponent("claude-config", isDirectory: true)
    try manager.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: container) }

    let canonical = workspace.standardizedFileURL.resolvingSymlinksInPath().path
    let projectKey = canonical.unicodeScalars.map { scalar -> Character in
        CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
    }
    let project = config.appendingPathComponent("projects", isDirectory: true)
        .appendingPathComponent(String(projectKey), isDirectory: true)
    try manager.createDirectory(at: project, withIntermediateDirectories: true)
    let sessionID = "31111111-2222-4333-8444-555555555555"
    let filler = String(repeating: "x", count: 8_000)
    let records = [
        #"{"type":"user","sessionId":"SESSION","cwd":"WORKSPACE","timestamp":"2026-07-23T01:00:00.000Z","message":{"content":"Original task title"}}"#,
        #"{"type":"progress","payload":"FILLER"}"#.replacingOccurrences(of: "FILLER", with: filler),
        #"{"type":"user","sessionId":"SESSION","cwd":"WORKSPACE","timestamp":"2026-07-23T01:10:00.000Z","message":{"content":"Later follow-up"}}"#,
        #"{"type":"assistant","sessionId":"SESSION","cwd":"WORKSPACE","timestamp":"2026-07-23T01:10:01.000Z","message":{"model":"claude-fable-5","content":[{"type":"text","text":"Latest answer"}]}}"#,
    ]
    .map { $0.replacingOccurrences(of: "SESSION", with: sessionID).replacingOccurrences(of: "WORKSPACE", with: canonical) }
    .joined(separator: "\n") + "\n"
    try Data(records.utf8).write(to: project.appendingPathComponent(sessionID).appendingPathExtension("jsonl"))

    let store = ClaudeNativeThreadStore(configRoot: config, maximumTranscriptBytes: 768)
    let thread = try await store.read(id: sessionID, workingDirectory: workspace)
    #expect(thread.summary.title == "Original task title")
    #expect(thread.messages.first?.textContent == "Later follow-up")
    #expect(thread.messages.last?.textContent == "Latest answer")
}

@Test func claudeNativeStoreFindsSessionsWrittenUnderSymlinkSpelling() async throws {
    let manager = FileManager.default
    let container = manager.temporaryDirectory
        .appendingPathComponent("flowx-claude-symlink-\(UUID().uuidString)", isDirectory: true)
    let workspace = container.appendingPathComponent("workspace", isDirectory: true)
    let alias = container.appendingPathComponent("workspace-alias", isDirectory: true)
    let config = container.appendingPathComponent("claude-config", isDirectory: true)
    try manager.createDirectory(at: workspace, withIntermediateDirectories: true)
    try manager.createSymbolicLink(at: alias, withDestinationURL: workspace)
    defer { try? manager.removeItem(at: container) }

    let configured = alias.standardizedFileURL.path
    let projectKey = configured.unicodeScalars.map { scalar -> Character in
        CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
    }
    let project = config.appendingPathComponent("projects", isDirectory: true)
        .appendingPathComponent(String(projectKey), isDirectory: true)
    try manager.createDirectory(at: project, withIntermediateDirectories: true)
    let sessionID = "41111111-2222-4333-8444-555555555555"
    let record = #"{"type":"user","sessionId":"SESSION","cwd":"WORKSPACE","timestamp":"2026-07-23T01:00:00.000Z","message":{"content":"Alias task"}}"#
        .replacingOccurrences(of: "SESSION", with: sessionID)
        .replacingOccurrences(of: "WORKSPACE", with: configured) + "\n"
    try Data(record.utf8).write(to: project.appendingPathComponent(sessionID).appendingPathExtension("jsonl"))

    let store = ClaudeNativeThreadStore(configRoot: config)
    let summaries = try await store.list(workingDirectory: alias, limit: 10)
    #expect(summaries.map(\.id) == [sessionID])
    let thread = try await store.read(id: sessionID, workingDirectory: alias)
    #expect(thread.messages.first?.textContent == "Alias task")
    #expect(thread.summary.workingDirectory == workspace.resolvingSymlinksInPath().standardizedFileURL.path)
}

@Test func claudeNativeStoreValidatesCwdBeforeApplyingResultCap() async throws {
    let manager = FileManager.default
    let container = manager.temporaryDirectory
        .appendingPathComponent("flowx-claude-collision-\(UUID().uuidString)", isDirectory: true)
    let workspace = container.appendingPathComponent("a-b", isDirectory: true)
    let collidingWorkspace = container.appendingPathComponent("a/b", isDirectory: true)
    let config = container.appendingPathComponent("claude-config", isDirectory: true)
    try manager.createDirectory(at: workspace, withIntermediateDirectories: true)
    try manager.createDirectory(at: collidingWorkspace, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: container) }

    let canonical = workspace.resolvingSymlinksInPath().standardizedFileURL.path
    let collision = collidingWorkspace.resolvingSymlinksInPath().standardizedFileURL.path
    let key = canonical.unicodeScalars.map { scalar -> Character in
        CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
    }
    let collisionKey = collision.unicodeScalars.map { scalar -> Character in
        CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
    }
    #expect(String(key) == String(collisionKey))
    let project = config.appendingPathComponent("projects", isDirectory: true)
        .appendingPathComponent(String(key), isDirectory: true)
    try manager.createDirectory(at: project, withIntermediateDirectories: true)

    let validID = "51111111-2222-4333-8444-555555555555"
    let valid = #"{"type":"user","sessionId":"SESSION","cwd":"WORKSPACE","timestamp":"2026-07-23T01:00:00.000Z","message":{"content":"Valid task"}}"#
        .replacingOccurrences(of: "SESSION", with: validID)
        .replacingOccurrences(of: "WORKSPACE", with: canonical) + "\n"
    try Data(valid.utf8).write(to: project.appendingPathComponent(validID).appendingPathExtension("jsonl"))

    for index in 0..<3 {
        let invalidID = "6\(index)111111-2222-4333-8444-555555555555"
        let invalid = #"{"type":"user","sessionId":"SESSION","cwd":"WORKSPACE","timestamp":"2026-07-23T01:10:00.000Z","message":{"content":"Collision"}}"#
            .replacingOccurrences(of: "SESSION", with: invalidID)
            .replacingOccurrences(of: "WORKSPACE", with: collision) + "\n"
        try Data(invalid.utf8).write(to: project.appendingPathComponent(invalidID).appendingPathExtension("jsonl"))
    }

    let store = ClaudeNativeThreadStore(configRoot: config, maximumThreadResults: 1)
    let summaries = try await store.list(workingDirectory: workspace, limit: 1)
    #expect(summaries.map(\.id) == [validID])
}
