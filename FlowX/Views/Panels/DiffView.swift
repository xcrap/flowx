import SwiftUI
import FXDesign

struct DiffView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: FXSpacing.sm) {
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                    .foregroundStyle(FXColors.fgTertiary)
                Text(appState.activeProject?.selectedInspectorPath ?? "No file selected")
                    .font(FXTypography.captionMedium)
                    .foregroundStyle(FXColors.fgSecondary)
                Spacer()
            }
            .padding(.horizontal, FXSpacing.md)
            .padding(.vertical, FXSpacing.sm)
            .background(FXColors.bgElevated)

            FXDivider()

            ScrollView {
                Text(diffText)
                    .font(FXTypography.mono)
                    .foregroundStyle(FXColors.fgSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(FXSpacing.md)
            }
            .background(FXColors.bg)
        }
    }

    private var diffText: String {
        let text = appState.activeProject?.selectedInspectorText ?? ""
        return text.isEmpty ? "Select a changed file or repository file to inspect it." : text
    }
}
