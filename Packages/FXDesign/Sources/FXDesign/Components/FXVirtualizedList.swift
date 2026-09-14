import AppKit
import SwiftUI

/// A single scroll owner with fixed, caller-supplied row heights. Hosting views
/// are recycled by AppKit, so long code lists only instantiate visible rows.
public struct FXVirtualizedList<RowContent: View>: NSViewRepresentable {
    public let count: Int
    public let revision: AnyHashable
    public let contentWidth: CGFloat
    public let scrollTarget: Int?
    public let scrollRequest: AnyHashable?
    public let rowHeight: (Int) -> CGFloat
    public let copyText: (Int) -> String?
    public let rowContent: (Int) -> RowContent

    public init(
        count: Int,
        revision: AnyHashable,
        contentWidth: CGFloat,
        scrollTarget: Int?,
        scrollRequest: AnyHashable?,
        rowHeight: @escaping (Int) -> CGFloat,
        copyText: @escaping (Int) -> String?,
        @ViewBuilder rowContent: @escaping (Int) -> RowContent
    ) {
        self.count = count
        self.revision = revision
        self.contentWidth = contentWidth
        self.scrollTarget = scrollTarget
        self.scrollRequest = scrollRequest
        self.rowHeight = rowHeight
        self.copyText = copyText
        self.rowContent = rowContent
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(FXColors.panelBg)

        let table = CodeTableView()
        table.headerView = nil
        table.intercellSpacing = .zero
        table.style = .plain
        table.backgroundColor = NSColor(FXColors.panelBg)
        table.selectionHighlightStyle = .none
        table.allowsMultipleSelection = true
        table.usesAutomaticRowHeights = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.focusRingType = .none
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("content"))
        column.resizingMask = []
        table.addTableColumn(column)
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.copyRows = { [weak coordinator = context.coordinator] indexes in
            guard let coordinator else { return "" }
            return indexes.compactMap { coordinator.parent.copyText($0) }.joined(separator: "\n")
        }
        scroll.documentView = table
        context.coordinator.table = table
        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let table = coordinator.table else { return }
        let changed = coordinator.revision != revision
        let widthChanged = abs(table.tableColumns[0].width - contentWidth) > 0.5
        let requestedScroll = coordinator.scrollRequest != scrollRequest
        coordinator.parent = self
        coordinator.scrollRequest = scrollRequest
        if changed || widthChanged {
            let offset = scroll.contentView.bounds.origin
            coordinator.revision = revision
            table.tableColumns[0].width = max(1, contentWidth)
            // Avoid inheriting the panel's SwiftUI animation for thousands of rows.
            NSAnimationContext.runAnimationGroup { animation in
                animation.duration = 0
                table.reloadData()
                table.layoutSubtreeIfNeeded()
            }
            let maximumY = max(0, table.frame.height - scroll.contentSize.height)
            scroll.contentView.scroll(to: NSPoint(x: offset.x, y: min(offset.y, maximumY)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        if (requestedScroll || !coordinator.didScrollInitially), let scrollTarget,
           scrollTarget >= 0, scrollTarget < count {
            coordinator.didScrollInitially = true
            let target = table.rect(ofRow: scrollTarget)
            let maximumY = max(0, table.frame.height - scroll.contentSize.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(target.minY, maximumY)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    public static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.table?.delegate = nil
        coordinator.table?.dataSource = nil
        coordinator.table?.copyRows = nil
    }

    public final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: FXVirtualizedList
        var revision: AnyHashable?
        var scrollRequest: AnyHashable?
        var didScrollInitially = false
        weak var table: CodeTableView?

        init(_ parent: FXVirtualizedList) { self.parent = parent }

        public func numberOfRows(in tableView: NSTableView) -> Int { parent.count }

        public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            parent.rowHeight(row)
        }

        public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("row")
            if let view = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSHostingView<RowContent> {
                view.rootView = parent.rowContent(row)
                return view
            }
            let view = NSHostingView(rootView: parent.rowContent(row))
            view.identifier = identifier
            view.sizingOptions = []
            return view
        }
    }

    final class CodeTableView: NSTableView {
        var copyRows: ((IndexSet) -> String)?

        @objc func copy(_ sender: Any?) {
            let rows = selectedRowIndexes.isEmpty ? IndexSet(integersIn: 0..<numberOfRows) : selectedRowIndexes
            guard let text = copyRows?(rows), !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}
