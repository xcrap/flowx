import SwiftUI
import FXAgent
import FXCore
import FXDesign

struct SettingsPanel: View {
    @Environment(AppState.self) private var appState
    @Environment(AppPreferences.self) private var preferences

    // Keep SettingsTab type for API compat but we no longer use tabs
    enum SettingsTab: String, CaseIterable {
        case general, providers, appearance, shortcuts
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            Text("Settings")
                .font(FXTypography.title3)
                .foregroundStyle(FXColors.fg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, FXSpacing.lg)
                .frame(height: 52)

            FXDivider()

            // Single scrollable pane — everything in order
            ScrollView {
                VStack(alignment: .leading, spacing: FXSpacing.xxxl) {
                    // Defaults first — this is an AI app
                    settingsSection("Defaults") {
                        settingsMenuRow("Provider", value: simplifiedProviderName(for: selectedProvider?.displayName ?? preferences.defaultProviderID), sections: [
                            FXDropdownSection(items: providers.map { provider in
                                FXDropdownItem(id: provider.id, title: simplifiedProviderName(for: provider.displayName), isSelected: preferences.defaultProviderID == provider.id) {
                                    preferences.setDefaultProvider(provider.id, using: appState.providerRegistry)
                                }
                            })
                        ])

                        settingsMenuRow("Model", value: simplifiedModelName(for: selectedModel?.name ?? preferences.defaultModelID), enabled: selectedProvider != nil, sections: [
                            FXDropdownSection(items: (selectedProvider?.availableModels ?? []).map { model in
                                FXDropdownItem(id: model.id, title: simplifiedModelName(for: model.name), isSelected: preferences.defaultModelID == model.id) {
                                    preferences.defaultModelID = model.id
                                }
                            })
                        ])

                        settingsMenuRow("Effort", value: effortLabel(for: preferences.defaultEffort), sections: [
                            FXDropdownSection(items: ["low", "medium", "high", "max"].map { level in
                                FXDropdownItem(id: level, title: effortLabel(for: level), isSelected: preferences.defaultEffort == level) {
                                    preferences.defaultEffort = level
                                }
                            })
                        ])

                        settingsMenuRow("Access", value: accessLabel(preferences.defaultAccess), sections: [
                            FXDropdownSection(items: AgentAccess.allCases.map { access in
                                FXDropdownItem(id: access.rawValue, title: accessLabel(access), isSelected: preferences.defaultAccess == access) {
                                    preferences.defaultAccess = access
                                }
                            })
                        ])

                        settingsMenuRow("Mode", value: modeLabel(preferences.defaultMode), sections: [
                            FXDropdownSection(items: AgentMode.allCases.map { mode in
                                FXDropdownItem(id: mode.rawValue, title: modeLabel(mode), isSelected: preferences.defaultMode == mode) {
                                    preferences.defaultMode = mode
                                }
                            })
                        ])
                    }

                    // Appearance
                    settingsSection("Appearance") {
                        settingsMenuRow("Theme", value: preferences.appearanceMode.label, panelWidth: 152, sections: [
                            FXDropdownSection(items: FXAppearanceMode.allCases.map { mode in
                                FXDropdownItem(id: mode.rawValue, title: mode.label, isSelected: preferences.appearanceMode == mode) {
                                    preferences.appearanceMode = mode
                                }
                            })
                        ])

                        settingsMenuRow("Base Tone", value: preferences.baseTone.label, panelWidth: 140, sections: [
                            FXDropdownSection(items: FXBaseTone.allCases.map { tone in
                                FXDropdownItem(id: tone.rawValue, title: tone.label, isSelected: preferences.baseTone == tone) {
                                    preferences.baseTone = tone
                                }
                            })
                        ])

                        settingsMenuRow("Accent", value: preferences.accentColor.label, panelWidth: 152, sections: [
                            FXDropdownSection(items: FXAccentColorOption.allCases.map { option in
                                FXDropdownItem(id: option.rawValue, title: option.label, isSelected: preferences.accentColor == option) {
                                    preferences.accentColor = option
                                }
                            })
                        ])

                        settingsMenuRow("Text Size", value: textSizeLabel(preferences.textSizePreset), panelWidth: 176, sections: [
                            FXDropdownSection(items: FXTextSizePreset.allCases.map { preset in
                                FXDropdownItem(id: preset.rawValue, title: textSizeLabel(preset), isSelected: preferences.textSizePreset == preset) {
                                    preferences.textSizePreset = preset
                                }
                            })
                        ])
                    }

                    // Providers
                    settingsSection("Providers") {
                        providerRow(title: "Claude Code", binaryID: "claude")
                        providerRow(title: "Codex", binaryID: "codex")
                    }

                    // Shortcuts
                    settingsSection("Shortcuts") {
                        shortcutRow("Toggle Sidebar", shortcut: "⌘B")
                        shortcutRow("Toggle Git Panel", shortcut: "⌘G")
                        shortcutRow("Toggle Browser", shortcut: "⌘P")
                        shortcutRow("Toggle Terminal", shortcut: "⌘T")
                        shortcutRow("Command Palette", shortcut: "⌘K")
                        shortcutRow("Send Prompt", shortcut: "⌘↩")
                        shortcutRow("Settings", shortcut: "⌘,")
                    }
                }
                .padding(FXSpacing.lg)
                .padding(.bottom, FXSpacing.xxl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(FXColors.panelBg)
    }

    // MARK: - Helpers

    private func settingsSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: FXSpacing.md) {
            Text(title)
                .font(FXTypography.captionMedium)
                .foregroundStyle(FXColors.fgTertiary)
                .textCase(.uppercase)
                .tracking(0.5)
            content()
        }
    }

