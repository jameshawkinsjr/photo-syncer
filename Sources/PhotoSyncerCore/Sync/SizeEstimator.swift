import Foundation

/// How much space an account's albums take, and would take at each compression level.
public struct SizeEstimate: Sendable {
    public struct Row: Sendable, Identifiable {
        /// The JPEG quality, or `nil` for "no compression" (only the account's downsizing and
        /// any HEIC-to-JPEG conversion the service needs).
        public var quality: Double?
        /// Every photo in the account's albums.
        public var totalBytes: Int64
        /// Only the photos not uploaded yet.
        public var pendingBytes: Int64
        public var id: String { quality.map { "\($0)" } ?? "none" }
    }

    /// Photos across the account's albums (a photo in two albums counts once).
    public var photoCount: Int
    /// Of those, photos no mapping of this account has pushed yet.
    public var pendingCount: Int
    /// The photos' size as they are (Photos' current versions, or the files on disk).
    public var originalBytes: Int64
    public var pendingOriginalBytes: Int64
    /// How many photos were actually exported and compressed to work out the ratios.
    public var sampled: Int
    public var rows: [Row]
}

extension SyncEngine {
    /// Estimates the size of everything `account`'s mappings sync. Sizes come from the
    /// library or file system; compressed sizes are worked out by really compressing a
    /// spread-out sample of photos and scaling up (exporting every photo would mean
    /// downloading the whole album from iCloud).
    public func estimateSizes(for account: Account, mappings: [Mapping], maxPixelSize: Int?,
                              qualities: [Double?], sampleSize: Int = 16,
                              progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> SizeEstimate {
        let mine = mappings.filter { $0.accountId == account.id }
        guard !mine.isEmpty else { throw SyncError.unexpected("\(account.name) has no albums to sync yet.") }

        // One entry per photo: its source, and whether some mapping of this account still has to push it.
        var photos: [(item: SourceItem, source: PhotoSource, isPhotosLibrary: Bool, pending: Bool)] = []
        var indexByKey: [String: Int] = [:]
        for mapping in mine {
            progress("Reading \(mapping.source.shortName)…")
            let source = source(for: mapping.source)
            let items = try await source.items()
            var ledger = ledger(for: mapping)
            ledger.reconcile(items)
            let isPhotosLibrary: Bool = {
                if case .photosAlbum = mapping.source { return true }
                return false
            }()
            for item in items {
                let pending = !ledger.contains(item.key)
                if let index = indexByKey[item.key] {
                    if pending { photos[index].pending = true }
                } else {
                    indexByKey[item.key] = photos.count
                    photos.append((item, source, isPhotosLibrary, pending))
                }
            }
        }
        guard !photos.isEmpty else { throw SyncError.unexpected("\(account.name)'s albums have no photos.") }

        progress("Adding up \(photos.count) photos…")
        let sizes = photos.map { $0.source.fileSize(of: $0.item) }

        // Export and compress a sample spread across the albums (and their dates).
        let count = min(sampleSize, photos.count)
        let picks = Set((0..<count).map { $0 * photos.count / count })
        var sampleOriginal: Int64 = 0
        var sampleOut = [Int64](repeating: 0, count: qualities.count)
        var sampled = 0
        for (done, index) in picks.sorted().enumerated() {
            progress("Compressing sample photos (\(done + 1) of \(picks.count))…")
            let photo = photos[index]
            guard let data = try? await photo.source.originalData(for: photo.item) else { continue }
            let preferJPEG = photo.isPhotosLibrary || account.service.uploadsAsJPEG
            var outputs: [Int64] = []
            for quality in qualities {
                let options = ImageOptions(maxPixelSize: maxPixelSize, jpegQuality: quality, preferJPEG: preferJPEG)
                guard let prepared = try? ImageProcessing.prepare(data, options: options) else {
                    outputs.append(Int64(data.count))
                    continue
                }
                outputs.append(Int64(prepared.count))
            }
            sampleOriginal += Int64(data.count)
            for slot in outputs.indices { sampleOut[slot] += outputs[slot] }
            sampled += 1
        }
        guard sampled > 0, sampleOriginal > 0 else {
            throw SyncError.unexpected("None of the sample photos could be read (are they downloadable from iCloud?).")
        }

        // Photos whose size isn't known count as the average of those that are.
        let known = sizes.compactMap { $0 }
        let average = known.isEmpty ? sampleOriginal / Int64(sampled) : known.reduce(0, +) / Int64(known.count)
        var original: Int64 = 0
        var pendingOriginal: Int64 = 0
        for (photo, size) in zip(photos, sizes) {
            let bytes = size ?? average
            original += bytes
            if photo.pending { pendingOriginal += bytes }
        }

        let rows = qualities.indices.map { slot -> SizeEstimate.Row in
            let ratio = Double(sampleOut[slot]) / Double(sampleOriginal)
            return .init(quality: qualities[slot], totalBytes: Int64(Double(original) * ratio),
                         pendingBytes: Int64(Double(pendingOriginal) * ratio))
        }
        return SizeEstimate(photoCount: photos.count, pendingCount: photos.filter(\.pending).count,
                            originalBytes: original, pendingOriginalBytes: pendingOriginal,
                            sampled: sampled, rows: rows)
    }
}
