import SwiftUI
import FXDesign

struct ConversationView: View {
    @Bindable var agent: AgentInfo

    private let maxContentWidth: CGFloat = 920

    var body: some View {
        VStack(spacing: 0) {
            // Scrollable messages — centered with max width
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: FXSpacing.xxxl) {
                        if !agent.activities.isEmpty {
                            RuntimeActivityBar(activities: agent.activities, toolCallCount: agent.toolCallCount)
                        }

                        ForEach(agent.messages) { message in
                            MessageBubble(message: message)
                        }

                        if !agent.conversationState.streamingText.isEmpty {
                            MessageBubble(streamingText: agent.conversationState.streamingText)
                        } else if agent.isStreaming {
                            streamingIndicator
                        }

                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: maxContentWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, FXSpacing.xxl)
                    .padding(.top, FXSpacing.xxl)
                    .padding(.bottom, FXSpacing.md)
                }
                .scrollContentBackground(.hidden)
            }

            // Input bar — also centered
            ChatInputBar(agent: agent)
        }
        .background(FXColors.contentBg)
    }

    private var streamingIndicator: some View {
        HStack {
            HStack(spacing: FXSpacing.sm) {
                TypingIndicator()
            }
            .padding(.horizontal, FXSpacing.lg)
            .padding(.vertical, FXSpacing.md)
            .background(FXColors.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: FXRadii.xl))
            .overlay(
                RoundedRectangle(cornerRadius: FXRadii.xl)
                    .strokeBorder(FXColors.border, lineWidth: 0.5)
            )

            Spacer(minLength: 80)
        }
    }
}
