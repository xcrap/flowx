import Foundation

public struct Project: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var rootPath: String
    public var description: String
    public var createdAt: Date
    public var updatedAt: Date
    public var agentOrder: [UUID]

    public var rootURL: URL {
        URL(fileURLWithPath: Self.normalizedRootPath(rootPath), isDirectory: true)
    }

    /// A stable spelling of the workspace path suitable for persistence and
    /// equality checks that should not treat `..`, `.` or `~` as distinct
    /// projects.
    public var normalizedRootPath: String {
        Self.normalizedRootPath(rootPath)
    }

    /// Resolves filesystem aliases such as symbolic links when the target
    /// exists. This is used only for duplicate detection; the normalized path
    /// remains the user-facing persisted path.
    public var canonicalRootPath: String {
        rootURL.resolvingSymlinksInPath().path
    }

    public init(
        id: UUID = UUID(),
        name: String = "Untitled Project",
        rootPath: String = NSHomeDirectory(),
        description: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        agentOrder: [UUID] = []
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.description = description
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.agentOrder = agentOrder
    }

    public static func normalizedRootPath(_ path: String) -> String {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmedPath.isEmpty ? NSHomeDirectory() : trimmedPath
        let expandedPath = (candidate as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expandedPath, isDirectory: true).standardizedFileURL.path
    }

    public static func validatedPersistedRootPath(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, (trimmed as NSString).isAbsolutePath else { return nil }
        return normalizedRootPath(trimmed)
    }
}