    private func settingsMenuRow(
        _ label: String,
        value: String,
        enabled: Bool = true,
        panelWidth: CGFloat = 160,
        sections: [FXDropdownSection]
    ) -> some View {
        HStack {
            Text(label)
                .font(FXTypography.body)
                .foregroundStyle(FXColors.fgSecondary)
            Spacer()
            FXDropdown(
                sections: sections,
                enabled: enabled,
                panelWidth: panelWidth,
                alignment: .trailing
            ) { isExpanded in
                HStack(spacing: FXSpacing.sm) {
                    Text(value)
                        .font(FXTypography.body)
                        .foregroundStyle(enabled ? FXColors.fg : FXColors.fgTertiary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(enabled ? (isExpanded ? FXColors.accent : FXColors.fgTertiary) : FXColors.fgQuaternary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
        }
    }

    private func shortcutRow(_ label: String, shortcut: String) -> some View {
        HStack {
            Text(label)
                .font(FXTypography.body)
                .foregroundStyle(FXColors.fgSecondary)
            Spacer()
            Text(shortcut)
                .font(FXTypography.monoSmall)
                .foregroundStyle(FXColors.fgTertiary)
                .padding(.horizontal, FXSpacing.sm)
                .padding(.vertical, FXSpacing.xxxs)
                .background(FXColors.bgSurface)
                .clipShape(RoundedRectangle(cornerRadius: FXRadii.xs))
        }
    }

    private func providerRow(title: String, binaryID: String) -> some View {
        let health = appState.runtimeHealth[binaryID]
        let isAvailable = health?.isUsable == true

        return VStack(alignment: .leading, spacing: FXSpacing.xs) {
            HStack(spacing: FXSpacing.sm) {
                Circle()
                    .fill(isAvailable ? FXColors.success : FXColors.error)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(FXTypography.body)
                    .foregroundStyle(FXColors.fgSecondary)
                Spacer()
                Text(health?.statusLabel ?? "Checking…")
                    .font(FXTypography.monoSmall)
                    .foregroundStyle(FXColors.fgTertiary)
            }
            if let path = health?.path {
                Text(path)
                    .font(FXTypography.monoSmall)
                    .foregroundStyle(FXColors.fgTertiary)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Data

    private var providers: [any AIProvider] {
        appState.providerRegistry.allProviders.sorted { $0.displayName < $1.displayName }
    }

    private var selectedProvider: (any AIProvider)? {
        providers.first(where: { $0.id == preferences.defaultProviderID }) ?? providers.first
    }

    private var selectedModel: AIModel? {
        selectedProvider?.availableModels.first(where: { $0.id == preferences.defaultModelID })
            ?? selectedProvider?.availableModels.first
    }

    private func simplifiedProviderName(for name: String) -> String {
        name.replacingOccurrences(of: "(via Claude Code)", with: "")
            .replacingOccurrences(of: "(OpenAI)", with: "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func simplifiedModelName(for name: String) -> String {
        name.replacingOccurrences(of: "(latest)", with: "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func effortLabel(for effort: String) -> String { effort.capitalized }

    private func modeLabel(_ mode: AgentMode) -> String {
        switch mode { case .auto: "Chat"; case .plan: "Plan" }
    }

    private func accessLabel(_ access: AgentAccess) -> String {
        switch access { case .supervised: "Supervised"; case .acceptEdits: "Accept Edits"; case .fullAccess: "Full Access" }
    }

    private func textSizeLabel(_ preset: FXTextSizePreset) -> String {
        "\(preset.label) (\(Int((14 * preset.scale).rounded())) pt)"
    }
}
