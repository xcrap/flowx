import SwiftUI

public struct FXCard<Content: View>: View {
    let content: Content
    let padding: CGFloat

    public init(padding: CGFloat = FXSpacing.md, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .background(FXColors.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: FXRadii.lg))
            .overlay(
                RoundedRectangle(cornerRadius: FXRadii.lg)
                    .strokeBorder(FXColors.border, lineWidth: 0.5)
            )
    }
}
