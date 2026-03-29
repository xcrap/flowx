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
            HStack(spacing: FXSpacing.xxs) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Button(action: { withAnimation(FXAnimation.quick) { selectedTab = tab } }) {
                        Text(tab.rawValue)
                            .font(FXTypography.captionMedium)
                            .foregroundStyle(selectedTab == tab ? FXColors.fg : FXColors.fgTertiary)
                            .padding(.horizontal, FXSpacing.md)
                            .padding(.vertical, FXSpacing.xs)
                            .background(selectedTab == tab ? FXColors.bgSelected : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: FXRadii.sm))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, FXSpacing.lg)
            .padding(.vertical, FXSpacing.sm)

            FXDivider()

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
                    value: simplifiedProviderName(for: selectedProvider?.displayName ?? preferences.defaultProviderID)
                ) {
                    ForEach(providers, id: \.id) { provider in
                        Button(simplifiedProviderName(for: provider.displayName)) {
                            preferences.setDefaultProvider(provider.id, using: appState.providerRegistry)
                        }
                    }
                }

                settingsMenuRow(
                    "Model",
                    value: simplifiedModelName(for: selectedModel?.name ?? preferences.defaultModelID),
                    enabled: selectedProvider != nil
                ) {
                    ForEach(selectedProvider?.availableModels ?? [], id: \.id) { model in
                        Button(simplifiedModelName(for: model.name)) {
                            preferences.defaultModelID = model.id
                        }
                    }
                }

                settingsMenuRow("Effort", value: effortLabel(for: preferences.defaultEffort)) {
                    ForEach(["low", "medium", "high", "max"], id: \.self) { level in
                        Button(effortLabel(for: level)) {
                            preferences.defaultEffort = level
                        }
                    }
                }

                settingsNote("Applies when you create a new agent. Existing agents keep their own settings.")
            }
            settingsSection("Agent Defaults") {
                settingsMenuRow("Access Level", value: accessLabel(preferences.defaultAccess)) {
                    ForEach(AgentAccess.allCases, id: \.self) { access in
                        Button(accessLabel(access)) {
                            preferences.defaultAccess = access
                        }
                    }
                }

                settingsMenuRow("Agent Mode", value: modeLabel(preferences.defaultMode)) {
                    ForEach(AgentMode.allCases, id: \.self) { mode in
                        Button(modeLabel(mode)) {
                            preferences.defaultMode = mode
                        }
                    }
                }
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
                settingsMenuRow("Appearance", value: preferences.appearanceMode.label) {
                    ForEach(FXAppearanceMode.allCases, id: \.self) { mode in
                        Button(mode.label) {
                            preferences.appearanceMode = mode
                        }
                    }
                }

                accentColorRow
            }
            settingsSection("Interface") {
                settingsMenuRow("Text Size", value: preferences.textSizePreset.label) {
                    ForEach(FXTextSizePreset.allCases, id: \.self) { preset in
                        Button(preset.label) {
                            preferences.textSizePreset = preset
                        }
                    }
                }

                settingsNote("Text size updates the shell immediately.")
            }
        }
    }

    // MARK: - Shortcuts

    private var shortcutSettings: some View {
        VStack(alignment: .leading, spacing: FXSpacing.xl) {
            settingsSection("Navigation") {
                shortcutRow("Toggle Sidebar", shortcut: "⌘B")
                shortcutRow("Toggle Inspector", shortcut: "⌘\\")
                shortcutRow("Toggle Terminal", shortcut: "⌘`")
                shortcutRow("Jump to Agent 1-9", shortcut: "⌘1-9")
            }
            settingsSection("Actions") {
                shortcutRow("Command Palette", shortcut: "⌘⇧P")
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
        @ViewBuilder content: () -> some View
    ) -> some View {
        HStack {
            Text(label)
                .font(FXTypography.body)
                .foregroundStyle(FXColors.fgSecondary)
            Spacer()
            Menu {
                content()
            } label: {
                settingsValueLabel(value, enabled: enabled)
            }
            .menuStyle(.borderlessButton)
            .disabled(!enabled)
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

    private var accentColorRow: some View {
        HStack(alignment: .center, spacing: FXSpacing.md) {
            Text("Accent Color")
                .font(FXTypography.body)
                .foregroundStyle(FXColors.fgSecondary)

            Spacer()

            HStack(spacing: FXSpacing.sm) {
                ForEach(FXAccentColorOption.allCases, id: \.self) { option in
                    Button {
                        preferences.accentColor = option
                    } label: {
                        Circle()
                            .fill(option.color)
                            .frame(width: 18, height: 18)
                            .overlay {
                                Circle()
                                    .strokeBorder(
                                        preferences.accentColor == option ? FXColors.fg : FXColors.border,
                                        lineWidth: preferences.accentColor == option ? 2 : 1
                                    )
                            }
                    }
                    .buttonStyle(.plain)
                    .help(option.label)
                }

                Text(preferences.accentColor.label)
                    .font(FXTypography.body)
                    .foregroundStyle(FXColors.fg)
                    .padding(.leading, FXSpacing.xs)
            }
            .padding(.horizontal, FXSpacing.sm)
            .padding(.vertical, FXSpacing.xxs)
            .background(FXColors.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: FXRadii.xs))
        }
    }

    private func settingsValueLabel(_ value: String, enabled: Bool) -> some View {
        HStack(spacing: FXSpacing.xs) {
            Text(value)
                .font(FXTypography.body)
                .foregroundStyle(enabled ? FXColors.fg : FXColors.fgTertiary)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(enabled ? FXColors.fgTertiary : FXColors.fgQuaternary)
        }
        .padding(.horizontal, FXSpacing.sm)
        .padding(.vertical, FXSpacing.xxxs)
        .background(FXColors.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: FXRadii.xs))
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
}
