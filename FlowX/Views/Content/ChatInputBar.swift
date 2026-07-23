import AppKit
import SwiftUI
import FXDesign
import FXAgent
import FXCore

struct ChatInputBar: View {
    @Environment(AppState.self) private var appState
    @Environment(AppPreferences.self) private var preferences
    @Bindable var agent: AgentInfo
    @FocusState private var composerFocused: Bool
    @State private var isDropTargeted = false
    @State private var attachmentFeedback: String?

    private let maxContentWidth: CGFloat = FXLayout.readableContentWidth

    private enum ComposerAction {
        case send
        case steer
        case queue
        case cancel
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    if agent.conversationState.inputText.isEmpty {
                        Text(composerPlaceholder)
                            .font(FXTypography.body)
                            .foregroundStyle(FXColors.fgTertiary)
                            .padding(.horizontal, FXSpacing.xl)
                            .padding(.top, FXSpacing.lg)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $agent.conversationState.inputText)
                        .scrollContentBackground(.hidden)
                        .font(FXTypography.body)
                        .foregroundStyle(FXColors.fg)
                        .lineSpacing(FXSpacing.xxs)
                        .frame(minHeight: 28, maxHeight: 120)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, FXSpacing.xl)
                        .padding(.top, FXSpacing.lg)
                        .padding(.bottom, FXSpacing.sm)
                        .focused($composerFocused)
                        .focusEffectDisabled()
                        .disabled(isSubmittingSteer)
                        .accessibilityLabel("Prompt input")
                        .accessibilityHint("Type a request for \(agent.title)")
                }

                if !agent.conversationState.pendingAttachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: FXSpacing.sm) {
                            ForEach(agent.conversationState.pendingAttachments) { attachment in
                                PendingAttachmentChip(attachment: attachment) {
                                    agent.conversationState.removeAttachment(attachment.id)
                                }
                            }
                        }
                        .padding(.horizontal, FXSpacing.lg)
                        .padding(.bottom, FXSpacing.sm)
                    }
                    .allowsHitTesting(!isSubmittingSteer)
                }

                if let attachmentFeedback {
                    Label(attachmentFeedback, systemImage: "exclamationmark.circle.fill")
                        .font(FXTypography.caption)
                        .foregroundStyle(FXColors.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, FXSpacing.lg)
                        .padding(.bottom, FXSpacing.sm)
                        .accessibilityLabel(attachmentFeedback)
                }

                HStack(spacing: FXSpacing.sm) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: FXSpacing.sm) {
                            controlButton(
                                icon: "paperclip",
                                tooltip: attachmentControlTooltip,
                                enabled: canAttachImages && !isSubmittingSteer
                            ) {
                                appState.attachFiles(to: agent)
                            }

                            controlButton(
                                icon: "doc.on.clipboard",
                                tooltip: canAttachImages ? "Attach image from clipboard (Command-Shift-V)" : attachmentControlTooltip,
                                enabled: canAttachImages && !isSubmittingSteer
                            ) {
                                pasteImageFromClipboard()
                            }
                            .keyboardShortcut("v", modifiers: [.command, .shift])

                            inlineDivider

                            menuControl(
                                text: providerLabel,
                                panelWidth: 180,
                                placement: .above,
                                enabled: !agent.isStreaming && !agent.isProviderNativeThread && !providers.isEmpty,
                                sections: providerSections
                            )

                            inlineDivider

                            menuControl(
                                text: modelLabel,
                                panelWidth: 220,
                                placement: .above,
                                enabled: !agent.isStreaming && currentProvider != nil,
                                sections: modelSections
                            )

                            inlineDivider

                            menuControl(
                                text: effortMenuLabel,
                                panelWidth: 160,
                                placement: .above,
                                enabled: !agent.isStreaming,
                                sections: effortSections
                            )

                            inlineDivider

                            menuControl(
                                text: modeMenuLabel,
                                panelWidth: 190,
                                placement: .above,
                                enabled: !agent.isStreaming,
                                sections: modeSections
                            )
                            .accessibilityLabel("Conversation mode")
                            .accessibilityValue(modeMenuLabel)

                            inlineDivider

                            menuControl(
                                text: accessMenuLabel,
                                panelWidth: 210,
                                placement: .above,
                                enabled: !agent.isStreaming,
                                sections: accessSections
                            )
                            .accessibilityLabel("Agent access")
                            .accessibilityValue(accessMenuLabel)
                        }
                    }

                    Button(action: {
                        switch composerAction {
                        case .send, .steer, .queue:
                            appState.sendPrompt(
                                for: agent,
                                followUpMode: preferences.defaultFollowUpMode
                            )
                        case .cancel:
                            appState.cancelPrompt(for: agent)
                        }
                    }) {
                        Image(systemName: composerIcon)
                            .font(FXTypography.icon(.action))
                            .foregroundStyle(sendButtonColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        (composerAction == .send && !hasDraftInput)
                            || hasUnsupportedAttachments
                            || isSubmittingSteer
                    )
                    .help(composerHelpText)
                    .accessibilityLabel(composerAccessibilityLabel)
                    .accessibilityHint(composerHelpText)
                }
                .padding(.horizontal, FXSpacing.lg)
                .padding(.bottom, FXSpacing.md)
            }
            .background(
                RoundedRectangle(cornerRadius: FXRadii.xl)
                    .fill(FXColors.bgSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: FXRadii.xl)
                    .strokeBorder(isDropTargeted ? FXColors.accent : FXColors.border, lineWidth: isDropTargeted ? 1.5 : 0.5)
            )
            .overlay(alignment: .topTrailing) {
                if isDropTargeted {
                    Label("Drop images to attach", systemImage: "photo.badge.plus")
                        .font(FXTypography.captionMedium)
                        .foregroundStyle(FXColors.accent)
                        .padding(.horizontal, FXSpacing.sm)
                        .padding(.vertical, FXSpacing.xxs)
                        .background(FXColors.bgElevated)
                        .clipShape(Capsule())
                        .padding(FXSpacing.sm)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard !isSubmittingSteer else { return false }
                return addDroppedImages(urls)
            } isTargeted: { targeted in
                isDropTargeted = targeted
            }
            .frame(maxWidth: maxContentWidth)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, FXSpacing.xxl)
        .padding(.top, FXSpacing.sm)
        .padding(.bottom, FXSpacing.xxl)
        .background(FXColors.contentBg)
        .onAppear(perform: focusComposer)
        .onChange(of: appState.activeAgentID) { _, newValue in
            guard newValue == agent.id else { return }
            focusComposer()
        }
    }

    private var providers: [any AIProvider] {
        appState.providerRegistry.allProviders.sorted { $0.displayName < $1.displayName }
    }

    private var currentProvider: (any AIProvider)? {
        providers.first(where: { $0.id == agent.providerID })
    }

    private var effectiveConfiguration: EffectiveAgentConfiguration {
        appState.effectiveConfiguration(for: agent)
    }

    private var inheritedConfiguration: EffectiveAgentConfiguration {
        appState.inheritedConfiguration(for: agent)
    }

    private var inheritedSettingTitle: String {
        agent.isProviderNativeThread ? "Task setting" : "App default"
    }

    private var currentModel: AIModel? {
        guard let modelID = effectiveConfiguration.modelID else { return nil }
        return currentProvider?.availableModels.first(where: { $0.id == modelID })
    }

    private var providerSections: [FXDropdownSection] {
        return [
            FXDropdownSection(
                items: providers.map { provider in
                    let runtimeAvailable = appState.runtimeHealth[provider.id]?.isUsable == true
                    return FXDropdownItem(
                        id: provider.id,
                        title: simplifiedProviderName(for: provider.displayName),
                        subtitle: !runtimeAvailable
                            ? "Runtime unavailable"
                            : provider.availableModels.isEmpty
                            ? "No models available"
                            : "\(provider.availableModels.count) \(provider.availableModels.count == 1 ? "model" : "models")",
                        isSelected: agent.providerID == provider.id,
                        isEnabled: runtimeAvailable && !provider.availableModels.isEmpty
                    ) {
                        selectProvider(provider)
                    }
                }
            )
        ]
    }

    private var modelSections: [FXDropdownSection] {
        let inherited = FXDropdownItem(
            id: "inherited-model",
            title: inheritedSettingTitle,
            subtitle: "Effective: \(modelName(for: inheritedConfiguration.modelID))",
            isSelected: agent.explicitModelID == nil
        ) {
            selectInheritedModel()
        }

        return [
            FXDropdownSection(
                items: [inherited] + (currentProvider?.availableModels ?? []).map { model in
                    FXDropdownItem(
                        id: model.id,
                        title: simplifiedModelName(for: model.name),
                        subtitle: model.supportsVision ? "Vision · \(formattedContextWindow(model.contextWindow)) context" : "\(formattedContextWindow(model.contextWindow)) context",
                        isSelected: agent.explicitModelID == model.id
                    ) {
                        selectModel(model)
                    }
                }
            )
        ]
    }

    private var effortSections: [FXDropdownSection] {
        [
            FXDropdownSection(
                items: [
                    FXDropdownItem(
                        id: "inherited-effort",
                        title: inheritedSettingTitle,
                        subtitle: "Effective: \(resolvedEffortLabel(inheritedConfiguration.effort))",
                        isSelected: agent.explicitEffort == nil
                    ) {
                        agent.explicitEffort = nil
                    }
                ] + supportedEfforts.map { level in
                    FXDropdownItem(
                        id: level,
                        title: effortLabel(for: level),
                        isSelected: agent.explicitEffort == level
                    ) {
                        agent.explicitEffort = level
                    }
                }
            )
        ]
    }

    private var modeSections: [FXDropdownSection] {
        [
            FXDropdownSection(
                items: [
                    FXDropdownItem(
                        id: "inherited-mode",
                        title: inheritedSettingTitle,
                        subtitle: "Effective: \(resolvedModeLabel(inheritedConfiguration.agentMode))",
                        isSelected: agent.explicitAgentMode == nil
                    ) {
                        agent.explicitAgentMode = nil
                    },
                    FXDropdownItem(
                        id: AgentMode.auto.rawValue,
                        title: "Chat",
                        subtitle: "Allow the agent to work normally",
                        isSelected: agent.explicitAgentMode == .auto
                    ) {
                        agent.explicitAgentMode = .auto
                    },
                    FXDropdownItem(
                        id: AgentMode.plan.rawValue,
                        title: "Plan",
                        subtitle: "Ask for a plan before making changes",
                        isSelected: agent.explicitAgentMode == .plan
                    ) {
                        agent.explicitAgentMode = .plan
                    },
                ]
            )
        ]
    }

    private var accessSections: [FXDropdownSection] {
        [
            FXDropdownSection(
                items: [
                    FXDropdownItem(
                        id: "inherited-access",
                        title: inheritedSettingTitle,
                        subtitle: "Effective: \(resolvedAccessLabel(inheritedConfiguration.agentAccess))",
                        isSelected: agent.explicitAgentAccess == nil
                    ) {
                        agent.explicitAgentAccess = nil
                    },
                    FXDropdownItem(
                        id: AgentAccess.supervised.rawValue,
                        title: "Supervised",
                        subtitle: "Ask before commands and edits",
                        isSelected: agent.explicitAgentAccess == .supervised
                    ) {
                        agent.explicitAgentAccess = .supervised
                    },
                    FXDropdownItem(
                        id: AgentAccess.acceptEdits.rawValue,
                        title: "Accept Edits",
                        subtitle: "Allow edits and review other actions",
                        isSelected: agent.explicitAgentAccess == .acceptEdits
                    ) {
                        agent.explicitAgentAccess = .acceptEdits
                    },
                    FXDropdownItem(
                        id: AgentAccess.fullAccess.rawValue,
                        title: "Full Access",
                        subtitle: "Auto-approve tools; questions still appear",
                        isSelected: agent.explicitAgentAccess == .fullAccess
                    ) {
                        agent.explicitAgentAccess = .fullAccess
                    },
                ]
            )
        ]
    }

    private var supportedEfforts: [String] {
        let advertised = currentModel?.supportedReasoningEfforts
            ?? currentProvider?.availableModels.flatMap(\.supportedReasoningEfforts)
            ?? []
        let uniqueAdvertised = advertised.reduce(into: [String]()) { result, effort in
            if !result.contains(effort) {
                result.append(effort)
            }
        }
        return uniqueAdvertised.isEmpty ? ["none", "low", "medium", "high", "xhigh"] : uniqueAdvertised
    }

    private var modelLabel: String {
        modelName(for: effectiveConfiguration.modelID)
    }

    private var effortMenuLabel: String {
        resolvedEffortLabel(effectiveConfiguration.effort)
    }

    private var modeMenuLabel: String {
        resolvedModeLabel(effectiveConfiguration.agentMode)
    }

    private var accessMenuLabel: String {
        resolvedAccessLabel(effectiveConfiguration.agentAccess)
    }

    private var providerLabel: String {
        simplifiedProviderName(for: currentProvider?.displayName ?? agent.providerName)
    }

    private var canAttachImages: Bool {
        if let currentModel {
            return currentModel.supportsVision
        }
        return currentProvider?.capabilities.supportedAttachments.contains(.image) == true
    }

    private var hasUnsupportedAttachments: Bool {
        !agent.conversationState.pendingAttachments.isEmpty && !canAttachImages
    }

    private var attachmentControlTooltip: String {
        canAttachImages ? "Attach images" : "The selected model does not support image attachments"
    }

    private var trimmedInput: String {
        agent.conversationState.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasDraftInput: Bool {
        !trimmedInput.isEmpty || !agent.conversationState.pendingAttachments.isEmpty
    }

    private var isSubmittingSteer: Bool {
        appState.isSubmittingSteer(for: agent.id)
    }

    private var composerAction: ComposerAction {
        if agent.isStreaming {
            guard hasDraftInput else { return .cancel }
            return preferences.defaultFollowUpMode == .steer ? .steer : .queue
        }
        return .send
    }

    private var composerPlaceholder: String {
        guard agent.isStreaming else { return "Ask to make changes..." }
        return preferences.defaultFollowUpMode == .steer
            ? "Steer the active run..."
            : "Queue a follow-up..."
    }

    private var composerIcon: String {
        return switch composerAction {
        case .send:
            "arrow.up.circle.fill"
        case .steer:
            "arrow.up.forward.circle.fill"
        case .queue:
            "plus.circle.fill"
        case .cancel:
            "stop.circle.fill"
        }
    }

    private var composerHelpText: String {
        if hasUnsupportedAttachments {
            return "Choose a vision-capable model or remove the image attachments"
        }

        return switch composerAction {
        case .send:
            "Send prompt (Command-Return or Control-Return)"
        case .steer:
            "Steer the active run (Command-Return) · Queue instead (Control-Return)"
        case .queue:
            "Queue after this turn (Command-Return) · Steer instead (Control-Return)"
        case .cancel:
            "Cancel current run"
        }
    }

    private var composerAccessibilityLabel: String {
        switch composerAction {
        case .send:
            "Send prompt"
        case .steer:
            "Steer active run"
        case .queue:
            "Queue prompt"
        case .cancel:
            "Cancel run"
        }
    }

    private var sendButtonColor: Color {
        switch composerAction {
        case .cancel:
            return FXColors.error
        case .steer:
            return FXColors.accent
        case .queue:
            return FXColors.info
        case .send:
            return hasDraftInput ? FXColors.accent : FXColors.fgQuaternary
        }
    }

    private var inlineDivider: some View {
        Rectangle()
            .fill(FXColors.borderSubtle)
            .frame(width: 1, height: 14)
    }

    private func controlButton(icon: String, tooltip: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(FXTypography.icon(.regular))
                .foregroundStyle(enabled ? FXColors.fgTertiary : FXColors.fgQuaternary)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(tooltip)
        .accessibilityLabel(tooltip)
    }

    private func menuControl(
        text: String,
        panelWidth: CGFloat? = nil,
        placement: FXDropdownPlacement = .automatic,
        enabled: Bool = true,
        sections: [FXDropdownSection]
    ) -> some View {
        FXDropdown(sections: sections, enabled: enabled, panelWidth: panelWidth, placement: placement) { isExpanded in
            controlLabel(text, isMenu: true, isExpanded: isExpanded)
        }
        .opacity(enabled ? 1 : 0.55)
        .fixedSize()
    }

    private func controlLabel(_ text: String, highlighted: Bool = false, isMenu: Bool = false, isExpanded: Bool = false) -> some View {
        HStack(spacing: isMenu ? FXSpacing.md : FXSpacing.sm) {
            Text(text)
                .font(FXTypography.icon(.regular))
            if isMenu {
                Image(systemName: "chevron.down")
                    .font(FXTypography.icon(.micro))
                    .foregroundStyle(FXColors.fgTertiary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
        }
        .foregroundStyle(highlighted ? FXColors.accent : FXColors.fgSecondary)
        .padding(.horizontal, FXSpacing.sm)
        .padding(.vertical, FXSpacing.xxs)
    }

    private func accessLabel(_ access: AgentAccess) -> String {
        switch access {
        case .supervised:
            "Supervised"
        case .acceptEdits:
            "Accept Edits"
        case .fullAccess:
            "Full Access"
        }
    }

    private func resolvedAccessLabel(_ access: AgentAccess?) -> String {
        access.map(accessLabel) ?? "Provider setting"
    }

    private func resolvedModeLabel(_ mode: AgentMode?) -> String {
        guard let mode else { return "Provider setting" }
        return mode == .plan ? "Plan" : "Chat"
    }

    private func modelName(for modelID: String?) -> String {
        guard let modelID else { return "Provider setting" }
        let advertisedName = currentProvider?.availableModels
            .first(where: { $0.id == modelID })?
            .name
        return simplifiedModelName(for: advertisedName ?? modelID)
    }

    private func resolvedEffortLabel(_ effort: String?) -> String {
        guard let effort else { return "Provider setting" }
        return effortLabel(for: effort)
    }

    private func simplifiedProviderName(for displayName: String) -> String {
        displayName
            .replacingOccurrences(of: " (OpenAI)", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func simplifiedModelName(for modelName: String) -> String {
        modelName
            .replacingOccurrences(of: " (latest)", with: "")
    }

    private func effortLabel(for value: String) -> String {
        switch value {
        case "low":
            "Low"
        case "medium":
            "Medium"
        case "high":
            "High"
        case "xhigh":
            "XHigh"
        default:
            value.capitalized
        }
    }

    private func selectProvider(_ provider: any AIProvider) {
        guard !agent.isStreaming,
              appState.runtimeHealth[provider.id]?.isUsable == true,
              let model = provider.availableModels.first else { return }

        if agent.providerID != provider.id {
            agent.providerID = provider.id
            agent.conversationState.sessionID = nil
            agent.conversationState.activeProviderID = provider.id
        }

        selectModel(model)
    }

    private func selectModel(_ model: AIModel) {
        guard !agent.isStreaming else { return }
        agent.explicitModelID = model.id
        agent.conversationState.activeModelID = model.id
        agent.conversationState.configuredContextWindow = model.contextWindow

        if let explicitEffort = agent.explicitEffort,
           !model.supportedReasoningEfforts.isEmpty,
           !model.supportedReasoningEfforts.contains(explicitEffort) {
            agent.explicitEffort = nil
        }
    }

    private func selectInheritedModel() {
        guard !agent.isStreaming else { return }
        agent.explicitModelID = nil
        let resolvedModelID = appState.effectiveConfiguration(for: agent).modelID
        agent.conversationState.activeModelID = resolvedModelID
        agent.conversationState.configuredContextWindow = resolvedModelID.flatMap { modelID in
            currentProvider?.availableModels
                .first(where: { $0.id == modelID })?
                .contextWindow
        }
    }

    private func formattedContextWindow(_ count: Int) -> String {
        if count >= 1_000_000 {
            return "\(count / 1_000_000)M"
        }
        if count >= 1_000 {
            return "\(count / 1_000)K"
        }
        return "\(count)"
    }

    private func addDroppedImages(_ urls: [URL]) -> Bool {
        guard !isSubmittingSteer, !urls.isEmpty else { return false }

        Task {
            if let message = await appState.attachFiles(at: urls, to: agent) {
                showAttachmentFeedback(message)
            } else {
                attachmentFeedback = nil
            }
        }

        return true
    }

    private func pasteImageFromClipboard() {
        guard !isSubmittingSteer else { return }
        guard canAttachImages else {
            showAttachmentFeedback("Choose a vision-capable model before attaching images.")
            return
        }

        let pasteboard = NSPasteboard.general
        if let data = pasteboard.data(forType: .png), !data.isEmpty {
            attachClipboardData(data, mimeType: "image/png", filename: "Pasted Image.png")
            return
        }

        if let tiffData = pasteboard.data(forType: .tiff), !tiffData.isEmpty {
            attachClipboardData(tiffData, mimeType: "image/tiff", filename: "Pasted Image.tiff")
            return
        }

        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], addDroppedImages(urls) {
            attachmentFeedback = nil
            return
        }

        showAttachmentFeedback("The clipboard does not contain a supported image.")
    }

    private func attachClipboardData(_ data: Data, mimeType: String, filename: String) {
        guard !isSubmittingSteer else { return }
        Task {
            if let message = await appState.attachImageData(
                data,
                mimeType: mimeType,
                filename: filename,
                to: agent
            ) {
                showAttachmentFeedback(message)
            } else {
                attachmentFeedback = nil
            }
        }
    }

    private func showAttachmentFeedback(_ message: String) {
        attachmentFeedback = message
        Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, attachmentFeedback == message else { return }
            attachmentFeedback = nil
        }
    }

    private func focusComposer() {
        Task { @MainActor in
            composerFocused = false
            await Task.yield()
            guard appState.activeAgentID == agent.id else { return }
            composerFocused = true
        }
    }
}

private struct PendingAttachmentChip: View {
    let attachment: Attachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: FXSpacing.sm) {
            AttachmentThumbnail(
                data: attachment.data,
                cacheKey: "composer-\(attachment.id.uuidString)",
                accessibilityLabel: attachment.filename
            )

            VStack(alignment: .leading, spacing: FXSpacing.xxxs) {
                Text(attachment.filename)
                    .font(FXTypography.captionMedium)
                    .foregroundStyle(FXColors.fgSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file))
                    .font(FXTypography.monoSmall)
                    .foregroundStyle(FXColors.fgTertiary)
            }

            FXIconButton(icon: "xmark", label: "Remove \(attachment.filename)", size: 24, action: onRemove)
        }
        .padding(.leading, FXSpacing.xxs)
        .padding(.trailing, FXSpacing.xs)
        .padding(.vertical, FXSpacing.xxs)
        .background(FXColors.bgElevated)
        .clipShape(RoundedRectangle(cornerRadius: FXRadii.md))
        .overlay(
            RoundedRectangle(cornerRadius: FXRadii.md)
                .strokeBorder(FXColors.borderSubtle, lineWidth: 0.5)
        )
        .contextMenu {
            Button("Remove", action: onRemove)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct AttachmentThumbnail: View {
    let data: Data
    let cacheKey: String
    let accessibilityLabel: String

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(FXTypography.icon(.regular))
                    .foregroundStyle(FXColors.fgTertiary)
            }
        }
        .frame(width: 34, height: 34)
        .background(FXColors.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: FXRadii.sm))
        .clipped()
        .accessibilityLabel("Image attachment: \(accessibilityLabel)")
        .task {
            guard image == nil, !data.isEmpty else { return }
            if let cached = AttachmentImageCache.image(for: cacheKey) {
                image = cached
                return
            }

            let sourceData = data
            let decoded = await AttachmentImageCache.loadDownsampledImage(
                from: sourceData,
                maxPixelSize: 96
            )
            guard !Task.isCancelled, let decoded else { return }
            image = AttachmentImageCache.store(decoded, for: cacheKey)
        }
    }
}
