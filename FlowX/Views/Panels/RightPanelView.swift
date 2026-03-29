import SwiftUI
import FXDesign

struct RightPanelView: View {
    @Environment(AppState.self) private var appState

    private var gitInfo: GitStatusService.GitInfo? {
        appState.activeProject?.gitInfo
    }

    private var showsPushButton: Bool {
        appState.rightPanelTab == .changes && (gitInfo?.canPush == true)
    }

    var body: some View {
        @Bindable var state = appState

        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                ForEach(RightPanelTab.allCases, id: \.self) { tab in
                    tabButton(tab, isActive: appState.rightPanelTab == tab) {
                        withAnimation(FXAnimation.quick) {
                            appState.rightPanelTab = tab
                        }
                    }
                }
                Spacer()

                if showsPushButton {
                    FXButton("Push", icon: "arrow.up", style: .primary) {
                        Task { @MainActor in
                            await appState.pushActiveProject()
                        }
                    }
                    .padding(.trailing, FXSpacing.md)
                }
            }
            .padding(.leading, FXSpacing.md)
            .padding(.vertical, FXSpacing.xs)

            FXDivider()

            // Content
            switch appState.rightPanelTab {
            case .changes:
                ChangesPanel()
            case .files:
                FilesPanel()
            }
        }
        .background(FXColors.panelBg)
    }

    private func tabButton(_ tab: RightPanelTab, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(tab.rawValue)
                .font(FXTypography.captionMedium)
                .foregroundStyle(isActive ? FXColors.fg : FXColors.fgTertiary)
                .padding(.horizontal, FXSpacing.md)
                .padding(.vertical, FXSpacing.xs)
                .background(
                    isActive ? FXColors.bgSelected : .clear
                )
                .clipShape(RoundedRectangle(cornerRadius: FXRadii.sm))
        }
        .buttonStyle(.plain)
    }
}
