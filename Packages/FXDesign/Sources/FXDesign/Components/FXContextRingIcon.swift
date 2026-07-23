import SwiftUI

/// A compact filled action button wrapped by a separate context-usage ring.
public struct FXContextRingIcon: View {
    private let icon: String
    private let progress: Double?
    private let tint: Color
    private let size: CGFloat

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    public init(
        icon: String,
        progress: Double?,
        tint: Color,
        size: CGFloat = 36
    ) {
        self.icon = icon
        self.progress = progress.map { min(max($0, 0), 1) }
        self.tint = tint
        self.size = size
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(FXColors.borderMedium, lineWidth: 1.5)

            if let progress, progress > 0 {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        progressColor,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }

            Circle()
                .fill(buttonFill)
                .frame(width: size - 8, height: size - 8)

            Image(systemName: icon)
                .font(FXTypography.icon(.control))
                .foregroundStyle(isEnabled ? FXColors.onAccent : FXColors.fgQuaternary)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .onHover { isHovered = $0 }
    }

    private var buttonFill: Color {
        guard isEnabled else { return FXColors.bgHover }
        return isHovered ? tint.opacity(0.86) : tint
    }

    private var progressColor: Color {
        guard let progress else { return FXColors.accent }
        if progress >= 0.9 { return FXColors.error }
        if progress >= 0.75 { return FXColors.warning }
        return FXColors.accent
    }
}
