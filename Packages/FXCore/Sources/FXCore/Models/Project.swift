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
        URL(fileURLWithPath: rootPath)
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
}
