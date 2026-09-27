import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

public enum FXDropdownItemTone: Equatable {
    case standard
    case destructive
}

public struct FXDropdownItem: Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let isSelected: Bool
    public let isEnabled: Bool
    public let tone: FXDropdownItemTone
    public let action: () -> Void

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        isSelected: Bool = false,
        isEnabled: Bool = true,
        tone: FXDropdownItemTone = .standard,
        action: @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.tone = tone
        self.action = action
    }
}

public struct FXDropdownSection: Identifiable {
    public let id: String
    public let title: String?
    public let items: [FXDropdownItem]

    public init(id: String? = nil, title: String? = nil, items: [FXDropdownItem]) {
        self.id = id ?? UUID().uuidString
        self.title = title
        self.items = items
    }
}

private struct FXDropdownSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

private extension Notification.Name {
    static let fxDropdownDidOpen = Notification.Name("FXDropdown.didOpen")
}

/// Row highlight shared by pointer hover and keyboard navigation, so arrow
/// keys continue from wherever the pointer last was.
@Observable
@MainActor
private final class FXDropdownHighlight {
    var key: String?
}

public enum FXDropdownPlacement {
    case automatic
    case above
    case below
}

public enum FXDropdownAlignment {
    case leading
    case trailing
}

public struct FXDropdown<Label: View>: View {
    private let sections: [FXDropdownSection]
    private let enabled: Bool
    private let panelWidth: CGFloat?
    private let maxPanelHeight: CGFloat
    private let placement: FXDropdownPlacement
    private let alignment: FXDropdownAlignment
    private let onExpandedChange: ((Bool) -> Void)?
    private let label: (Bool) -> Label

    @State private var isExpanded = false
    @State private var labelSize: CGSize = .zero
    @State private var dropdownID = UUID()
    @State private var anchorBox = FXDropdownAnchorBox()
    @State private var presenter = FXDropdownPresenter()
    @State private var highlight = FXDropdownHighlight()

    public init(
        sections: [FXDropdownSection],
        enabled: Bool = true,
        panelWidth: CGFloat? = nil,
        maxPanelHeight: CGFloat = 320,
        placement: FXDropdownPlacement = .automatic,
        alignment: FXDropdownAlignment = .leading,
        onExpandedChange: ((Bool) -> Void)? = nil,
        @ViewBuilder label: @escaping (_ isExpanded: Bool) -> Label
    ) {
        self.sections = sections
        self.enabled = enabled
        self.panelWidth = panelWidth
        self.maxPanelHeight = maxPanelHeight
        self.placement = placement
        self.alignment = alignment
        self.onExpandedChange = onExpandedChange
        self.label = label
    }

    public var body: some View {
        Button(action: toggleExpanded) {
            label(isExpanded)
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .preference(key: FXDropdownSizeKey.self, value: proxy.size)
                    }
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .background(FXDropdownAnchorView(anchorBox: anchorBox))
        .onPreferenceChange(FXDropdownSizeKey.self) { labelSize = $0 }
        // Lets hover-revealed triggers stay visible while their panel is open;
        // moving into the panel (a child window) ends the row's hover.
        .onChange(of: isExpanded) { _, expanded in
            onExpandedChange?(expanded)
        }
        .onReceive(NotificationCenter.default.publisher(for: .fxDropdownDidOpen)) { notification in
            guard let otherID = notification.object as? UUID, otherID != dropdownID, isExpanded else { return }
            dismissDropdown()
        }
        .onDisappear(perform: dismissDropdown)
    }

    private var resolvedPanelWidth: CGFloat {
        max(panelWidth ?? 0, labelSize.width, 160)
    }

    private static func highlightKey(section: FXDropdownSection, item: FXDropdownItem) -> String {
        "\(section.id)|\(item.id)"
    }

    private var dropdownPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                        if let title = section.title, !title.isEmpty {
                            Text(title)
                                .font(FXTypography.caption)
                                .foregroundStyle(FXColors.fgTertiary)
                                .textCase(.uppercase)
                                .tracking(0.5)
                                .padding(.horizontal, FXSpacing.md)
                                .padding(.top, index == 0 ? FXSpacing.sm : FXSpacing.md)
                                .padding(.bottom, FXSpacing.xs)
                        }

                        ForEach(section.items) { item in
                            let key = Self.highlightKey(section: section, item: item)
                            FXDropdownRow(item: item, highlightKey: key, highlight: highlight) {
                                item.action()
                                dismissDropdown()
                            }
                            .id(key)
                        }

