import SwiftUI

public struct FXSegmentedOption<Value: Hashable>: Identifiable {
    public let id: Value
    public let title: String

    public init(_ id: Value, title: String) {
        self.id = id
        self.title = title
    }
}

/// Flat, directly accessible choices for compact FlowX toolbars.
public struct FXSegmentedControl<Value: Hashable>: View {
    private let options: [FXSegmentedOption<Value>]
    @Binding private var selection: Value
    private let label: String

    public init(_ label: String, options: [FXSegmentedOption<Value>], selection: Binding<Value>) {
        self.label = label
        self.options = options
        _selection = selection
    }

    public var body: some View {
        HStack(spacing: FXSpacing.xxxs) {
            ForEach(options) { option in
                Button { selection = option.id } label: {
                    Text(option.title)
                        .font(FXTypography.captionMedium)
                        .foregroundStyle(selection == option.id ? FXColors.fg : FXColors.fgTertiary)
                        .padding(.horizontal, FXSpacing.sm)
                        .frame(height: 24)
                        .background(selection == option.id ? FXColors.bgSelected : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: FXRadii.xs))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == option.id ? .isSelected : [])
            }
        }
        .padding(FXSpacing.xxxs)
        .background(FXColors.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: FXRadii.sm))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .fixedSize()
    }
}
