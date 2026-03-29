import SwiftUI
import FXDesign

struct SettingsPanel: View {
    @Environment(AppState.self) private var appState
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
                settingsRow("Provider", value: "Claude Code")
                settingsRow("Model", value: "Sonnet (latest)")
                settingsRow("Effort", value: "High")
            }
            settingsSection("Agent Defaults") {
                settingsRow("Access Level", value: "Full Access")
                settingsRow("Agent Mode", value: "Auto")
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
                settingsRow("Appearance", value: "Dark")
                settingsRow("Accent Color", value: "Purple")
            }
            settingsSection("Editor") {
                settingsRow("Font Size", value: "14px")
                settingsRow("Line Height", value: "1.6")
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
                shortcutRow("Command Palette", shortcut: "⌘K")
                shortcutRow("New Agent", shortcut: "⌘N")
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

    private func settingsRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(FXTypography.body)
                .foregroundStyle(FXColors.fgSecondary)
            Spacer()
            Text(value)
                .font(FXTypography.body)
                .foregroundStyle(FXColors.fg)
                .padding(.horizontal, FXSpacing.sm)
                .padding(.vertical, FXSpacing.xxxs)
                .background(FXColors.bgSurface)
                .clipShape(RoundedRectangle(cornerRadius: FXRadii.xs))
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
}
