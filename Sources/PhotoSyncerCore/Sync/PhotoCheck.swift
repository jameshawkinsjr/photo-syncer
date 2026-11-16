import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What a photo file holds that matters to a frame: its format, colour and extra images.
public struct ImageReport: Sendable, Equatable {
    /// "heic", "jpeg", "png", …
    public var format: String
    public var byteCount: Int
    public var width: Int
    public var height: Int
    /// EXIF orientation (1 = upright).
    public var orientation: Int
    /// "RGB", "Gray", "CMYK", "Lab".
    public var colorModel: String?
    /// The embedded colour profile's name ("sRGB IEC61966-2.1", "Display P3").
    public var profile: String?
    public var bitDepth: Int?
    public var hasAlpha: Bool
    /// Images in the file (more than one: a multi-picture file).
    public var imageCount: Int
    /// Gain maps, depth and mattes (see `ImageProcessing.auxiliaryData`).
    public var auxiliary: [String]
    /// Apple's HDR tags (headroom and gain) in the maker notes.
    public var hasAppleHDRTags: Bool
    /// Average brightness as a plain viewer shows it, 0–255; `nil` if it couldn't be decoded.
    public var meanLuma: Double?

    public init?(_ data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              CGImageSourceGetCount(source) > 0 else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        format = UTType(type)?.preferredFilenameExtension ?? type
        byteCount = data.count
        width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        colorModel = properties[kCGImagePropertyColorModel] as? String
        profile = properties[kCGImagePropertyProfileName] as? String
        bitDepth = properties[kCGImagePropertyDepth] as? Int
        hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        imageCount = CGImageSourceGetCount(source)
        auxiliary = ImageProcessing.auxiliaryData(in: source)
        let maker = properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any] ?? [:]
        hasAppleHDRTags = maker["33"] != nil || maker["48"] != nil
        meanLuma = ImageProcessing.meanLuma(of: data)
    }

    public var looksBlack: Bool { (meanLuma ?? 255) < ImageProcessing.nearlyBlackLuma }

    var isWideOrUnusualColour: Bool {
        if let profile, !profile.hasPrefix("sRGB") { return true }
        if let colorModel, colorModel != "RGB" && colorModel != "Gray" { return true }
        return false
    }

    /// "heic 4032×3024 o6 RGB Display P3 8-bit, HDR gain map, Apple HDR tags, 2.1 MB, brightness 128"
    public var summary: String {
        var parts = ["\(format) \(width)×\(height)" + (orientation == 1 ? "" : " o\(orientation)")]
        parts[0] += " " + [colorModel, profile, bitDepth.map { "\($0)-bit" }].compactMap { $0 }.joined(separator: " ")
        if hasAlpha { parts.append("transparency") }
        if imageCount > 1 { parts.append("\(imageCount) images") }
        parts += auxiliary
        if hasAppleHDRTags { parts.append("Apple HDR tags") }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file))
        parts.append(meanLuma.map { String(format: "brightness %.0f", $0) } ?? "doesn't decode")
        return parts.joined(separator: ", ")
    }
}

/// One photo looked at by Check Photos: the file Photos (or the folder) gives, and the copy
/// that would be uploaded. Nothing is uploaded.
public struct PhotoCheck: Sendable, Identifiable {
    /// The photo's ledger key.
    public var key: String
    /// Its Photos local identifier (or path in the folder); never its name.
    public var reference: String
    public var fileExtension: String
    public var date: Date?
    /// How the ledger holds it, if it does ("uploaded", "matched", "markedSynced").
    public var ledgerState: Ledger.How?
    public var original: ImageReport?
    public var upload: ImageReport?
    /// The library's date had to be written into the copy.
    public var redated: Bool = false
    /// Why there's no copy to upload.
    public var error: String?

    public var id: String { key }

    public init(key: String, reference: String, fileExtension: String, date: Date?, ledgerState: Ledger.How? = nil) {
        self.key = key
        self.reference = reference
        self.fileExtension = fileExtension
        self.date = date
        self.ledgerState = ledgerState
    }

    /// Things about the original a frame's simple decoder may get wrong (the copy uploaded
    /// now leaves them out; files uploaded by hand or by an older version may still have them).
    public var risks: [String] {
        guard let original else { return [] }
        var risks: [String] = []
        if !original.auxiliary.isEmpty { risks.append(original.auxiliary.joined(separator: ", ")) }
        if original.hasAppleHDRTags { risks.append("Apple HDR tags") }
        if original.isWideOrUnusualColour { risks.append([original.colorModel, original.profile].compactMap { $0 }.joined(separator: " ")) }
        if let depth = original.bitDepth, depth > 8 { risks.append("\(depth)-bit") }
        if original.hasAlpha { risks.append("transparency") }
        if original.imageCount > 1 { risks.append("\(original.imageCount) images in one file") }
        if !["jpeg", "jpg"].contains(original.format) { risks.append(original.format.uppercased()) }
        return risks
    }

    /// What's wrong with the copy that would be uploaded; empty when it's a plain, visible JPEG.
    public var problems: [String] {
        if let error { return [error] }
        guard let upload else { return ["no copy to upload"] }
        var problems: [String] = []
        if upload.meanLuma == nil { problems.append("doesn't decode") }
        if upload.looksBlack && !(original?.looksBlack ?? false) { problems.append("comes out black") }
        if !["jpeg", "jpg"].contains(upload.format) { problems.append("is \(upload.format.uppercased()), not JPEG") }
        if upload.isWideOrUnusualColour { problems.append("isn't sRGB") }
        if let depth = upload.bitDepth, depth != 8 { problems.append("is \(depth)-bit") }
        if upload.hasAlpha { problems.append("has transparency") }
        if !upload.auxiliary.isEmpty { problems.append("still has " + upload.auxiliary.joined(separator: ", ")) }
        if upload.imageCount > 1 { problems.append("has \(upload.imageCount) images") }
        return problems
    }

