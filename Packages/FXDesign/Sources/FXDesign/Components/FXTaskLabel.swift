import SwiftUI

/// Sidebar task title with an always-visible provider, without shortening the
/// title to make room for a badge or changing the row's actions.
public struct FXTaskLabel: View {
    let title: String
    let provider: String
    let isSelected: Bool

    public init(_ title: String, provider: String, isSelected: Bool) {
        self.title = title
        self.provider = provider
        self.isSelected = isSelected
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: FXSpacing.xxxs) {
            Text(title)
                .font(FXTypography.bodyMedium)
                .foregroundStyle(isSelected ? FXColors.fg : FXColors.fgSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .allowsTightening(true)
            Text(provider)
                .font(FXTypography.overline)
                .foregroundStyle(FXColors.fgTertiary)
                .lineLimit(1)
        }
    }
}
