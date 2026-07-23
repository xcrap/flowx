import SwiftUI

private struct ProjectDisclosureTransitionModifier: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: 1, y: progress, anchor: .top)
            .mask(alignment: .top) {
                Rectangle()
                    .scaleEffect(x: 1, y: progress, anchor: .top)
            }
    }
}

public extension AnyTransition {
    static var slideFromRight: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .trailing).combined(with: .opacity)
        )
    }

    static var slideFromBottom: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .move(edge: .bottom).combined(with: .opacity)
        )
    }

    static var fadeScale: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.95).combined(with: .opacity),
            removal: .scale(scale: 0.95).combined(with: .opacity)
        )
    }

    static var projectDisclosure: AnyTransition {
        .modifier(
            active: ProjectDisclosureTransitionModifier(progress: 0.001),
            identity: ProjectDisclosureTransitionModifier(progress: 1)
        )
    }
}
