#if canImport(AppKit)
import AppKit
import SwiftUI

/// FlowX body text for native `NSTextView` editors such as the composer.
/// Token values are copied into the view, so apply them again only when
/// `FXTheme.signature` changes: setting the font restyles and lays out all
/// of the text again.
@MainActor
public enum FXNativeTextStyle {
    public static func applyBody(to textView: NSTextView) {
        let baseFont = NSFont.systemFont(ofSize: FXTypography.bodyPointSize)
        let roundedDescriptor = baseFont.fontDescriptor.withDesign(.rounded)
            ?? baseFont.fontDescriptor
        textView.font = NSFont(
            descriptor: roundedDescriptor,
            size: FXTypography.bodyPointSize
        ) ?? baseFont
        textView.textColor = NSColor(FXColors.fg)
        textView.insertionPointColor = NSColor(FXColors.accent)
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(FXColors.accent).withAlphaComponent(0.28)
        ]
        textView.typingAttributes = [
            .font: textView.font ?? baseFont,
            .foregroundColor: NSColor(FXColors.fg)
        ]
    }

    /// Height of the text as laid out in the view's container, including the
    /// container inset. Completes any pending layout first.
    public static func contentHeight(of textView: NSTextView) -> CGFloat? {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        return ceil(
            layoutManager.usedRect(for: textContainer).height
                + textView.textContainerInset.height * 2
        )
    }
}
#endif
