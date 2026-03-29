import SwiftUI
import FXDesign

struct FilesPanel: View {
    @Environment(AppState.self) private var appState
    @State private var searchText = ""
    @State private var expandedPaths: Set<String> = []

    var body: some View {
        if let project = appState.activeProject {
            let tree = buildTree(from: project.repositoryFiles)
            let visibleTree = filteredTree(tree, query: searchQuery)

            VStack(spacing: 0) {
                searchBar
                FXDivider()

                if visibleTree.isEmpty {
                    emptyState(for: project)
                } else {
                    ScrollView {
                        LazyVStack(spacing: FXSpacing.xxs) {
                            ForEach(visibleTree) { node in
                                FilesTreeRow(
                                    node: node,
                                    depth: 0,
                                    selectedPath: project.selectedInspectorPath,
                                    forceExpanded: !searchQuery.isEmpty,
                                    expandedPaths: $expandedPaths
                                ) { path in
                                    appState.selectInspectorPath(path, for: project)
                                }
                            }
                        }
                        .padding(.horizontal, FXSpacing.sm)
                        .padding(.vertical, FXSpacing.sm)
                    }
                    .background(FXColors.bg)
                }
            }
            .onAppear {
                seedExpandedPaths(from: tree, selectedPath: project.selectedInspectorPath)
            }
            .onChange(of: project.selectedInspectorPath) { _, selectedPath in
                expandAncestors(of: selectedPath)
            }
        } else {
            emptyState(title: "No project selected", body: "Choose a project to browse its files.")
        }
    }

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchBar: some View {
        HStack(spacing: FXSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(FXColors.fgTertiary)

            TextField("Search files", text: $searchText)
                .textFieldStyle(.plain)
                .font(FXTypography.caption)
                .foregroundStyle(FXColors.fgSecondary)

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(FXColors.fgQuaternary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, FXSpacing.md)
        .padding(.vertical, FXSpacing.sm)
        .background(FXColors.bgElevated)
    }

    @ViewBuilder
    private func emptyState(for project: ProjectState) -> some View {
        if project.repositoryFiles.isEmpty {
            emptyState(
                title: "No files indexed",
                body: "This project is empty or the visible files are being skipped from the inspector."
            )
        } else {
            emptyState(
                title: "No matches",
                body: "Try a different search term or clear the filter to browse the full file tree."
            )
        }
    }

    private func emptyState(title: String, body: String) -> some View {
        VStack(spacing: FXSpacing.md) {
            Image(systemName: "folder")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(FXColors.fgTertiary)

            VStack(spacing: FXSpacing.xs) {
                Text(title)
                    .font(FXTypography.bodyMedium)
                    .foregroundStyle(FXColors.fgSecondary)

                Text(body)
                    .font(FXTypography.caption)
                    .foregroundStyle(FXColors.fgTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 220)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FXColors.bg)
    }

    private func buildTree(from paths: [String], prefix: String = "") -> [FileTreeNode] {
        let grouped = Dictionary(grouping: paths) { path -> String in
            let parts = path.split(separator: "/", maxSplits: 1)
            return parts.first.map(String.init) ?? path
        }

        return grouped.map { name, groupedPaths in
            let childPaths = groupedPaths.compactMap { path -> String? in
                let parts = path.split(separator: "/", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return String(parts[1])
            }

            let fullPath = prefix.isEmpty ? name : "\(prefix)/\(name)"
            return FileTreeNode(
                name: name,
                path: fullPath,
                children: buildTree(from: childPaths, prefix: fullPath)
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func filteredTree(_ nodes: [FileTreeNode], query: String) -> [FileTreeNode] {
        guard !query.isEmpty else { return nodes }

        return nodes.compactMap { node in
            if node.isDirectory {
                if node.path.localizedCaseInsensitiveContains(query) {
                    return node
                }

                let children = filteredTree(node.children, query: query)
                guard !children.isEmpty else { return nil }
                return FileTreeNode(name: node.name, path: node.path, children: children)
            }

            return node.path.localizedCaseInsensitiveContains(query) ? node : nil
        }
    }

    private func seedExpandedPaths(from nodes: [FileTreeNode], selectedPath: String?) {
        guard expandedPaths.isEmpty else {
            expandAncestors(of: selectedPath)
            return
        }

        for node in nodes where node.isDirectory {
            expandedPaths.insert(node.path)
        }

        expandAncestors(of: selectedPath)
    }

    private func expandAncestors(of path: String?) {
        guard let path else { return }

        let components = path.split(separator: "/")
        guard components.count > 1 else { return }

        var current = ""
        for component in components.dropLast() {
            current = current.isEmpty ? String(component) : "\(current)/\(component)"
            expandedPaths.insert(current)
        }
    }
}

private struct FileTreeNode: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let children: [FileTreeNode]

    var isDirectory: Bool { !children.isEmpty }
}

private struct FilesTreeRow: View {
    let node: FileTreeNode
    let depth: Int
    let selectedPath: String?
    let forceExpanded: Bool
    @Binding var expandedPaths: Set<String>
    let onSelect: (String) -> Void

    private var isExpanded: Bool {
        forceExpanded || expandedPaths.contains(node.path)
    }

    private var isSelected: Bool {
        selectedPath == node.path
    }

    private var isAncestorSelected: Bool {
        guard node.isDirectory, let selectedPath else { return false }
        return selectedPath.hasPrefix(node.path + "/")
    }

    var body: some View {
        VStack(spacing: FXSpacing.xxs) {
            if node.isDirectory {
                Button(action: toggleExpansion) {
                    HStack(spacing: FXSpacing.sm) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(FXColors.fgQuaternary)
                            .frame(width: 10)

                        Image(systemName: "folder")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(FXColors.fgTertiary)

                        Text(node.name)
                            .font(FXTypography.captionMedium)
                            .foregroundStyle(isAncestorSelected ? FXColors.fgSecondary : FXColors.fgTertiary)
                            .lineLimit(1)

                        Spacer(minLength: 0)
                    }
                    .padding(.leading, FXSpacing.md + CGFloat(depth) * 14)
                    .padding(.trailing, FXSpacing.md)
                    .padding(.vertical, FXSpacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: FXRadii.md)
                            .fill(isAncestorSelected ? FXColors.bgHover : .clear)
                    )
                }
                .buttonStyle(.plain)

                if isExpanded {
                    ForEach(node.children) { child in
                        FilesTreeRow(
                            node: child,
                            depth: depth + 1,
                            selectedPath: selectedPath,
                            forceExpanded: forceExpanded,
                            expandedPaths: $expandedPaths,
                            onSelect: onSelect
                        )
                    }
                }
            } else {
                Button(action: { onSelect(node.path) }) {
                    HStack(spacing: FXSpacing.sm) {
                        Color.clear
                            .frame(width: 10)

                        Image(systemName: "doc")
                            .font(.system(size: 11))
                            .foregroundStyle(isSelected ? FXColors.info : FXColors.fgQuaternary)

                        Text(node.name)
                            .font(FXTypography.caption)
                            .foregroundStyle(isSelected ? FXColors.fg : FXColors.fgSecondary)
                            .lineLimit(1)

                        Spacer(minLength: 0)
                    }
                    .padding(.leading, FXSpacing.md + CGFloat(depth) * 14)
                    .padding(.trailing, FXSpacing.md)
                    .padding(.vertical, FXSpacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: FXRadii.md)
                            .fill(isSelected ? FXColors.bgSelected : .clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: FXRadii.md)
                            .strokeBorder(isSelected ? FXColors.borderMedium : .clear, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func toggleExpansion() {
        guard !forceExpanded else { return }
        if expandedPaths.contains(node.path) {
            expandedPaths.remove(node.path)
        } else {
            expandedPaths.insert(node.path)
        }
    }
}
