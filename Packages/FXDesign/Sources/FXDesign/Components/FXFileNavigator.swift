import Foundation
import SwiftUI

public struct FXFileNavigatorItem: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let directory: String
    public let additions: Int
    public let deletions: Int

    public init(path: String, additions: Int = 0, deletions: Int = 0) {
        self.path = path
        name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        directory = parent.isEmpty || parent == "." ? "Project root" : parent
        self.additions = additions
        self.deletions = deletions
    }

    public func matches(_ query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy {
            path.localizedStandardContains(String($0))
        }
    }
}

/// An in-panel navigator keeps long paths, search and the current file visible.
public struct FXFileNavigator: View {
    private let items: [FXFileNavigatorItem]
    private let selectedPath: String?
    @Binding private var query: String
    private let onSelect: (String) -> Void

    public init(items: [FXFileNavigatorItem], selectedPath: String?, query: Binding<String>,
                onSelect: @escaping (String) -> Void) {
        self.items = items
        self.selectedPath = selectedPath
        _query = query
        self.onSelect = onSelect
    }

    public var body: some View {
        let matches = items.filter { $0.matches(query) }
        VStack(spacing: 0) {
            HStack(spacing: FXSpacing.xs) {
                Image(systemName: "magnifyingglass")
                    .font(FXTypography.icon(.small))
                    .foregroundStyle(FXColors.fgTertiary)
                TextField("Filter files…", text: $query)
                    .textFieldStyle(.plain)
                    .font(FXTypography.caption)
                    .foregroundStyle(FXColors.fg)
                    .accessibilityLabel("Filter changed files")
                    .onSubmit {
                        if let first = matches.first { onSelect(first.path) }
                    }
                if !query.isEmpty {
                    FXIconButton(icon: "xmark", label: "Clear file filter", size: 20) { query = "" }
                }
            }
            .padding(.horizontal, FXSpacing.sm)
            .frame(height: 32)
            .background(FXColors.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: FXRadii.sm))
            .padding(FXSpacing.sm)

            if matches.isEmpty {
                VStack(spacing: FXSpacing.xs) {
                    Text("No matching files")
                        .font(FXTypography.captionMedium)
                        .foregroundStyle(FXColors.fgSecondary)
                    Text("Try a filename or folder.")
                        .font(FXTypography.caption)
                        .foregroundStyle(FXColors.fgTertiary)
                }
                .padding(FXSpacing.lg)
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: FXSpacing.xxxs) {
                            ForEach(matches) { item in
                                FXFileNavigatorRow(item: item, isSelected: item.path == selectedPath) {
                                    onSelect(item.path)
                                }
                                .id(item.path)
                            }
                        }
                        .padding(.horizontal, FXSpacing.xs)
                        .padding(.bottom, FXSpacing.sm)
                    }
                    .onChange(of: selectedPath) { _, path in
                        if let path { proxy.scrollTo(path, anchor: .center) }
                    }
                }
            }
        }
        .background(FXColors.panelBg)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Changed files")
    }
}

private struct FXFileNavigatorRow: View {
    let item: FXFileNavigatorItem
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: FXSpacing.sm) {
                Image(systemName: "doc.text")
                    .font(FXTypography.icon(.regular))
                    .foregroundStyle(FXColors.fgTertiary)
                    .padding(.top, FXSpacing.xxxs)
                VStack(alignment: .leading, spacing: FXSpacing.xxxs) {
                    Text(item.name)
                        .font(FXTypography.captionMedium)
                        .foregroundStyle(isSelected ? FXColors.fg : FXColors.fgSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.directory)
                        .font(FXTypography.caption)
                        .foregroundStyle(FXColors.fgTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: FXSpacing.xxxs) {
                    if item.additions > 0 {
                        Text("+\(item.additions)").foregroundStyle(FXColors.diffAddedFg)
                    }
                    if item.deletions > 0 {
                        Text("−\(item.deletions)").foregroundStyle(FXColors.diffRemovedFg)
                    }
                }
                .font(FXTypography.monoSmall)
            }
            .padding(.horizontal, FXSpacing.sm)
            .padding(.vertical, FXSpacing.sm)
            .background(isSelected ? FXColors.bgSelected : (isHovered ? FXColors.bgHover : .clear))
            .clipShape(RoundedRectangle(cornerRadius: FXRadii.sm))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(item.path)
        .accessibilityLabel("Open diff for \(item.path)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
