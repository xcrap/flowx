import AppKit
import SwiftUI

/// A lightweight live resize handle. The parent can keep `onResizeChanged`
/// view-local and only persist the final value from `onResizeEnded`.
struct TerminalResizeHandle: View {
    static let height: CGFloat = 6

    let terminalHeight: CGFloat
    let minimumTerminalHeight: CGFloat
    let maximumTerminalHeight: CGFloat
    let backgroundColor: Color
    let lineColor: Color
    let hoverColor: Color
    let onResizeChanged: (CGFloat) -> Void
    let onResizeEnded: (CGFloat) -> Void
    let onResizeCancelled: () -> Void

    @State private var hovered = false
    @State private var dragStartHeight: CGFloat?

    var body: some View {
        ZStack(alignment: .top) {
            backgroundColor

            Rectangle()
                .fill(hovered ? hoverColor : lineColor)
                .frame(height: 1)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            hovered = hovering
            if hovering {
                NSCursor.resizeUpDown.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    let startHeight = dragStartHeight ?? terminalHeight
                    if dragStartHeight == nil {
                        dragStartHeight = startHeight
                    }
                    onResizeChanged(
                        resolvedHeight(startHeight - value.translation.height)
                    )
                }
                .onEnded { value in
                    let startHeight = dragStartHeight ?? terminalHeight
                    let finalHeight = resolvedHeight(
                        startHeight - value.translation.height
                    )
                    dragStartHeight = nil
                    onResizeEnded(finalHeight)
                }
        )
        .onDisappear {
            cancelActiveDrag()
            NSCursor.arrow.set()
        }
        .help("Resize terminal")
    }

    private func resolvedHeight(_ proposedHeight: CGFloat) -> CGFloat {
        min(
            max(proposedHeight, minimumTerminalHeight),
            maximumTerminalHeight
        )
    }

    private func cancelActiveDrag() {
        guard dragStartHeight != nil else { return }
        dragStartHeight = nil
        onResizeCancelled()
    }
}

/// Resizes the adjacent content live while allowing the parent to commit its
/// persistent width only once, after the pointer is released.
struct LiveHorizontalResizeHandle: View {
    let width: CGFloat
    let currentPanelWidth: CGFloat
    let minimumPanelWidth: CGFloat
    let maximumPanelWidth: CGFloat
    let lineColor: Color
    let hoverColor: Color
    let helpText: String
    let onResizeChanged: (CGFloat) -> Void
    let onResizeEnded: (CGFloat) -> Void
    let onResizeCancelled: () -> Void

    @State private var hovered = false
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: width)
            .overlay {
                Rectangle()
                    .fill(hovered ? hoverColor.opacity(0.8) : lineColor)
                    .frame(width: 1)
            }
            .contentShape(Rectangle())
            .background(hovered ? hoverColor.opacity(0.08) : .clear)
            .onHover { hovering in
                hovered = hovering
                if hovering {
                    NSCursor.resizeLeftRight.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        let startWidth = dragStartWidth ?? currentPanelWidth
                        if dragStartWidth == nil {
                            dragStartWidth = startWidth
                        }
                        onResizeChanged(
                            resolvedWidth(startWidth - value.translation.width)
                        )
                    }
                    .onEnded { value in
                        let startWidth = dragStartWidth ?? currentPanelWidth
                        let finalWidth = resolvedWidth(
                            startWidth - value.translation.width
                        )
                        dragStartWidth = nil
                        onResizeEnded(finalWidth)
                        if hovered {
                            NSCursor.resizeLeftRight.set()
                        } else {
                            NSCursor.arrow.set()
                        }
                    }
            )
            .onDisappear {
                cancelActiveDrag()
                NSCursor.arrow.set()
            }
            .help(helpText)
    }

    private func resolvedWidth(_ proposedWidth: CGFloat) -> CGFloat {
        min(
            max(proposedWidth, minimumPanelWidth),
            maximumPanelWidth
        )
    }

    private func cancelActiveDrag() {
        guard dragStartWidth != nil else { return }
        dragStartWidth = nil
        onResizeCancelled()
    }
}