                        if index < sections.count - 1 {
                            FXDivider()
                                .padding(.horizontal, FXSpacing.md)
                                .padding(.vertical, FXSpacing.sm)
                        }
                    }
                }
                .padding(.vertical, FXSpacing.xs)
            }
            .scrollIndicators(.hidden)
            .onChange(of: highlight.key) { _, key in
                guard let key else { return }
                proxy.scrollTo(key)
            }
        }
        .frame(maxHeight: maxPanelHeight)
        .background(FXColors.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: FXRadii.xl))
        .overlay(
            RoundedRectangle(cornerRadius: FXRadii.xl)
                .strokeBorder(FXColors.borderMedium, lineWidth: 0.5)
        )
    }

    private func toggleExpanded() {
        guard enabled else { return }
        if isExpanded {
            dismissDropdown()
        } else {
            presentDropdown()
        }
    }

    private func presentDropdown() {
        guard let anchorView = anchorBox.view, anchorView.window != nil else { return }

        NotificationCenter.default.post(name: .fxDropdownDidOpen, object: dropdownID)
        isExpanded = true
        highlight.key = sections.lazy.flatMap { section in
            section.items.lazy
                .filter { $0.isSelected && $0.isEnabled }
                .map { Self.highlightKey(section: section, item: $0) }
        }.first
        let navigableItems = sections.flatMap { section in
            section.items.filter(\.isEnabled).map { (key: Self.highlightKey(section: section, item: $0), item: $0) }
        }
        presenter.present(
            anchorView: anchorView,
            width: resolvedPanelWidth,
            maxHeight: maxPanelHeight,
            placement: placement,
            alignment: alignment,
            content: AnyView(dropdownPanel.frame(width: resolvedPanelWidth, alignment: .leading)),
            onKeyDown: { keyCode in
                handleKey(keyCode, navigableItems: navigableItems)
            }
        ) {
            isExpanded = false
        }
    }

    private func dismissDropdown() {
        presenter.dismiss()
        isExpanded = false
    }

    /// ↑/↓ move the highlight across enabled rows, Return/Enter chooses it.
    /// Returns whether the key was consumed so it does not reach the view
    /// behind the panel (e.g. the composer).
    private func handleKey(
        _ keyCode: UInt16,
        navigableItems: [(key: String, item: FXDropdownItem)]
    ) -> Bool {
        guard !navigableItems.isEmpty else { return false }
        let currentIndex = highlight.key.flatMap { key in
            navigableItems.firstIndex { $0.key == key }
        }
        switch keyCode {
        case 125: // down arrow
            let next = currentIndex.map { min($0 + 1, navigableItems.count - 1) } ?? 0
            highlight.key = navigableItems[next].key
            return true
        case 126: // up arrow
            let previous = currentIndex.map { max($0 - 1, 0) } ?? navigableItems.count - 1
            highlight.key = navigableItems[previous].key
            return true
        case 36, 76: // return, keypad enter
            guard let currentIndex else { return false }
            navigableItems[currentIndex].item.action()
            dismissDropdown()
            return true
        default:
            return false
        }
    }
}

private struct FXDropdownRow: View {
    let item: FXDropdownItem
    let highlightKey: String
    let highlight: FXDropdownHighlight
    let action: () -> Void

    private var isHighlighted: Bool {
        item.isEnabled && highlight.key == highlightKey
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: FXSpacing.md) {
                VStack(alignment: .leading, spacing: item.subtitle == nil ? 0 : FXSpacing.xxxs) {
                    Text(item.title)
                        .font(FXTypography.body)
                        .foregroundStyle(titleColor)

                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(FXTypography.caption)
                            .foregroundStyle(FXColors.fgTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 0)

                if item.isSelected {
                    Image(systemName: "checkmark")
                        .font(FXTypography.icon(.small))
                        .foregroundStyle(FXColors.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, FXSpacing.md)
            .padding(.vertical, FXSpacing.sm)
            .background(isHighlighted ? FXColors.bgHover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.isEnabled)
        .onHover { hovering in
            if hovering, item.isEnabled {
                highlight.key = highlightKey
            } else if !hovering, highlight.key == highlightKey {
                highlight.key = nil
            }
        }
    }

    private var titleColor: Color {
        guard item.isEnabled else { return FXColors.fgTertiary }
        return item.tone == .destructive ? FXColors.error : FXColors.fg
    }
}

#if canImport(AppKit)
private final class FXDropdownAnchorBox {
    weak var view: NSView?
}

private struct FXDropdownAnchorView: NSViewRepresentable {
    let anchorBox: FXDropdownAnchorBox

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        anchorBox.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchorBox.view = nsView
    }
}

@MainActor
private final class FXDropdownPresenter {
    private weak var parentWindow: NSWindow?
    private weak var anchorView: NSView?
    private var panel: FXDropdownPanel?
    private var eventMonitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var onDismiss: (() -> Void)?
    private var onKeyDown: ((UInt16) -> Bool)?

