import Foundation

public struct Attachment: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let data: Data
    public let mimeType: String
    public let filename: String

    public init(id: UUID = UUID(), data: Data, mimeType: String, filename: String) {
        self.id = id
        self.data = data
        self.mimeType = mimeType
        self.filename = filename
    }

    public var isImage: Bool {
        mimeType.hasPrefix("image/")
    }

    public var isPDF: Bool {
        mimeType == "application/pdf"
    }

    public static let supportedImageTypes: Set<String> = [
        "public.jpeg",
        "public.png",
        "public.gif",
        "public.webp",
        "public.heic",
        "public.heif",
        "public.tiff",
        "public.bmp",
    ]

    public static let supportedTypes: Set<String> = supportedImageTypes.union([
        "com.adobe.pdf",
    ])

    public static func mimeType(for utType: String) -> String {
        switch utType {
        case "public.jpeg": "image/jpeg"
        case "public.png": "image/png"
        case "public.gif": "image/gif"
        case "public.webp": "image/webp"
        case "public.heic", "public.heif": "image/heic"
        case "public.tiff": "image/tiff"
        case "public.bmp": "image/bmp"
        case "com.adobe.pdf": "application/pdf"
        default: "application/octet-stream"
        }
    }

    public static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "heic", "heif": "image/heic"
        case "tiff", "tif": "image/tiff"
        case "bmp": "image/bmp"
        case "pdf": "application/pdf"
        default: "application/octet-stream"
        }
    }
}

public enum MessageRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}

public enum MessageContent: Codable, Sendable, Equatable {
    case text(String)
    case code(language: String, code: String)
    case image(data: Data, mimeType: String)
    case toolUse(id: String, name: String, input: String)
    case toolResult(id: String, content: String, isError: Bool)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case language
        case code
        case data
        case mimeType
        case id
        case name
        case input
        case content
        case isError
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .code(let language, let code):
            try container.encode("code", forKey: .type)
            try container.encode(language, forKey: .language)
            try container.encode(code, forKey: .code)
        case .image(let data, let mimeType):
            try container.encode("image", forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encode(mimeType, forKey: .mimeType)
        case .toolUse(let id, let name, let input):
            try container.encode("toolUse", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(input, forKey: .input)
        case .toolResult(let id, let content, let isError):
            try container.encode("toolResult", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(content, forKey: .content)
            try container.encode(isError, forKey: .isError)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "code":
            self = .code(
                language: try container.decode(String.self, forKey: .language),
                code: try container.decode(String.self, forKey: .code)
            )
        case "image":
            self = .image(
                data: try container.decode(Data.self, forKey: .data),
                mimeType: try container.decode(String.self, forKey: .mimeType)
            )
        case "toolUse":
            self = .toolUse(
                id: try container.decode(String.self, forKey: .id),
                name: try container.decode(String.self, forKey: .name),
                input: try container.decode(String.self, forKey: .input)
            )
        case "toolResult":
            self = .toolResult(
                id: try container.decode(String.self, forKey: .id),
                content: try container.decode(String.self, forKey: .content),
                isError: try container.decode(Bool.self, forKey: .isError)
            )
        case let type:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown content type: \(type)"
            )
        }
    }
}

public struct ConversationMessage: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var role: MessageRole
    public var content: [MessageContent]
    public var timestamp: Date

    public init(
        id: UUID = UUID(),
        role: MessageRole,
        content: [MessageContent],
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }

    public var textContent: String {
        content.compactMap { item in
            if case .text(let text) = item {
                return text
            }
            return nil
        }
        .joined()
    }
}

public struct Conversation: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var agentID: UUID
    public var messages: [ConversationMessage]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        agentID: UUID,
        messages: [ConversationMessage] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.agentID = agentID
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
