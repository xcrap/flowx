import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import FXCore
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

@Test func providerPreparationResizesOlderLargeAttachmentsBeforeSending() async throws {
    let context = try #require(CGContext(data: nil, width: 4000, height: 2000, bitsPerComponent: 8,
                                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 4000, height: 2000))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    let prepared = try await ProviderAttachmentStore.prepareForSending([
        FXCore.Attachment(data: data as Data, mimeType: "image/jpeg", filename: "large-photo.jpg"),
    ])
    defer { prepared.remove() }
    let file = try #require(prepared.files.first)
    let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
    let output = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(output.width == 2000)
    #expect(output.height == 1000)
    #expect(try Data(contentsOf: file).count <= AttachmentImagePreparer.maximumOutputBytes)
}
