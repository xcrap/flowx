import Foundation
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
    // Existing provider transcripts may contain larger, unoptimized images.
    static let maximumPixelCount = 50_000_000
    static let maximumPixelDimension = 16_384
    private static let preparationExecutor = BoundedTaskExecutor(maxConcurrentTasks: 2)

    static func prepareForSending(_ attachments: [Attachment]) async throws -> PreparedProviderAttachments {
        guard !attachments.isEmpty else { return .empty }
        return try await preparationExecutor.run(priority: .userInitiated) { try prepare(attachments) }
    }

    static func prepare(_ attachments: [Attachment]) throws -> PreparedProviderAttachments {
        guard !attachments.isEmpty else { return .empty }
        guard attachments.count <= maximumAttachmentCount else {
            throw ProviderAttachmentError.tooMany(maximumAttachmentCount)
        }

        for attachment in attachments where !attachment.isImage {
            throw ProviderAttachmentError.unsupported(attachment.filename)
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
        let prepared = try AttachmentImagePreparer.prepare(attachment)
        let output = (data: prepared.data, extension: (prepared.filename as NSString).pathExtension)

        let url = directory.appendingPathComponent(String(format: "%02d-%@.%@", index, attachment.id.uuidString, output.extension))
        do {
            try output.data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw ProviderAttachmentError.couldNotCreateStorage
        }
        return url
    }

}
