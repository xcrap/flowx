import Foundation
import ImageIO
import UniformTypeIdentifiers
import FXCore

/// Converts image references owned by a provider's native transcript into
/// detached conversation content. Remote URLs are deliberately not fetched:
/// native history import must never turn transcript rendering into network or
/// arbitrary-resource access.
enum ProviderNativeImageImporter {
    static let maximumImageBytes = ProviderAttachmentStore.maximumAttachmentBytes
    static let maximumTranscriptImageBytes = ProviderAttachmentStore.maximumTotalBytes

    private static let maximumPathBytes = 4_096
    private static let supportedMIMETypes: Set<String> = [
        "image/jpeg",
        "image/png",
        "image/webp",
        "image/gif",
        "image/heic",
        "image/heif",
        "image/tiff",
        "image/bmp",
    ]

    static func localFile(
        atPath path: String,
        remainingBytes: inout Int
    ) -> MessageContent? {
        guard remainingBytes > 0,
              !path.isEmpty,
              path.utf8.count <= maximumPathBytes,
              path.first == "/",
              !path.contains("\0"),
              !NSString(string: path).pathComponents.contains("..") else {
            return nil
        }

        let originalURL = URL(fileURLWithPath: path, isDirectory: false)
            .standardizedFileURL
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]
        guard let values = try? originalURL.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= min(maximumImageBytes, remainingBytes),
              FileManager.default.isReadableFile(atPath: originalURL.path) else {
            return nil
        }

        let resolvedURL = originalURL.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedURL.isFileURL,
              let data = try? Data(contentsOf: resolvedURL, options: []),
              data.count == fileSize else {
            return nil
        }
        return validatedContent(
            data: data,
            declaredMIMEType: nil,
            remainingBytes: &remainingBytes
        )
    }

    static func dataURL(
        _ rawValue: String,
        remainingBytes: inout Int
    ) -> MessageContent? {
        guard rawValue.hasPrefix("data:"),
              let comma = rawValue.firstIndex(of: ",") else {
            return nil
        }
        let metadata = rawValue[rawValue.index(rawValue.startIndex, offsetBy: 5)..<comma]
        let fields = metadata.split(separator: ";", omittingEmptySubsequences: false)
        guard let mediaType = fields.first.map(String.init),
              fields.dropFirst().contains(where: {
                  $0.caseInsensitiveCompare("base64") == .orderedSame
              }) else {
            return nil
        }
        return base64(
            String(rawValue[rawValue.index(after: comma)...]),
            mimeType: mediaType,
            remainingBytes: &remainingBytes
        )
    }

    static func base64(
        _ encoded: String,
        mimeType: String,
        remainingBytes: inout Int
    ) -> MessageContent? {
        guard remainingBytes > 0,
              canonicalMIMEType(mimeType) != nil else {
            return nil
        }

        let maximumDecodedBytes = min(maximumImageBytes, remainingBytes)
        let maximumEncodedBytes = ((maximumDecodedBytes + 2) / 3) * 4
        guard !encoded.isEmpty,
              encoded.utf8.count <= maximumEncodedBytes,
              let data = Data(base64Encoded: encoded),
              !data.isEmpty,
              data.count <= maximumDecodedBytes else {
            return nil
        }
        return validatedContent(
            data: data,
            declaredMIMEType: mimeType,
            remainingBytes: &remainingBytes
        )
    }

    private static func validatedContent(
        data: Data,
        declaredMIMEType: String?,
        remainingBytes: inout Int
    ) -> MessageContent? {
        guard !data.isEmpty,
              data.count <= min(maximumImageBytes, remainingBytes),
              let source = CGImageSourceCreateWithData(
                  data as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                  as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0,
              width <= ProviderAttachmentStore.maximumPixelDimension,
              height <= ProviderAttachmentStore.maximumPixelDimension,
              width <= ProviderAttachmentStore.maximumPixelCount / height,
              let typeIdentifier = CGImageSourceGetType(source) as String?,
              let detectedMIMEType = UTType(typeIdentifier)?.preferredMIMEType
                  .flatMap(canonicalMIMEType) else {
            return nil
        }

        if let declaredMIMEType {
            guard canonicalMIMEType(declaredMIMEType) == detectedMIMEType else {
                return nil
            }
        }

        remainingBytes -= data.count
        return .image(data: data, mimeType: detectedMIMEType)
    }

    private static func canonicalMIMEType(_ value: String) -> String? {
        let normalized = value
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let canonical: String
        switch normalized {
        case "image/jpg":
            canonical = "image/jpeg"
        case "image/x-png":
            canonical = "image/png"
        case "image/x-bmp", "image/x-ms-bmp":
            canonical = "image/bmp"
        case let value?:
            canonical = value
        case nil:
            return nil
        }
        return supportedMIMETypes.contains(canonical) ? canonical : nil
    }
}
