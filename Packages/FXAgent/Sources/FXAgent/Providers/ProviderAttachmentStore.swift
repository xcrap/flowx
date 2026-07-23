import Foundation
import ImageIO
import UniformTypeIdentifiers
import FXCore

struct PreparedProviderAttachments: Sendable {
    let directory: URL?
    let files: [URL]

    static let empty = PreparedProviderAttachments(directory: nil, files: [])

    func remove() {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}

enum ProviderAttachmentError: LocalizedError, Sendable {
    case tooMany(Int)
    case tooLarge(String)
    case totalTooLarge
    case unsupported(String)
    case invalidImage(String)
    case couldNotCreateStorage

    var errorDescription: String? {
        switch self {
        case .tooMany(let maximum):
            "A turn can include at most \(maximum) images."
        case .tooLarge(let filename):
            "\(filename) is larger than the 25 MB image limit."
        case .totalTooLarge:
            "The images in one turn cannot exceed 50 MB in total."
        case .unsupported(let filename):
            "\(filename) is not a supported image. PDF and generic file inputs are not supported by the current provider protocols."
        case .invalidImage(let filename):
            "\(filename) could not be decoded as an image."
        case .couldNotCreateStorage:
            "FlowX could not create secure temporary storage for the images."
        }
    }
}

enum ProviderAttachmentStore {
    static let maximumAttachmentCount = 10
    static let maximumAttachmentBytes = 25 * 1_024 * 1_024
    static let maximumTotalBytes = 50 * 1_024 * 1_024
    static let maximumPixelCount = 50_000_000
    static let maximumPixelDimension = 16_384
    static let convertedMaximumPixelDimension = 2_048

    static func prepare(_ attachments: [Attachment]) throws -> PreparedProviderAttachments {
        guard !attachments.isEmpty else { return .empty }
        guard attachments.count <= maximumAttachmentCount else {
            throw ProviderAttachmentError.tooMany(maximumAttachmentCount)
        }

        var totalBytes = 0
        for attachment in attachments {
            guard attachment.isImage else {
                throw ProviderAttachmentError.unsupported(attachment.filename)
            }
            guard attachment.data.count <= maximumAttachmentBytes else {
                throw ProviderAttachmentError.tooLarge(attachment.filename)
            }
            let (newTotal, overflow) = totalBytes.addingReportingOverflow(attachment.data.count)
            guard !overflow, newTotal <= maximumTotalBytes else {
                throw ProviderAttachmentError.totalTooLarge
            }
            totalBytes = newTotal
        }

        let manager = FileManager.default
        let directory = manager.temporaryDirectory
            .appendingPathComponent("FlowX", isDirectory: true)
            .appendingPathComponent("ProviderAttachments", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        do {
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            throw ProviderAttachmentError.couldNotCreateStorage
        }

        do {
            let files = try attachments.enumerated().map { index, attachment in
                try write(attachment, index: index, to: directory)
            }
            let outputBytes = try files.reduce(into: 0) { total, file in
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= maximumAttachmentBytes else {
                    throw ProviderAttachmentError.tooLarge(file.lastPathComponent)
                }
                let (sum, overflow) = total.addingReportingOverflow(size)
                guard !overflow, sum <= maximumTotalBytes else {
                    throw ProviderAttachmentError.totalTooLarge
                }
                total = sum
            }
            _ = outputBytes
            return PreparedProviderAttachments(directory: directory, files: files)
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }

    private static func write(_ attachment: Attachment, index: Int, to directory: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithData(
            attachment.data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ), CGImageSourceGetCount(source) > 0,
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
        width > 0, height > 0,
        width <= maximumPixelDimension, height <= maximumPixelDimension,
        width <= maximumPixelCount / height else {
            throw ProviderAttachmentError.invalidImage(attachment.filename)
        }

        let mimeType = attachment.mimeType.lowercased()
        let output: (data: Data, extension: String)
        switch mimeType {
        case "image/jpeg", "image/jpg":
            output = (attachment.data, "jpg")
        case "image/png":
            output = (attachment.data, "png")
        case "image/webp":
            output = (attachment.data, "webp")
        case "image/gif", "image/heic", "image/heif", "image/tiff", "image/bmp", "image/x-bmp":
            // Provider image inputs are static. Animated GIFs are deliberately
            // flattened to their first frame, and less portable formats are
            // normalized to PNG before either CLI sees them.
            output = (try pngData(from: source, filename: attachment.filename), "png")
        default:
            throw ProviderAttachmentError.unsupported(attachment.filename)
        }

        let url = directory.appendingPathComponent(String(format: "%02d-%@.%@", index, attachment.id.uuidString, output.extension))
        do {
            try output.data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw ProviderAttachmentError.couldNotCreateStorage
        }
        return url
    }

    private static func pngData(from source: CGImageSource, filename: String) throws -> Data {
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: convertedMaximumPixelDimension,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else {
            throw ProviderAttachmentError.invalidImage(filename)
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ProviderAttachmentError.invalidImage(filename)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ProviderAttachmentError.invalidImage(filename)
        }
        let result = data as Data
        guard result.count <= maximumAttachmentBytes else {
            throw ProviderAttachmentError.tooLarge(filename)
        }
        return result
    }
}
