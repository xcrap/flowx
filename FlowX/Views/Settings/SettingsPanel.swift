import SwiftUI
import FXAgent
import FXCore
import FXDesign

struct SettingsPanel: View {
    @Environment(AppState.self) private var appState
    @Environment(AppPreferences.self) private var preferences
    @State private var selectedTab: SettingsTab = .general

    enum SettingsTab: String, CaseIterable {
        case general = "General"
        case providers = "Providers"
        case appearance = "Appearance"
        case shortcuts = "Shortcuts"

        var displayTitle: String {
            rawValue.uppercased()
        }
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

            // Tab bar
            HStack(spacing: FXSpacing.sm) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Button(action: { withAnimation(FXAnimation.quick) { selectedTab = tab } }) {
                        Text(tab.displayTitle)
                            .font(FXTypography.captionMedium)
                            .tracking(0.6)
                            .foregroundStyle(selectedTab == tab ? FXColors.fg : FXColors.fgTertiary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, FXSpacing.sm)
                            .padding(.vertical, FXSpacing.xs)
                            .background(selectedTab == tab ? FXColors.bgSelected : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: FXRadii.sm))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, FXSpacing.lg)
            .padding(.top, FXSpacing.md)
            .padding(.bottom, FXSpacing.md)

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: FXSpacing.xxl) {
                    switch selectedTab {
                    case .general: generalSettings
                    case .providers: providerSettings
                    case .appearance: appearanceSettings
                    case .shortcuts: shortcutSettings
                    }
                }
                .padding(FXSpacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(FXColors.panelBg)
    }

    // MARK: - General

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: FXSpacing.xl) {
            settingsSection("Default Provider") {
                settingsMenuRow(
                    "Provider",
                    value: simplifiedProviderName(for: selectedProvider?.displayName ?? preferences.defaultProviderID),
                    sections: [
                        FXDropdownSection(
                            items: providers.map { provider in
                                FXDropdownItem(
                                    id: provider.id,
                                    title: simplifiedProviderName(for: provider.displayName),
                                    isSelected: preferences.defaultProviderID == provider.id
                                ) {
                                    preferences.setDefaultProvider(provider.id, using: appState.providerRegistry)
                                }
                            }
                        )
                    ]
                )

                settingsMenuRow(
                    "Model",
                    value: simplifiedModelName(for: selectedModel?.name ?? preferences.defaultModelID),
                    enabled: selectedProvider != nil,
                    sections: [
                        FXDropdownSection(
                            items: (selectedProvider?.availableModels ?? []).map { model in
                                FXDropdownItem(
                                    id: model.id,
                                    title: simplifiedModelName(for: model.name),
                                    isSelected: preferences.defaultModelID == model.id
                                ) {
                                    preferences.defaultModelID = model.id
                                }
                            }
                        )
                    ]
                )

                settingsMenuRow(
                    "Effort",
                    value: effortLabel(for: preferences.defaultEffort),
                    sections: [
                        FXDropdownSection(
                            items: ["low", "medium", "high", "max"].map { level in
                                FXDropdownItem(
                                    id: level,
                                    title: effortLabel(for: level),
                                    isSelected: preferences.defaultEffort == level
                                ) {
                                    preferences.defaultEffort = level
                                }
                            }
                        )
                    ]
                )

                settingsNote("Applies when you create a new agent. Existing agents keep their own settings.")
            }
            settingsSection("Agent Defaults") {
                settingsMenuRow(
                    "Access Level",
                    value: accessLabel(preferences.defaultAccess),
                    sections: [
                        FXDropdownSection(
                            items: AgentAccess.allCases.map { access in
                                FXDropdownItem(
                                    id: access.rawValue,
                                    title: accessLabel(access),
                                    isSelected: preferences.defaultAccess == access
                                ) {
                                    preferences.defaultAccess = access
                                }
                            }
                        )
                    ]
                )

                settingsMenuRow(
                    "Agent Mode",
                    value: modeLabel(preferences.defaultMode),
                    sections: [
                        FXDropdownSection(
                            items: AgentMode.allCases.map { mode in
                                FXDropdownItem(
                                    id: mode.rawValue,
                                    title: modeLabel(mode),
                                    isSelected: preferences.defaultMode == mode
                                ) {
                                    preferences.defaultMode = mode
                                }
                            }
                        )
                    ]
                )
            }
        }
    }

    // MARK: - Providers

    private var providerSettings: some View {
        VStack(alignment: .leading, spacing: FXSpacing.xl) {
            providerRow(title: "Anthropic (Claude Code)", binaryID: "claude")
            providerRow(title: "OpenAI (Codex)", binaryID: "codex")
        }
    }

    // MARK: - Appearance

    private var appearanceSettings: some View {
        VStack(alignment: .leading, spacing: FXSpacing.xl) {
            settingsSection("Theme") {
                settingsMenuRow(
                    "Appearance",
                    value: preferences.appearanceMode.label,
                    panelWidth: 152,
                    sections: [
                        FXDropdownSection(
                            items: FXAppearanceMode.allCases.map { mode in
                                FXDropdownItem(
                                    id: mode.rawValue,
                                    title: mode.label,
                                    isSelected: preferences.appearanceMode == mode
                                ) {
                                    preferences.appearanceMode = mode
                                }
                            }
                        )
                    ]
                )

                settingsMenuRow(
                    "Accent Color",
                    value: preferences.accentColor.label,
                    panelWidth: 152,
                    sections: [
                        FXDropdownSection(
                            items: FXAccentColorOption.allCases.map { option in
                                FXDropdownItem(
                                    id: option.rawValue,
                                    title: option.label,
                                    isSelected: preferences.accentColor == option
                                ) {
                                    preferences.accentColor = option
                                }
                            }
                        )
                    ]
                )
            }
            settingsSection("Interface") {
                settingsMenuRow(
                    "Text Size",
                    value: textSizeLabel(preferences.textSizePreset),
                    panelWidth: 176,
                    sections: [
                        FXDropdownSection(
                            items: FXTextSizePreset.allCases.map { preset in
                                FXDropdownItem(
                                    id: preset.rawValue,
                                    title: textSizeLabel(preset),
                                    isSelected: preferences.textSizePreset == preset
                                ) {
                                    preferences.textSizePreset = preset
                                }
                            }
                        )
                    ]
                )

                settingsNote("Text size updates the shell immediately.")
            }
        }
    }

    // MARK: - Shortcuts

    private var shortcutSettings: some View {
        VStack(alignment: .leading, spacing: FXSpacing.xl) {
            settingsSection("Navigation") {
                shortcutRow("Toggle Sidebar", shortcut: "⌘B")
                shortcutRow("Toggle Git Panel", shortcut: "⌘G")
                shortcutRow("Toggle Browser Preview", shortcut: "⌘P")
                shortcutRow("Toggle Terminal", shortcut: "⌘T")
                shortcutRow("Jump to Agent 1-9", shortcut: "⌘1-9")
            }
            settingsSection("Actions") {
                shortcutRow("Command Palette", shortcut: "⌘K")
                shortcutRow("Send Prompt", shortcut: "⌘↩")
                shortcutRow("Settings", shortcut: "⌘,")
            }
        }
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
                settingsValueLabel(value, enabled: enabled, isExpanded: isExpanded)
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

        return settingsSection(title) {
            VStack(alignment: .leading, spacing: FXSpacing.sm) {
                HStack(spacing: FXSpacing.sm) {
                    Circle()
                        .fill(isAvailable ? FXColors.success : FXColors.error)
                        .frame(width: 8, height: 8)
                    Text(isAvailable ? "\(binaryID) CLI detected" : "\(binaryID) CLI not found")
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
    }

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

    private func settingsValueLabel(_ value: String, enabled: Bool, isExpanded: Bool) -> some View {
        HStack(spacing: FXSpacing.sm) {
            Text(value)
                .font(FXTypography.body)
                .foregroundStyle(enabled ? FXColors.fg : FXColors.fgTertiary)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(
                    enabled
                        ? (isExpanded ? FXColors.accent : FXColors.fgTertiary)
                        : FXColors.fgQuaternary
                )
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
        }
        .padding(.horizontal, FXSpacing.xxs)
        .padding(.vertical, FXSpacing.xxxs)
        .frame(minWidth: 0, alignment: .trailing)
        .contentShape(Rectangle())
    }

    private func settingsNote(_ text: String) -> some View {
        Text(text)
            .font(FXTypography.caption)
            .foregroundStyle(FXColors.fgTertiary)
    }

    private func simplifiedProviderName(for displayName: String) -> String {
        displayName
            .replacingOccurrences(of: "(via Claude Code)", with: "")
            .replacingOccurrences(of: "(OpenAI)", with: "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func simplifiedModelName(for name: String) -> String {
        name
            .replacingOccurrences(of: "(latest)", with: "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func effortLabel(for effort: String) -> String {
        effort.capitalized
    }

    private func modeLabel(_ mode: AgentMode) -> String {
        switch mode {
        case .auto:
            "Chat"
        case .plan:
            "Plan"
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

    private func textSizeLabel(_ preset: FXTextSizePreset) -> String {
        "\(preset.label) (\(Int((14 * preset.scale).rounded())) pt)"
    }
}
