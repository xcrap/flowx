import SwiftUI
import FXDesign
import FXAgent

struct RuntimeActivityBar: View {
    let activities: [ConversationRuntimeActivity]
    let toolCallCount: Int
    @State private var isExpanded = true

    private var completedTaskCount: Int {
        activities.filter(isCompleted).count
    }

    private var headerTitle: String {
        if toolCallCount > 0 {
            return toolCallCount == 1 ? "1 tool call" : "\(toolCallCount) tool calls"
        }

        if activities.count == 1, let summary = activities.first?.summary, !summary.isEmpty {
            return summary
        }

        return activities.count == 1 ? "1 runtime event" : "\(activities.count) runtime events"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Summary header
            Button(action: { withAnimation(FXAnimation.snappy) { isExpanded.toggle() } }) {
                HStack(spacing: FXSpacing.sm) {
                    Image(systemName: "gearshape.2")
                        .font(.system(size: 12))
                        .foregroundStyle(FXColors.fgTertiary)

                    Text(headerTitle)
                        .font(FXTypography.body)
                        .foregroundStyle(FXColors.fgSecondary)

                    if !isExpanded {
                        Text("·")
                            .foregroundStyle(FXColors.fgTertiary)
                        Text("\(completedTaskCount)/\(activities.count) complete")
                            .font(FXTypography.body)
                            .foregroundStyle(FXColors.fgSecondary)
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(FXColors.fgTertiary)
                }
                .padding(.horizontal, FXSpacing.lg)
                .padding(.vertical, FXSpacing.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide runtime activity" : "Show runtime activity")
            .accessibilityValue(headerTitle)
            .accessibilityHint("Shows recent tool calls and provider events for this conversation.")

            // Activity list
            if isExpanded {
                VStack(alignment: .leading, spacing: FXSpacing.xs) {
                    ForEach(activities) { activity in
                        activityRow(activity)
                    }
                }
                .padding(.horizontal, FXSpacing.lg)
                .padding(.bottom, FXSpacing.lg)
            }
        }
        .background(FXColors.bgSurface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: FXRadii.lg))
        .overlay(
            RoundedRectangle(cornerRadius: FXRadii.lg)
                .strokeBorder(FXColors.border, lineWidth: 0.5)
        )
    }

    private func activityRow(_ activity: ConversationRuntimeActivity) -> some View {
        VStack(alignment: .leading, spacing: FXSpacing.xxxs) {
            HStack(spacing: FXSpacing.md) {
                Image(systemName: iconName(for: activity))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(color(for: activity))
                    .frame(width: 18)

                Text(activity.summary)
                    .font(FXTypography.body)
                    .foregroundStyle(activity.tone == .success ? FXColors.fgSecondary : FXColors.fg)

                Spacer()
            }

            if let detail = activity.detail, !detail.isEmpty {
                Text(detail)
                    .font(FXTypography.caption)
                    .foregroundStyle(FXColors.fgTertiary)
                    .padding(.leading, 32)
            }
        }
        .padding(.vertical, FXSpacing.xxxs)
        .accessibilityElement(children: .combine)
    }

    private func iconName(for activity: ConversationRuntimeActivity) -> String {
        switch activity.tone {
        case .success:
            "checkmark.circle.fill"
        case .working:
            "circle.dotted"
        case .warning:
            "exclamationmark.triangle.fill"
        case .error:
            "xmark.circle.fill"
        case .info:
            "info.circle.fill"
        }
    }

    private func color(for activity: ConversationRuntimeActivity) -> Color {
        switch activity.tone {
        case .success:
            FXColors.success
        case .working:
            FXColors.accent
        case .warning:
            FXColors.warning
        case .error:
            FXColors.error
        case .info:
            FXColors.info
        }
    }

    private func isCompleted(_ activity: ConversationRuntimeActivity) -> Bool {
        activity.tone == .success || activity.state?.lowercased() == "completed"
    }
}
