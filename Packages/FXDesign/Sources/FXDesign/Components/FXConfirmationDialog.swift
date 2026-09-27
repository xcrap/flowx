import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Modal confirmation card shown over a dimmed backdrop. Escape cancels no
/// matter which view holds keyboard focus, and the destructive action needs a
/// deliberate click.
public struct FXConfirmationDialog: View {
    private let title: String
    private let message: String
    private let systemImage: String
    private let confirmTitle: String
    private let isDestructive: Bool
    private let onCancel: () -> Void
    private let onConfirm: () -> Void

    @State private var escapeMonitor = FXEscapeKeyMonitor()

    public init(
        title: String,
        message: String,
        systemImage: String,
        confirmTitle: String,
        isDestructive: Bool,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.confirmTitle = confirmTitle
        self.isDestructive = isDestructive
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    public var body: some View {
        ZStack {
            FXColors.overlay
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: FXSpacing.lg) {
                HStack(spacing: FXSpacing.md) {
                    Image(systemName: systemImage)
                        .font(FXTypography.icon(.large))
                        .foregroundStyle(isDestructive ? FXColors.error : FXColors.accent)

                    Text(title)
                        .font(FXTypography.title2)
                        .foregroundStyle(FXColors.fg)
                }

                Text(message)
                    .font(FXTypography.body)
                    .foregroundStyle(FXColors.fgSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: FXSpacing.sm) {
                    Spacer(minLength: 0)

                    FXButton("Cancel", style: .secondary, action: onCancel)
                        .keyboardShortcut(.cancelAction)

                    FXButton(confirmTitle, style: isDestructive ? .danger : .primary, action: onConfirm)
                }
            }
            .padding(FXSpacing.xl)
            .frame(width: FXLayout.modalWidth)
            .background(FXColors.bgElevated)
            .clipShape(RoundedRectangle(cornerRadius: FXRadii.xxl))
            .overlay(
                RoundedRectangle(cornerRadius: FXRadii.xxl)
                    .strokeBorder(FXColors.borderMedium, lineWidth: 0.5)
            )
            .shadow(color: FXColors.overlay, radius: 24, y: 14)
        }
        // Keyboard focus usually stays in whatever the person was using: a
        // text field eats Escape, and the terminal forwards it to the shell.
        // SwiftUI focus cannot reliably pull first responder from AppKit
        // views, so intercept Escape at the window level while shown.
        .onAppear {
            escapeMonitor.start(onEscape: onCancel)
        }
        .onDisappear {
            escapeMonitor.stop()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// Consumes Escape key presses app-wide while started. Used by modal surfaces
/// that must dismiss regardless of which AppKit view is first responder.
@MainActor
public final class FXEscapeKeyMonitor {
    private var monitor: Any?

    public init() {}

    public func start(onEscape: @escaping () -> Void) {
        stop()
        #if canImport(AppKit)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated {
                onEscape()
            }
            return nil
        }
        #endif
    }

    public func stop() {
        #if canImport(AppKit)
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        #endif
        monitor = nil
    }
}
