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
    /// Convert HEIC, PNG and the like, and any JPEG that isn't plain 8-bit sRGB, to a plain JPEG.
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
    /// With `preferJPEG`, anything but a plain JPEG (`isPlainJPEG`) is converted, including
    /// JPEGs that are wide-gamut, HDR or carry depth data.
    public static func prepare(_ data: Data, options: ImageOptions) throws -> Data? {
        let needsResize: Bool = {
            guard let limit = options.maxPixelSize, let size = pixelSize(of: data) else { return false }
            return max(size.width, size.height) > CGFloat(limit)
        }()
        let mustConvert = options.preferJPEG && !Self.isPlainJPEG(data)
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

    /// Re-encodes an image as a plain JPEG: 8-bit sRGB, opaque, upright, with only its
    /// portable metadata (capture date, location, camera, caption). With `maxPixelSize`, the
    /// long edge is scaled down to it; smaller images are left at their size.
    ///
    /// Frames are simple decoders, so everything else is dropped: wide-gamut and HDR colour
    /// (converted to sRGB), HDR gain maps, depth and portrait mattes, transparency (flattened
    /// onto white), 16-bit samples, and vendor metadata such as Apple's HDR tags.
    public static func jpeg(from data: Data, maxPixelSize: Int? = nil, quality: Double = ImageOptions.defaultQuality) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { throw Failure.unreadable }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let longEdge = max(width, height)
        let target = maxPixelSize.map { min($0, longEdge > 0 ? longEdge : $0) } ?? longEdge

        // The thumbnail API applies the EXIF orientation and scales in one step. It decodes the
        // standard (SDR) rendition; a gain map is never applied.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(target, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw Failure.unreadable
        }
        let image = try flattened(decoded)

        var metadata = portableMetadata(properties, width: image.width, height: image.height)
        metadata[kCGImageDestinationLossyCompressionQuality] = quality

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Failure.encodeFailed
        }
        CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encodeFailed }
        return output as Data
    }

    /// The image drawn into an opaque 8-bit sRGB bitmap: colour converted from any profile,
    /// transparency flattened onto white, deeper samples reduced to 8 bits.
    static func flattened(_ image: CGImage) throws -> CGImage {
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw Failure.encodeFailed
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        guard let result = context.makeImage() else { throw Failure.encodeFailed }
        return result
    }

    /// The metadata worth keeping in a converted photo: EXIF (when and how it was taken), GPS,
    /// TIFF (camera, date) and IPTC (captions), with the orientation reset to upright and the
    /// size and colour space set to the new image's. Vendor dictionaries (Apple's HDR tags),
    /// colour profile names and auxiliary-image descriptions are left behind.
    static func portableMetadata(_ properties: [CFString: Any], width: Int, height: Int) -> [CFString: Any] {
        var metadata: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = width
            exif[kCGImagePropertyExifPixelYDimension] = height
            exif[kCGImagePropertyExifColorSpace] = 1 // sRGB
            exif[kCGImagePropertyExifMakerNote] = nil
            metadata[kCGImagePropertyExifDictionary] = exif
        }
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            metadata[kCGImagePropertyTIFFDictionary] = tiff
        }
        for key in [kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            if let value = properties[key] { metadata[key] = value }
        }
        return metadata
    }

    /// Whether the bytes are a JPEG any frame can show as it is: one 8-bit image, sRGB (or
    /// untagged), opaque, RGB or grey, with no gain map, depth or matte images inside.
    /// iPhone HDR JPEGs, Display P3 JPEGs and the like aren't.
    public static func isPlainJPEG(_ data: Data) -> Bool {
        guard isJPEG(data),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
        if let depth = properties[kCGImagePropertyDepth] as? Int, depth != 8 { return false }
        if properties[kCGImagePropertyHasAlpha] as? Bool == true { return false }
        if let model = properties[kCGImagePropertyColorModel] as? String,
           model != (kCGImagePropertyColorModelRGB as String) && model != (kCGImagePropertyColorModelGray as String) { return false }
        if let profile = properties[kCGImagePropertyProfileName] as? String, !profile.hasPrefix("sRGB") { return false }
        return auxiliaryData(in: source).isEmpty
    }

    /// The auxiliary images a photo carries, by name: "HDR gain map", "depth", and so on.
    public static func auxiliaryData(of data: Data) -> [String] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [] }
        return auxiliaryData(in: source)
    }

    static func auxiliaryData(in source: CGImageSource) -> [String] {
        guard CGImageSourceGetCount(source) > 0 else { return [] }
        var kinds: [(CFString, String)] = [(kCGImageAuxiliaryDataTypeHDRGainMap, "HDR gain map")]
        if #available(macOS 15, *) { kinds.append((kCGImageAuxiliaryDataTypeISOGainMap, "ISO gain map")) }
        kinds += [
            (kCGImageAuxiliaryDataTypeDepth, "depth"),
            (kCGImageAuxiliaryDataTypeDisparity, "disparity"),
            (kCGImageAuxiliaryDataTypePortraitEffectsMatte, "portrait matte"),
            (kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte, "skin matte"),
            (kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte, "hair matte"),
            (kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte, "teeth matte"),
            (kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte, "glasses matte"),
            (kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte, "sky matte"),
        ]
        return kinds.compactMap { type, name in
            CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) != nil ? name : nil
        }
    }

    // MARK: Brightness

    /// The average brightness (0 = black, 255 = white) of the image as a plain viewer shows
    /// it: upright, in sRGB, with any transparency over black. `nil` if it can't be decoded.
    public static func meanLuma(of data: Data) -> Double? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: sRGB,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var total = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            total += 0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.0722 * Double(pixels[index + 2])
        }
        return total / Double(side * side)
    }

    /// Below this average brightness a photo shows as black.
    public static let nearlyBlackLuma = 8.0

    public static func looksBlack(_ data: Data) -> Bool {
        guard let luma = meanLuma(of: data) else { return false }
        return luma < nearlyBlackLuma
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