    func present(
        anchorView: NSView,
        width: CGFloat,
        maxHeight: CGFloat,
        placement: FXDropdownPlacement,
        alignment: FXDropdownAlignment,
        content: AnyView,
        onKeyDown: @escaping (UInt16) -> Bool,
        onDismiss: @escaping () -> Void
    ) {
        close(notify: false)

        guard let window = anchorView.window else { return }

        self.parentWindow = window
        self.anchorView = anchorView
        self.onDismiss = onDismiss
        self.onKeyDown = onKeyDown

        let panel = FXDropdownPanel()
        let hostingController = NSHostingController(
            rootView: content
                .frame(width: width, alignment: .leading)
        )

        panel.contentViewController = hostingController
        hostingController.view.layoutSubtreeIfNeeded()

        let fittingSize = hostingController.view.fittingSize
        let panelSize = NSSize(
            width: width,
            height: min(maxHeight, max(44, fittingSize.height))
        )

        panel.setContentSize(panelSize)
        panel.setFrameOrigin(position(for: panelSize, placement: placement, alignment: alignment))

        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        // The window server derives the shadow from the rounded, transparent
        // content. A SwiftUI shadow would be clipped by the content-sized panel.
        panel.invalidateShadow()

        self.panel = panel
        installObservers()
        installEventMonitors()
    }

    func dismiss() {
        close(notify: false)
    }

    private func close(notify: Bool) {
        removeEventMonitors()
        removeObservers()

        if let panel {
            parentWindow?.removeChildWindow(panel)
            panel.orderOut(nil)
        }

        panel = nil
        anchorView = nil
        parentWindow = nil

        let dismissal = onDismiss
        onDismiss = nil
        onKeyDown = nil

        if notify {
            dismissal?()
        }
    }

    private func installObservers() {
        guard let parentWindow else { return }

        observers = [
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: parentWindow,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.close(notify: true)
                }
            },
            NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification,
                object: parentWindow,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.close(notify: true)
                }
            },
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: parentWindow,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.close(notify: true)
                }
            },
            NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.close(notify: true)
                }
            }
        ]
    }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    private func installEventMonitors() {
        let mouseMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let localMask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]

        if let localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: localMask,
            handler: { [weak self] event in
                guard let self else { return event }

                if event.type == .keyDown {
                    if event.keyCode == 53 {
                        MainActor.assumeIsolated {
                            self.close(notify: true)
                        }
                        return nil
                    }
                    let handled = MainActor.assumeIsolated {
                        self.onKeyDown?(event.keyCode) ?? false
                    }
                    if handled { return nil }
                }

                // Scrolling the content under an open panel would leave it
                // floating away from its trigger, so treat it like a click.
                let isDismissingEvent =
                    event.type == .leftMouseDown ||
                    event.type == .rightMouseDown ||
                    event.type == .otherMouseDown ||
                    event.type == .scrollWheel

                if isDismissingEvent, !self.containsMouseLocation(NSEvent.mouseLocation) {
                    MainActor.assumeIsolated {
                        self.close(notify: true)
                    }
                }

                return event
            }
        ) {
            eventMonitors.append(localMonitor)
        }

        if let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseMask, handler: { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.containsMouseLocation(NSEvent.mouseLocation) {
                    self.close(notify: true)
                }
            }
        }) {
            eventMonitors.append(globalMonitor)
        }
    }

    private func removeEventMonitors() {
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors.removeAll()
    }

    private func containsMouseLocation(_ screenPoint: NSPoint) -> Bool {
        if let panel, panel.frame.contains(screenPoint) {
            return true
        }

        guard let anchorView,
              let window = anchorView.window
        else { return false }

        let anchorRect = anchorView.convert(anchorView.bounds, to: nil)
        let screenRect = window.convertToScreen(anchorRect)
        return screenRect.contains(screenPoint)
    }

    private func position(
        for panelSize: NSSize,
        placement: FXDropdownPlacement,
        alignment: FXDropdownAlignment
    ) -> NSPoint {
        guard let anchorView,
              let window = anchorView.window
        else { return .zero }

        let anchorRect = window.convertToScreen(anchorView.convert(anchorView.bounds, to: nil))
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let horizontalMargin: CGFloat = 8
        let verticalGap = FXSpacing.sm

        let preferredX: CGFloat = switch alignment {
        case .leading:
            anchorRect.minX
        case .trailing:
            anchorRect.maxX - panelSize.width
        }

        let x = min(
            max(preferredX, visibleFrame.minX + horizontalMargin),
            visibleFrame.maxX - panelSize.width - horizontalMargin
        )

        let aboveY = anchorRect.maxY + verticalGap
        let belowY = anchorRect.minY - verticalGap - panelSize.height
        let clampedAboveY = min(aboveY, visibleFrame.maxY - panelSize.height - horizontalMargin)
        let clampedBelowY = max(belowY, visibleFrame.minY + horizontalMargin)
        let fitsAbove = aboveY + panelSize.height <= visibleFrame.maxY - horizontalMargin
        let fitsBelow = belowY >= visibleFrame.minY + horizontalMargin

        let y: CGFloat = switch placement {
        case .above:
            clampedAboveY
        case .below:
            clampedBelowY
        case .automatic:
            if fitsBelow {
                belowY
            } else if fitsAbove {
                aboveY
            } else {
                clampedAboveY
            }
        }

        return NSPoint(x: x, y: y)
    }
}

@MainActor
private final class FXDropdownPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        level = .floating
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
#endif
