import SwiftUI
import FXDesign
import FXAgent
import FXCore

struct ChatInputBar: View {
    @Environment(AppState.self) private var appState
    @Bindable var agent: AgentInfo

    private let maxContentWidth: CGFloat = 920

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    if agent.conversationState.inputText.isEmpty {
                        Text("Ask to make changes...")
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
                        .lineSpacing(4)
                        .frame(minHeight: 28, maxHeight: 120)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, FXSpacing.xl)
                        .padding(.top, FXSpacing.lg)
                        .padding(.bottom, FXSpacing.sm)
                }

                if !agent.conversationState.pendingAttachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: FXSpacing.sm) {
                            ForEach(agent.conversationState.pendingAttachments) { attachment in
                                HStack(spacing: FXSpacing.xs) {
                                    Image(systemName: attachment.isImage ? "photo" : "doc")
                                        .font(.system(size: 11, weight: .medium))
                                    Text(attachment.filename)
                                        .font(FXTypography.caption)
                                        .lineLimit(1)
                                }
                                .foregroundStyle(FXColors.fgSecondary)
                                .padding(.horizontal, FXSpacing.sm)
                                .padding(.vertical, FXSpacing.xxs)
                                .background(FXColors.bgElevated)
                                .clipShape(RoundedRectangle(cornerRadius: FXRadii.sm))
                                .contextMenu {
                                    Button("Remove") {
                                        agent.conversationState.removeAttachment(attachment.id)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, FXSpacing.lg)
                        .padding(.bottom, FXSpacing.sm)
                    }
                }

                HStack(spacing: FXSpacing.sm) {
                    controlButton(icon: "paperclip", tooltip: "Attach files") {
                        appState.attachFiles(to: agent)
                    }

                    inlineDivider

                    menuControl(
                        text: providerAndModelLabel,
                        content: {
                            ForEach(providers, id: \.id) { provider in
                                Section(simplifiedProviderName(for: provider.displayName)) {
                                    ForEach(provider.availableModels, id: \.id) { model in
                                        Button(simplifiedModelName(for: model.name)) {
                                            agent.providerID = provider.id
                                            agent.modelID = model.id
                                        }
                                    }
                                }
                            }
                        }
                    )

                    inlineDivider

                    menuControl(
                        text: agent.effort.capitalized,
                        content: {
                            ForEach(["Low", "Medium", "High", "Max"], id: \.self) { level in
                                Button(level) { agent.effort = level.lowercased() }
                            }
                        }
                    )

                    inlineDivider

                    Button(action: {
                        withAnimation(FXAnimation.quick) {
                            agent.agentMode = agent.agentMode == .auto ? .plan : .auto
                        }
                    }) {
                        controlLabel(agent.agentMode == .plan ? "Plan" : "Chat", highlighted: agent.agentMode == .plan)
                    }
                    .buttonStyle(.plain)

                    inlineDivider

                    Button(action: {
                        withAnimation(FXAnimation.quick) {
                            agent.agentAccess = nextAccess(after: agent.agentAccess)
                        }
                    }) {
                        controlLabel(accessLabel(agent.agentAccess))
                    }
                    .buttonStyle(.plain)
                    .help("Cycle: Supervised → Accept Edits → Full Access")

                    Spacer()

                    Button(action: {
                        if agent.isStreaming {
                            appState.cancelPrompt(for: agent)
                        } else {
                            appState.sendPrompt(for: agent)
                        }
                    }) {
                        Image(systemName: agent.isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(sendButtonColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(!agent.isStreaming && agent.conversationState.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, FXSpacing.lg)
                .padding(.bottom, FXSpacing.md)
            }
            .background(FXColors.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: FXRadii.xl))
            .overlay(
                RoundedRectangle(cornerRadius: FXRadii.xl)
                    .strokeBorder(FXColors.border, lineWidth: 0.5)
            )
            .frame(maxWidth: maxContentWidth)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, FXSpacing.xxl)
        .padding(.top, FXSpacing.sm)
        .padding(.bottom, FXSpacing.xxl)
        .background(FXColors.contentBg)
    }

    private var providers: [any AIProvider] {
        appState.providerRegistry.allProviders.sorted { $0.displayName < $1.displayName }
    }

    private var currentProvider: (any AIProvider)? {
        providers.first(where: { $0.id == agent.providerID })
    }

    private var currentModel: AIModel? {
        currentProvider?.availableModels.first(where: { $0.id == agent.modelID })
    }

    private var providerAndModelLabel: String {
        let providerName = simplifiedProviderName(for: currentProvider?.displayName ?? agent.providerName)
        let modelName = simplifiedModelName(for: currentModel?.name ?? agent.modelID)

        if modelName.localizedCaseInsensitiveContains(providerName) {
            return modelName
        }

        return "\(providerName) \(modelName)"
    }

    private var sendButtonColor: Color {
        if agent.isStreaming {
            return FXColors.error
        }
        return agent.conversationState.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? FXColors.fgQuaternary
            : FXColors.accent
    }

    private var inlineDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 1, height: 14)
    }

    private func controlButton(icon: String, tooltip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(FXColors.fgTertiary)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    private func menuControl<Content: View>(text: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        Menu {
            content()
        } label: {
            controlLabel(text, isMenu: true)
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func controlLabel(_ text: String, highlighted: Bool = false, isMenu: Bool = false) -> some View {
        HStack(spacing: isMenu ? FXSpacing.md : FXSpacing.sm) {
            Text(text)
                .font(.system(size: 12, weight: .medium))
            if isMenu {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(FXColors.fgTertiary)
            }
        }
        .foregroundStyle(highlighted ? FXColors.accent : FXColors.fgSecondary)
        .padding(.horizontal, FXSpacing.sm)
        .padding(.vertical, FXSpacing.xxs)
    }

    private func nextAccess(after access: AgentAccess) -> AgentAccess {
        switch access {
        case .supervised:
            .acceptEdits
        case .acceptEdits:
            .fullAccess
        case .fullAccess:
            .supervised
        }
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

    private func simplifiedProviderName(for displayName: String) -> String {
        displayName
            .replacingOccurrences(of: " (via Claude Code)", with: "")
            .replacingOccurrences(of: " (OpenAI)", with: "")
    }

    private func simplifiedModelName(for modelName: String) -> String {
        modelName
            .replacingOccurrences(of: " (latest)", with: "")
    }
}
