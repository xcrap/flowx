import AppKit
import SwiftUI

/// Replaces AppKit's expansive read-only text menu with the three transcript actions
/// people use, while leaving editable fields such as the composer untouched.
struct TranscriptSelectionMenuLimiter: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(to: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        private weak var scopeView: NSView?
        private weak var selectedTextView: NSTextView?
        private var selectedText = ""
        private var eventMonitor: Any?

        override init() {
            super.init()
            startObserving()
        }

        func attach(to view: NSView) {
            scopeView = view
            startObserving()
        }

        func detach() {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
            eventMonitor = nil
            scopeView = nil
            selectedTextView = nil
            selectedText = ""
        }

        private func startObserving() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
                guard let self,
                      self.presentCompactMenu(for: event) else {
                    return event
                }
                return nil
            }
        }

        private func presentCompactMenu(for event: NSEvent) -> Bool {
            guard let scopeView,
                  let window = scopeView.window,
                  window.isKeyWindow,
                  event.window === window,
                  let textView = selectedReadOnlyTextView(in: window),
                  let text = selectedString(in: textView),
                  !text.isEmpty else {
                return false
            }

            selectedTextView = textView
            selectedText = text

            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.addItem(
                item(
                    title: "Look Up “\(abbreviated(text))”",
                    action: #selector(lookUpSelection)
                )
            )
            menu.addItem(
                item(
                    title: "Search With Google",
                    action: #selector(searchSelection)
                )
            )
            menu.addItem(
                item(
                    title: "Copy",
                    action: #selector(copySelection),
                    keyEquivalent: "c"
                )
            )
            menu.popUp(
                positioning: nil,
                at: event.locationInWindow,
                in: window.contentView
            )
            return true
        }

        private func item(
            title: String,
            action: Selector,
            keyEquivalent: String = ""
        ) -> NSMenuItem {
            let item = NSMenuItem(
                title: title,
                action: action,
                keyEquivalent: keyEquivalent
            )
            item.target = self
            item.isEnabled = true
            return item
        }

        private func selectedReadOnlyTextView(in window: NSWindow) -> NSTextView? {
            if let textView = window.firstResponder as? NSTextView,
               !textView.isEditable,
               textView.selectedRange().length > 0 {
                return textView
            }

            guard let contentView = window.contentView else { return nil }
            return selectedReadOnlyTextView(in: contentView)
        }

        private func selectedReadOnlyTextView(in view: NSView) -> NSTextView? {
            if let textView = view as? NSTextView,
               !textView.isEditable,
               textView.selectedRange().length > 0 {
                return textView
            }

            for subview in view.subviews.reversed() {
                if let match = selectedReadOnlyTextView(in: subview) {
                    return match
                }
            }
            return nil
        }

        private func selectedString(in textView: NSTextView) -> String? {
            let range = textView.selectedRange()
            guard range.location != NSNotFound,
                  range.length > 0,
                  NSMaxRange(range) <= textView.string.utf16.count else {
                return nil
            }

            return (textView.string as NSString)
                .substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private func abbreviated(_ text: String) -> String {
            let collapsed = text
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            guard collapsed.count > 28 else { return collapsed }
            return "\(collapsed.prefix(27))…"
        }

        @objc private func lookUpSelection() {
            guard let selectedTextView else { return }
            selectedTextView.showDefinition(
                for: nil,
                range: selectedTextView.selectedRange(),
                options: nil,
                baselineOriginProvider: nil
            )
        }

        @objc private func searchSelection() {
            guard !selectedText.isEmpty,
                  var components = URLComponents(string: "https://www.google.com/search") else {
                return
            }
            components.queryItems = [URLQueryItem(name: "q", value: selectedText)]
            guard let url = components.url else { return }
            NSWorkspace.shared.open(url)
        }

        @objc private func copySelection() {
            guard !selectedText.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(selectedText, forType: .string)
        }
    }
}
