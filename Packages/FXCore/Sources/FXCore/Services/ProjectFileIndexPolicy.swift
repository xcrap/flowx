import Foundation

public enum ProjectFileIndexPolicy {
    public static let skippedDirectoryNames: Set<String> = [
        ".git", ".build", ".next", ".swiftpm", "DerivedData", "build", "dist", "node_modules",
    ]

    public static func shouldSkip(relativePath: String, isDirectory: Bool) -> Bool {
        guard isDirectory else { return false }
        return relativePath.split(separator: "/").contains {
            skippedDirectoryNames.contains(String($0))
        }
    }

    public static func shouldSkipFile(relativePath: String) -> Bool {
        let directoryComponents = relativePath.split(separator: "/").dropLast()
        return directoryComponents.contains {
            skippedDirectoryNames.contains(String($0))
        }
    }
}
