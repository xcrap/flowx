import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import FXCore

private func fixtureImage(width: Int, height: Int, alpha: Bool = false, noise: Bool = false) throws -> CGImage {
    var pixels = Data(count: width * height * 4)
    pixels.withUnsafeMutableBytes { bytes in
        let values = bytes.bindMemory(to: UInt32.self)
        var seed: UInt32 = 0x12345678
        for i in values.indices {
            seed ^= seed << 13
            seed ^= seed >> 17
            seed ^= seed << 5
            values[i] = (noise ? seed & 0x00ffffff : 0x004488aa) | (alpha ? 0x80000000 : 0xff000000)
        }
    }
    let provider = try #require(CGDataProvider(data: pixels as CFData))
    return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: alpha ? CGImageAlphaInfo.last.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
}

private func encodeFixture(_ image: CGImage, type: UTType, orientation: Int = 1, frames: Int = 1) throws -> Data {
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, frames, nil))
    for _ in 0..<frames {
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
    }
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

private func decoded(_ attachment: FXCore.Attachment) throws -> CGImage {
    #expect(attachment.data.count <= AttachmentImagePreparer.maximumOutputBytes)
    let source = try #require(CGImageSourceCreateWithData(attachment.data as CFData, nil))
    #expect(CGImageSourceGetCount(source) == 1)
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(max(image.width, image.height) <= AttachmentImagePreparer.maximumOutputDimension)
    return image
}

@Test func smallCompatibleImageKeepsItsBytesAndIdentity() throws {
    let data = try encodeFixture(fixtureImage(width: 80, height: 40), type: .png)
    let original = Attachment(data: data, mimeType: "image/png", filename: "screenshot.png")
    let prepared = try AttachmentImagePreparer.prepare(original)
    #expect(prepared == original)
    #expect(try decoded(prepared).width == 80)
}

@Test func oversizedNoisyPNGIsCompressedWithoutChangingOriginalFile() throws {
    let data = try encodeFixture(fixtureImage(width: 3500, height: 2600, noise: true), type: .png)
    #expect(data.count > 25 * 1_024 * 1_024)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("flowx-large-\(UUID()).png")
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let prepared = try AttachmentImagePreparer.prepare(fileURL: url)
    let image = try decoded(prepared)
    let aspectRatioError = abs(Double(image.width) / Double(image.height) - 3500.0 / 2600.0)
    #expect(aspectRatioError < 0.003)
    #expect(prepared.data.count < data.count / 10)
    #expect(try Data(contentsOf: url) == data)
    print("Attachment benchmark: \(data.count) bytes -> \(prepared.data.count) bytes, \(image.width)×\(image.height)")
}

@Test func largeTransparentImageStaysTransparentAndStatic() throws {
    let data = try encodeFixture(fixtureImage(width: 2400, height: 1200, alpha: true, noise: true), type: .png)
    let prepared = try AttachmentImagePreparer.prepare(Attachment(data: data, mimeType: "image/png", filename: "overlay.png"))
    let image = try decoded(prepared)
    #expect(prepared.mimeType == "image/png")
    #expect([CGImageAlphaInfo.first, .last, .premultipliedFirst, .premultipliedLast].contains(image.alphaInfo))
    #expect(image.width < 2000)
    #expect(abs(Double(image.width) / Double(image.height) - 2) < 0.01)
}

@Test func rotatedJPEGIsOrientedBeforeSending() throws {
    let data = try encodeFixture(fixtureImage(width: 80, height: 40), type: .jpeg, orientation: 6)
    let prepared = try AttachmentImagePreparer.prepare(Attachment(data: data, mimeType: "image/jpeg", filename: "photo.jpg"))
    let image = try decoded(prepared)
    #expect(image.width == 40)
    #expect(image.height == 80)
    let source = try #require(CGImageSourceCreateWithData(prepared.data as CFData, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    #expect((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1 == 1)
}

@Test func clipboardTIFFAndAnimatedGIFBecomePortableStaticImages() throws {
    let image = try fixtureImage(width: 100, height: 50, alpha: true)
    for (type, mime, name, frames) in [(UTType.tiff, "image/tiff", "Pasted Image.tiff", 1),
                                      (UTType.gif, "image/gif", "animation.gif", 2)] {
        let data = try encodeFixture(image, type: type, frames: frames)
        let prepared = try AttachmentImagePreparer.prepare(Attachment(data: data, mimeType: mime, filename: name))
        #expect(prepared.mimeType == "image/png")
        #expect(prepared.filename.hasSuffix(".png"))
        #expect(try decoded(prepared).width == 100)
    }
}

@Test func preparationRejectsInvalidDataAndUsesActualImageFormat() throws {
    #expect(throws: AttachmentImagePreparationError.self) {
        try AttachmentImagePreparer.prepare(Attachment(data: Data("not an image".utf8), mimeType: "image/png", filename: "broken.png"))
    }
    let data = try encodeFixture(fixtureImage(width: 20, height: 10), type: .png)
    let prepared = try AttachmentImagePreparer.prepare(Attachment(data: data, mimeType: "image/jpeg", filename: "mislabeled.jpg"))
    #expect(prepared.mimeType == "image/png")
    #expect(prepared.filename == "mislabeled.png")
    #expect(prepared.data == data)
}

@Test func preparationRejectsOversizedSourceBeforeDecoding() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("flowx-source-limit-\(UUID()).png")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: url) }
    let file = try FileHandle(forWritingTo: url)
    try file.truncate(atOffset: UInt64(AttachmentImagePreparer.maximumSourceBytes + 1))
    try file.close()
    do {
        _ = try AttachmentImagePreparer.prepare(fileURL: url)
        Issue.record("Oversized source was accepted")
    } catch AttachmentImagePreparationError.sourceTooLarge {
        // Expected before ImageIO reads or decodes the sparse file.
    }
}
