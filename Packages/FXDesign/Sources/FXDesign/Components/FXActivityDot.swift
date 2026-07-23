import SwiftUI

public enum FXActivityDotState: Equatable, Sendable {
    case idle
    case running
    case waiting
    case completed
    case error
}

/// A compact identity dot that can also communicate live activity without
/// adding a second badge or status label beside a title.
public struct FXActivityDot: View {
    private let color: Color
    private let state: FXActivityDotState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotation: Double = 0

    public init(color: Color, state: FXActivityDotState = .idle) {
        self.color = color
        self.state = state
    }

    public var body: some View {
        ZStack {
            statusRing

            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
        }
        .frame(width: 16, height: 16)
        .task(id: animationKey) {
            rotation = 0
            guard state == .running, !reduceMotion else { return }
            withAnimation(FXAnimation.activitySpin) {
                rotation = 360
            }
        }
    }

    @ViewBuilder
    private var statusRing: some View {
        switch state {
        case .idle:
            Circle()
                .fill(color.opacity(0.14))
                .frame(width: 13, height: 13)

        case .running:
            if reduceMotion {
                Circle()
                    .stroke(color.opacity(0.75), lineWidth: 1.5)
                    .frame(width: 14, height: 14)
            } else {
                Circle()
                    .trim(from: 0.08, to: 0.68)
                    .stroke(
                        color,
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                    )
                    .frame(width: 14, height: 14)
                    .rotationEffect(.degrees(rotation))
            }

        case .waiting:
            Circle()
                .stroke(FXColors.warning, lineWidth: 1.5)
                .frame(width: 14, height: 14)

        case .completed:
            Circle()
                .stroke(FXColors.success, lineWidth: 1.5)
                .frame(width: 14, height: 14)

        case .error:
            Circle()
                .stroke(FXColors.error, lineWidth: 1.5)
                .frame(width: 14, height: 14)
        }
    }

    private var animationKey: String {
        "\(state)-\(reduceMotion)"
    }
}
