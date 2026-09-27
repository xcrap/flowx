import AppKit
import SwiftUI
import Testing
@testable import FXDesign

/// A text view configured like the chat composer, with the composer's
/// delegate behavior: measure after every edit.
@MainActor
private final class ComposerHarness: NSObject, NSTextViewDelegate {
    let window: NSWindow
    let textView: NSTextView
    private(set) var measuredHeight: CGFloat = 0

    init(text: String, width: CGFloat = 640) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 120))
        scrollView.hasVerticalScroller = true
        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 28))
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 28)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        super.init()
        textView.delegate = self
        FXNativeTextStyle.applyBody(to: textView)
        scrollView.documentView = textView
        window.contentView = scrollView
        measure()
    }

    func measure() {
        measuredHeight = min(120, max(28, FXNativeTextStyle.contentHeight(of: textView) ?? 0))
    }

    func textDidChange(_ notification: Notification) {
        measure()
    }

    func type(_ text: String) {
        textView.insertText(text, replacementRange: textView.selectedRange())
    }
}

@Test @MainActor func nativeTextHeightFollowsEditsAndTextSize() {
    _ = NSApplication.shared
    let harness = ComposerHarness(text: "")
    #expect(harness.measuredHeight == 28)
    for _ in 0..<6 { harness.type("A line of text\n") }
    let sixLines = harness.measuredHeight
    #expect(sixLines > 28)

    let previousPreset = FXTheme.textSizePreset
    let signature = FXTheme.signature
    FXTheme.textSizePreset = previousPreset == .large ? .compact : .large
    defer { FXTheme.textSizePreset = previousPreset }
    #expect(FXTheme.signature != signature)
    FXNativeTextStyle.applyBody(to: harness.textView)
    harness.measure()
    #expect(harness.measuredHeight != sixLines)
}

/// Opt-in, optimized benchmark of composer keystrokes. Run with
/// `make benchmark-chat` and compare on the same Mac.
@Test(.enabled(if: ProcessInfo.processInfo.environment["FLOWX_BENCHMARK_CHAT"] == "1"))
@MainActor func benchmarkComposerKeystrokes() {
    _ = NSApplication.shared
    func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
    let line = "Please update the renderer so completed paragraphs stay cached while streaming.\n"
    for kilobytes in [1, 16, 64] {
        let prompt = String(repeating: line, count: kilobytes * 1_024 / line.utf8.count)
        let keystrokes = 100
        // Before: every SwiftUI update of the representable restyled all of
        // the text and measured it, on top of the measure in textDidChange.
        func run(restyleOnEveryUpdate: Bool) -> Duration {
            let harness = ComposerHarness(text: prompt)
            harness.textView.setSelectedRange(NSRange(location: (prompt as NSString).length, length: 0))
            var applied = FXTheme.signature
            let clock = ContinuousClock()
            let start = clock.now
            for _ in 0..<keystrokes {
                harness.type("x")
                if restyleOnEveryUpdate {
                    FXNativeTextStyle.applyBody(to: harness.textView)
                    harness.measure()
                } else if FXTheme.signature != applied {
                    applied = FXTheme.signature
                    FXNativeTextStyle.applyBody(to: harness.textView)
                    harness.measure()
                }
            }
            return start.duration(to: clock.now)
        }
        _ = run(restyleOnEveryUpdate: true)
        _ = run(restyleOnEveryUpdate: false)
        let before = run(restyleOnEveryUpdate: true)
        let after = run(restyleOnEveryUpdate: false)
        print(String(
            format: "COMPOSER BENCHMARK: %2d KB prompt, %d keystrokes: restyle + measure per update %.3f ms/keystroke; on change only %.3f ms/keystroke; %.1fx",
            kilobytes, keystrokes,
            milliseconds(before) / Double(keystrokes), milliseconds(after) / Double(keystrokes),
            milliseconds(before) / milliseconds(after)
        ))
    }
}
