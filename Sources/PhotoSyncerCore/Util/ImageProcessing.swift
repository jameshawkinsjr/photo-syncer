import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// How an account wants photos changed before they're uploaded.
public struct ImageOptions: Sendable, Hashable {
    /// Scale the long edge down to this many pixels; smaller photos keep their size.
    public var maxPixelSize: Int?
    /// Re-encode every photo as JPEG at this quality (0–1) to save space. `nil` keeps the
    /// photo's own quality (it's only re-encoded when it has to be resized or converted).
    public var jpegQuality: Double?
    /// Convert HEIC, PNG and the like to JPEG.
    public var preferJPEG: Bool

    public init(maxPixelSize: Int? = nil, jpegQuality: Double? = nil, preferJPEG: Bool = false) {
        self.maxPixelSize = maxPixelSize
        self.jpegQuality = jpegQuality
        self.preferJPEG = preferJPEG
    }

    /// The quality used when a photo is re-encoded without compression being asked for.
    public static let defaultQuality = 0.9
}

public enum ImageProcessing {
    /// The JPEG to upload instead of `data`, or `nil` to upload `data` as it is.
    /// Compressing alone never makes a photo bigger: if the re-encoded copy isn't smaller
    /// (an already well-compressed JPEG, or a HEIC that may stay HEIC), the original is kept.
    public static func prepare(_ data: Data, options: ImageOptions) throws -> Data? {
        let needsResize: Bool = {
            guard let limit = options.maxPixelSize, let size = pixelSize(of: data) else { return false }
            return max(size.width, size.height) > CGFloat(limit)
        }()
        let mustConvert = options.preferJPEG && !Self.isJPEG(data)
        guard needsResize || mustConvert || options.jpegQuality != nil else { return nil }

        let output = try jpeg(from: data, maxPixelSize: needsResize ? options.maxPixelSize : nil,
                              quality: options.jpegQuality ?? ImageOptions.defaultQuality)
        if !needsResize && !mustConvert && output.count >= data.count { return nil }
        return output
    }


    public enum Failure: Error, LocalizedError {
        case unreadable
        case encodeFailed
        public var errorDescription: String? {
            switch self {
            case .unreadable: return "The image couldn't be read."
            case .encodeFailed: return "The image couldn't be converted to JPEG."
            }
        }
    }

    /// Whether the bytes are already a JPEG.
    public static func isJPEG(_ data: Data) -> Bool {
        data.count > 3 && data[data.startIndex] == 0xFF && data[data.startIndex + 1] == 0xD8
    }

    /// Re-encodes an image as JPEG, keeping its metadata (capture date, location) and
    /// applying its orientation. With `maxPixelSize`, the long edge is scaled down to it;
    /// smaller images are left at their size.
    public static func jpeg(from data: Data, maxPixelSize: Int? = nil, quality: Double = ImageOptions.defaultQuality) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { throw Failure.unreadable }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let longEdge = max(width, height)
        let target = maxPixelSize.map { min($0, longEdge > 0 ? longEdge : $0) } ?? longEdge

        // The thumbnail API applies the EXIF orientation and scales in one step.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(target, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw Failure.unreadable
        }

        var metadata = properties
        // The pixels are already upright, so the orientation tag must say so.
        metadata[kCGImagePropertyOrientation] = 1
        if var tiff = metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            metadata[kCGImagePropertyTIFFDictionary] = tiff
        }
        metadata[kCGImagePropertyPixelWidth] = nil
        metadata[kCGImagePropertyPixelHeight] = nil
        metadata[kCGImageDestinationLossyCompressionQuality] = quality

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Failure.encodeFailed
        }
        CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encodeFailed }
        return output as Data
    }

    /// The pixel size of an image, without decoding it.
    public static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: width, height: height)
    }
}
