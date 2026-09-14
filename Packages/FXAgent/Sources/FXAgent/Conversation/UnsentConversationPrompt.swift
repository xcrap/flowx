import Foundation
import FXCore

/// Kept separately from the provider-owned transcript so refresh cannot erase it.
public struct UnsentConversationPrompt: Codable, Sendable, Equatable {
    public let prompt: String
    public let attachments: [Attachment]
    public let sessionID: String?

    public init(prompt: String, attachments: [Attachment], sessionID: String?) {
        self.prompt = prompt
        self.attachments = attachments
        self.sessionID = sessionID
    }
}
