import SwiftUI

public struct FXDivider: View {
    let axis: Axis

    public init(_ axis: Axis = .horizontal) {
        self.axis = axis
    }

    public var body: some View {
        switch axis {
        case .horizontal:
            Rectangle()
                .fill(FXColors.border)
                .frame(height: 1)
        case .vertical:
            Rectangle()
                .fill(FXColors.border)
                .frame(width: 1)
        }
    }
}
