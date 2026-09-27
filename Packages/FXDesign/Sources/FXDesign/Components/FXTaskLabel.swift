import SwiftUI

/// Single-line sidebar task title. The provider is shown by the row's
/// `FXActivityDot` color (and its tooltip), so rows stay one line tall.
public struct FXTaskLabel: View {
    let title: String
    let isSelected: Bool

    public init(_ title: String, isSelected: Bool) {
        self.title = title
        self.isSelected = isSelected
    }

    public var body: some View {
        Text(title)
            .font(FXTypography.bodyMedium)
            .foregroundStyle(isSelected ? FXColors.fg : FXColors.fgSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .allowsTightening(true)
    }
}
