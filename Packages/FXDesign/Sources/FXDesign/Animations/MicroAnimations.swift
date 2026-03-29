import SwiftUI

public enum FXAnimation {
    public static let snappy = Animation.spring(duration: 0.25, bounce: 0.0)
    public static let gentle = Animation.spring(duration: 0.35, bounce: 0.15)
    public static let quick = Animation.easeOut(duration: 0.15)
    public static let smooth = Animation.easeInOut(duration: 0.3)
    public static let panel = Animation.spring(duration: 0.3, bounce: 0.0)
    public static let micro = Animation.easeOut(duration: 0.1)
}

// MARK: - Pulsing status indicator

public struct PulsingDot: View {
    let color: Color
    @State private var pulse = false

    public init(color: Color) {
        self.color = color
    }

    public var body: some View {
        ZStack {
            // Outer glow ring — slow, smooth breathe
            Circle()
                .fill(color.opacity(pulse ? 0.0 : 0.35))
                .frame(width: pulse ? 18 : 8, height: pulse ? 18 : 8)

            // Inner dot — gentle brightness breathe
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .opacity(pulse ? 0.7 : 1.0)
        }
        .frame(width: 18, height: 18)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

// MARK: - Typing indicator (for streaming in conversation view)

public struct TypingIndicator: View {
    @State private var phase: Int = 0

    public init() {}

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(FXColors.fgTertiary)
                    .frame(width: 4, height: 4)
                    .opacity(phase == i ? 1.0 : 0.3)
                    .scaleEffect(phase == i ? 1.2 : 1.0)
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(350))
                withAnimation(.easeInOut(duration: 0.3)) {
                    phase = (phase + 1) % 3
                }
            }
        }
    }
}
