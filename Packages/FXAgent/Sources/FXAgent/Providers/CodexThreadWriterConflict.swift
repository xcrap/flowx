import Foundation

/// A rejected resume, before any user input is sent to the provider.
public struct CodexThreadWriterConflict: LocalizedError, Sendable {
    public static let message = "This task is open in another Codex session. FlowX can show its updates, but your message was not sent. Finish any running work and quit the other Codex app or session, then retry your message here."

    public init() {}

    public var errorDescription: String? { Self.message }

    public static func matches(_ message: String) -> Bool {
        message == Self.message || message.localizedCaseInsensitiveContains("already has an active writer")
    }
}
