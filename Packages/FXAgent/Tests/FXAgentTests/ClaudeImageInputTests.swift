import Foundation
import Testing
@testable import FXAgent

@Test func claudeInitialPromptUsesNativeImageContentBlocks() throws {
    let imageData = Data([0x89, 0x50, 0x4e, 0x47])
    let imageURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("png")
    try imageData.write(to: imageURL, options: .atomic)
    defer { try? FileManager.default.removeItem(at: imageURL) }

    let pipe = Pipe()
    let controller = ClaudeTurnController()
    controller.setWriter(pipe.fileHandleForWriting)
    try controller.sendInitialPrompt("Inspect this image.", imageFiles: [imageURL])
    controller.closeInput()

    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    let line = try #require(String(data: output, encoding: .utf8))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let envelope = try #require(
        JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    )
    let message = try #require(envelope["message"] as? [String: Any])
    let content = try #require(message["content"] as? [[String: Any]])
    #expect(content.count == 2)
    #expect(content[0]["type"] as? String == "text")
    #expect(content[0]["text"] as? String == "Inspect this image.")
    #expect(content[1]["type"] as? String == "image")

    let source = try #require(content[1]["source"] as? [String: Any])
    #expect(source["type"] as? String == "base64")
    #expect(source["media_type"] as? String == "image/png")
    let encoded = try #require(source["data"] as? String)
    #expect(Data(base64Encoded: encoded) == imageData)
}
