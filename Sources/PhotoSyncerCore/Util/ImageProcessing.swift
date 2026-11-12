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

    // MARK: Capture date

    /// The date a photo was taken, as written in its EXIF. With an offset (`OffsetTimeOriginal`)
    /// it's an exact moment; without one it's a wall-clock time read as if it were UTC.
    public struct CaptureDate: Sendable, Equatable {
        public var date: Date
        public var hasOffset: Bool
    }

    public static func captureDate(of data: Data) -> CaptureDate? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
              let wallClock = exifFormatter(TimeZone(secondsFromGMT: 0)!).date(from: text) else { return nil }
        if let offset = (exif[kCGImagePropertyExifOffsetTimeOriginal] as? String).flatMap(offsetSeconds) {
            return CaptureDate(date: wallClock.addingTimeInterval(TimeInterval(-offset)), hasOffset: true)
        }
        return CaptureDate(date: wallClock, hasOffset: false)
    }

    /// Whether a photo's file needs the date the library shows for it: the file has no date, or
    /// one that's clearly different (a scan's scan date, a date fixed in Photos afterwards).
    /// Without an offset the file's time could be in any time zone, so only a gap of more than
    /// 14 hours counts.
    public static func needsCaptureDate(file: CaptureDate?, library: Date) -> Bool {
        guard let file else { return true }
        let gap = abs(file.date.timeIntervalSince(library))
        return gap > (file.hasOffset ? 60 : 14 * 3600 + 60)
    }

    /// The same image with `date` written as when it was taken (EXIF and TIFF dates, with the
    /// time zone offset), so services that read the file (Google Photos, Amazon) date it right.
    /// The pixels aren't re-encoded.
    public static func settingCaptureDate(_ data: Data, to date: Date, timeZone: TimeZone = .current) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) else { throw Failure.unreadable }
        let stamp = exifFormatter(timeZone).string(from: date) as CFString
        let seconds = timeZone.secondsFromGMT(for: date)
        let offset = String(format: "%@%02d:%02d", seconds < 0 ? "-" : "+", abs(seconds) / 3600, abs(seconds) % 3600 / 60) as CFString

        let metadata = CGImageMetadataCreateMutable()
        let values: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeOriginal, stamp),
            (kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeDigitized, stamp),
            (kCGImagePropertyExifDictionary, kCGImagePropertyExifOffsetTimeOriginal, offset),
            (kCGImagePropertyExifDictionary, kCGImagePropertyExifOffsetTimeDigitized, offset),
            (kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFDateTime, stamp),
        ]
        for (dictionary, key, value) in values {
            guard CGImageMetadataSetValueMatchingImageProperty(metadata, dictionary, key, value) else { throw Failure.encodeFailed }
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else { throw Failure.encodeFailed }
        let options: [CFString: Any] = [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: true]
        // Copies the image as it is, only changing its metadata (no Finalize with this call).
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil) else { throw Failure.encodeFailed }
        return output as Data
    }

    private static func exifFormatter(_ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }

    /// "+02:00" -> 7200.
    private static func offsetSeconds(_ text: String) -> Int? {
        let parts = text.dropFirst().split(separator: ":").compactMap { Int($0) }
        guard let sign = text.first, sign == "+" || sign == "-", parts.count == 2 else { return nil }
        return (sign == "-" ? -1 : 1) * (parts[0] * 3600 + parts[1] * 60)
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