    public var isOK: Bool { problems.isEmpty }

    /// One line for the log: ids and formats only, never the photo's name.
    public var logLine: String {
        var line = "Check Photos: \(reference) .\(fileExtension)"
        if let date { line += " " + PhotoCheck.stamp.string(from: date) }
        line += " | original: " + (original?.summary ?? "couldn't be read")
        if let upload { line += " | upload: " + upload.summary + (redated ? ", library date written in" : "") }
        line += " | " + (isOK ? "OK" : problems.joined(separator: "; "))
        if let ledgerState { line += " | ledger: \(ledgerState.rawValue)" }
        return line
    }

    static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

public enum PhotoDiagnostics {
    /// Days typed as "2024-06-01, 2024-06-15" (commas, spaces or new lines between them).
    /// `nil` if any of them isn't a real date.
    public static func days(from text: String) -> [DateComponents]? {
        let words = text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return nil }
        var days: [DateComponents] = []
        for word in words {
            let parts = word.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            let day = DateComponents(year: parts[0], month: parts[1], day: parts[2])
            guard day.isValidDate(in: Calendar(identifier: .gregorian)) else { return nil }
            days.append(day)
        }
        return days
    }

    /// Whether `date` falls on `day`, the day before or the day after (time zones and
    /// services' dating can move a photo by a day).
    public static func isNear(_ date: Date?, _ days: [DateComponents], calendar: Calendar = .current) -> Bool {
        guard let date else { return false }
        return days.contains { day in
            guard let start = calendar.date(from: day),
                  let from = calendar.date(byAdding: .day, value: -1, to: start),
                  let to = calendar.date(byAdding: .day, value: 2, to: start) else { return false }
            return date >= from && date < to
        }
    }

    /// Whether `date` falls on one of `days` exactly.
    public static func isOn(_ date: Date?, _ days: [DateComponents], calendar: Calendar = .current) -> Bool {
        guard let date else { return false }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return days.contains { $0.year == components.year && $0.month == components.month && $0.day == components.day }
    }

    /// Looks at one Photos photo: its file, and the copy the app would upload for it.
    public static func checkPhotosLibraryPhoto(_ data: Data, date: Date?, options: ImageOptions, into check: inout PhotoCheck) {
        check.original = ImageReport(data)
        do {
            let result = try PhotosAlbumSource.uploadData(from: data, date: date, options: options, refusingBlack: false)
            check.upload = ImageReport(result.data)
            check.redated = result.redated
        } catch {
            check.error = error.localizedDescription
        }
    }
}

extension SyncEngine {
    /// Check Photos: looks at the photos of a mapping's source taken within a day of `days`,
    /// and at the copies that would be uploaded for them, writing a line per photo to the log.
    /// Nothing is uploaded or changed.
    public func checkPhotos(_ mapping: Mapping, account: Account, days: [DateComponents],
                            progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> [PhotoCheck] {
        let source = source(for: mapping.source)
        progress("Reading \(mapping.source.shortName)…")
        let items = try await source.items().filter { PhotoDiagnostics.isNear($0.date, days) }
        var ledger = ledger(for: mapping)
        ledger.reconcile(items)
        let options = ImageOptions(maxPixelSize: account.maxPixelSize, jpegQuality: account.jpegQuality,
                                   preferJPEG: account.service.uploadsAsJPEG)
        let dayList = days.map { String(format: "%04d-%02d-%02d", $0.year ?? 0, $0.month ?? 0, $0.day ?? 0) }.joined(separator: ", ")
        log.write("Check Photos: \(mapping.source.displayName) → \(mapping.destination.name) on \(account.name): \(items.count) photos within a day of \(dayList)")

        var checks: [PhotoCheck] = []
        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            progress("Checking photo \(index + 1) of \(items.count)…")
            var check = PhotoCheck(key: item.key, reference: item.assetIdentifier ?? item.key,
                                   fileExtension: (item.fileName as NSString).pathExtension.lowercased(),
                                   date: item.date, ledgerState: ledger.entries[item.key]?.how)
            do {
                let data = try await source.originalData(for: item)
                if case .photosAlbum = mapping.source {
                    PhotoDiagnostics.checkPhotosLibraryPhoto(data, date: item.date, options: options, into: &check)
                } else {
                    check.original = ImageReport(data)
                    let payload = try await source.payload(for: item, options: options)
                    check.upload = ImageReport(payload.data)
                }
            } catch {
                check.error = error.localizedDescription
            }
            log.write(check.logLine)
            checks.append(check)
        }
        let bad = checks.filter { !$0.isOK }.count
        log.write("Check Photos: done, \(checks.count) checked, \(bad) with a problem in the copy that would be uploaded")
        return checks
    }

    /// Forgets that these photos were pushed by `mapping`, so its next sync uploads them again
    /// (the person deletes the bad copies from the service first; the app never deletes).
    public func uploadAgain(_ keys: [String], in mapping: Mapping) throws {
        guard !keys.isEmpty else { return }
        var ledger = ledger(for: mapping)
        ledger.uploadAgain(keys)
        try ledgers.save(ledger, for: mapping.id)
        log.write("\(mapping.source.displayName) → \(mapping.destination.name): \(keys.count) photos will be uploaded again on the next sync")
    }
}
