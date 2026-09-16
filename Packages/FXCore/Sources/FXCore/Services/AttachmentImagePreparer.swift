import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum AttachmentImagePreparationError: LocalizedError, Sendable {
    case unreadable(String)
    case sourceTooLarge(String)
    case invalidImage(String)
    case unsupported(String)
    case cannotFit(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let name): "\(name) is empty or could not be read."
        case .sourceTooLarge(let name): "\(name) exceeds the 128 MB import limit. Export a smaller image first."
        case .invalidImage(let name): "\(name) could not be decoded as an image. Try exporting it as PNG or JPEG."
        case .unsupported(let name): "\(name) is not a supported image. Choose a PNG, JPEG, WebP, GIF, HEIC, TIFF, or BMP file."
        case .cannotFit(let name): "\(name) could not be reduced to the image size limit. Try cropping it or exporting a smaller copy."
        }
    }
}

/// Prepares a copy for model input. Originals remain untouched. Call from a
/// background executor: decoding and encoding are intentionally synchronous.
public enum AttachmentImagePreparer {
    public static let maximumSourceBytes = 128 * 1_024 * 1_024
    public static let maximumOutputBytes = 2 * 1_024 * 1_024
    // Also fits Claude's limit when earlier turns bring the image count above 20.
    public static let maximumOutputDimension = 2_000
    private static let maximumSourcePixels = 200_000_000

    public static func prepare(fileURL: URL, id: UUID = UUID()) throws -> Attachment {
        let name = fileURL.lastPathComponent
        guard fileURL.isFileURL,
              let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size > 0 else {
            throw AttachmentImagePreparationError.unreadable(name)
        }
        guard size <= maximumSourceBytes else { throw AttachmentImagePreparationError.sourceTooLarge(name) }
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, sourceOptions) else {
            throw AttachmentImagePreparationError.invalidImage(name)
        }
        return try prepare(source: source, size: size, id: id, name: name) {
            // Only read original bytes for an already-small compatible image.
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            guard data.count == size else { throw AttachmentImagePreparationError.unreadable(name) }
            return data
        }
    }

    public static func prepare(_ attachment: Attachment) throws -> Attachment {
        guard attachment.isImage else { throw AttachmentImagePreparationError.unsupported(attachment.filename) }
        guard !attachment.data.isEmpty else { throw AttachmentImagePreparationError.unreadable(attachment.filename) }
        guard attachment.data.count <= maximumSourceBytes else {
            throw AttachmentImagePreparationError.sourceTooLarge(attachment.filename)
        }
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(attachment.data as CFData, sourceOptions) else {
            throw AttachmentImagePreparationError.invalidImage(attachment.filename)
        }
        return try prepare(source: source, size: attachment.data.count, id: attachment.id,
                           name: attachment.filename) { attachment.data }
    }

    private static var sourceOptions: CFDictionary {
        [kCGImageSourceShouldCache: false] as CFDictionary
    }

    private static func prepare(source: CGImageSource, size: Int, id: UUID, name: String,
                                originalData: () throws -> Data) throws -> Attachment {
        guard CGImageSourceGetCount(source) > 0,
              let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String),
              [UTType.png, .jpeg, .webP, .gif, .heic, .heif, .tiff, .bmp].contains(where: { type.conforms(to: $0) }) else {
            throw AttachmentImagePreparationError.unsupported(name)
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, max(width, height) <= 100_000,
              width <= maximumSourcePixels / height else {
            throw AttachmentImagePreparationError.invalidImage(name)
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let passthroughType: UTType? = [UTType.png, .jpeg, .webP].first { type.conforms(to: $0) }
        var edge = min(max(width, height), maximumOutputDimension)
        for attempt in 0..<10 {
            try Task.checkCancellation()
            // ImageIO downsamples during decode and applies EXIF orientation;
            // it never creates an original-resolution NSImage on the UI thread.
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: edge,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary) else {
                throw AttachmentImagePreparationError.invalidImage(name)
            }
            try Task.checkCancellation()
            if attempt == 0, let passthroughType, orientation == 1,
               CGImageSourceGetCount(source) == 1,
               max(width, height) <= maximumOutputDimension, size <= maximumOutputBytes {
                return attachment(data: try originalData(), type: passthroughType, id: id, name: name)
            }

            let hasAlpha = [.first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly].contains(image.alphaInfo)
            // Keep screenshot text lossless and preserve transparency. Opaque
            // photos use JPEG if PNG would exceed the budget.
            if hasAlpha || !type.conforms(to: .jpeg) && !type.conforms(to: .heic) && !type.conforms(to: .heif) {
                if let data = encode(image, as: .png), data.count <= maximumOutputBytes {
                    return attachment(data: data, type: .png, id: id, name: name)
                }
            }
            if !hasAlpha {
                for quality in [0.9, 0.8, 0.7] {
                    try Task.checkCancellation()
                    if let data = encode(image, as: .jpeg, quality: quality), data.count <= maximumOutputBytes {
                        return attachment(data: data, type: .jpeg, id: id, name: name)
                    }
                }
            }
            guard edge > 64 else { break }
            edge = max(64, Int(Double(edge) * 0.75))
        }
        throw AttachmentImagePreparationError.cannotFit(name)
    }

    private static func encode(_ image: CGImage, as type: UTType, quality: Double? = nil) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        var options: [CFString: Any] = [:]
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func attachment(data: Data, type: UTType, id: UUID, name: String) -> Attachment {
        let ext = type.preferredFilenameExtension ?? "png"
        let originalExtension = (name as NSString).pathExtension
        let matchesExtension = UTType(filenameExtension: originalExtension)?.conforms(to: type) == true
        let filename = matchesExtension ? name : (name as NSString).deletingPathExtension + "." + ext
        return Attachment(id: id, data: data, mimeType: type.preferredMIMEType ?? "image/png", filename: filename)
    }
}
