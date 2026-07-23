import AppKit
import FXCore
import ImageIO

/// Bounded, downsampled image cache shared by composer and conversation media.
/// Raw attachment bytes never become full-resolution `NSImage` instances on
/// the main actor, which keeps large photos from stalling or inflating RSS.
@MainActor
enum AttachmentImageCache {
    private final class ImageBox: NSObject {
        let image: NSImage

        init(_ image: NSImage) {
            self.image = image
        }
    }

    private static let cache: NSCache<NSString, ImageBox> = {
        let cache = NSCache<NSString, ImageBox>()
        cache.countLimit = 64
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    private static let decodeExecutor = BoundedTaskExecutor(maxConcurrentTasks: 2)

    static func image(for key: String) -> NSImage? {
        cache.object(forKey: key as NSString)?.image
    }

    static func store(_ decoded: DownsampledImage, for key: String) -> NSImage {
        let size = NSSize(width: decoded.width, height: decoded.height)
        let image = NSImage(cgImage: decoded.cgImage, size: size)
        cache.setObject(ImageBox(image), forKey: key as NSString, cost: decoded.byteCost)
        return image
    }

    static func loadDownsampledImage(
        from data: Data,
        maxPixelSize: Int
    ) async -> DownsampledImage? {
        do {
            return try await decodeExecutor.run(priority: .utility) {
                downsample(data, maxPixelSize: maxPixelSize)
            }
        } catch {
            return nil
        }
    }

    static func loadDownsampledImage(
        from fileURL: URL,
        maxPixelSize: Int
    ) async -> DownsampledImage? {
        do {
            return try await decodeExecutor.run(priority: .utility) {
                downsample(fileURL: fileURL, maxPixelSize: maxPixelSize)
            }
        } catch {
            return nil
        }
    }

    nonisolated private static func downsample(_ data: Data, maxPixelSize: Int) -> DownsampledImage? {
        guard !Task.isCancelled else { return nil }
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        return downsample(source, maxPixelSize: maxPixelSize)
    }

    /// Downsamples a durable history asset without first materializing the
    /// original file as `Data`, keeping multi-megabyte images out of the main
    /// actor and avoiding a second full-size allocation.
    nonisolated private static func downsample(fileURL: URL, maxPixelSize: Int) -> DownsampledImage? {
        guard !Task.isCancelled else { return nil }
        guard fileURL.isFileURL,
              let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            return nil
        }

        return downsample(source, maxPixelSize: maxPixelSize)
    }

    nonisolated private static func downsample(
        _ source: CGImageSource,
        maxPixelSize: Int
    ) -> DownsampledImage? {
        guard !Task.isCancelled else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(32, maxPixelSize),
            kCGImageSourceShouldCacheImmediately: true,
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              !Task.isCancelled else {
            return nil
        }

        return DownsampledImage(cgImage: cgImage)
    }
}

struct DownsampledImage: @unchecked Sendable {
    let cgImage: CGImage
    let width: Int
    let height: Int
    let byteCost: Int

    init(cgImage: CGImage) {
        self.cgImage = cgImage
        width = cgImage.width
        height = cgImage.height
        byteCost = cgImage.bytesPerRow * cgImage.height
    }
}
