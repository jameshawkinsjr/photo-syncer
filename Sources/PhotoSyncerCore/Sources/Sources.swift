import Foundation

/// The bytes to upload for one photo.
public struct UploadPayload: Sendable {
    public var data: Data
    public var fileName: String
    public var mimeType: String
    public var md5: String

    public init(data: Data, fileName: String, mimeType: String) {
        self.data = data
        self.fileName = fileName
        self.mimeType = mimeType
        self.md5 = Hashing.md5(data)
    }
}

/// One photo in a source.
public struct SourceItem: Sendable, Hashable {
    /// Stable identity within the source: a path relative to the folder, or a Photos local identifier.
    public var key: String
    /// The file name it would be uploaded with.
    public var fileName: String
    /// For folder items: the file on disk.
    public var fileURL: URL?
    /// When it was taken or added, for ordering uploads oldest first.
    public var date: Date?
    /// Other keys the same photo may have been recorded under (its Mac-only Photos id, when
    /// `key` is its iCloud id).
    public var aliases: [String]
    /// For Photos items: the asset's id on this Mac.
    public var assetIdentifier: String?

    public init(key: String, fileName: String, fileURL: URL? = nil, date: Date? = nil,
                aliases: [String] = [], assetIdentifier: String? = nil) {
        self.key = key
        self.fileName = fileName
        self.fileURL = fileURL
        self.date = date
        self.aliases = aliases
        self.assetIdentifier = assetIdentifier
    }
}

/// A place photos come from.
public protocol PhotoSource: Sendable {
    func items() async throws -> [SourceItem]
    /// MD5 of the bytes `payload` would return without resizing, if it can be known cheaply
    /// (folder files: yes, from a cache; Photos exports: no).
    func originalMD5(of item: SourceItem) throws -> String?
    /// The photo's size on disk, if it can be known without reading it.
    func fileSize(of item: SourceItem) -> Int64?
    /// The photo's bytes as they are, before any resizing, compression or conversion.
    func originalData(for item: SourceItem) async throws -> Data
    /// The bytes to upload, downsized, compressed or converted to JPEG as `options` asks.
    func payload(for item: SourceItem, options: ImageOptions) async throws -> UploadPayload
}

/// A folder on disk; sub-folders included, hidden files skipped.
public struct FolderSource: PhotoSource {
    public let root: URL
    let md5Cache: MD5Cache

    public init(path: String, md5Cache: MD5Cache) {
        root = URL(fileURLWithPath: PortablePath.expand(path), isDirectory: true)
        self.md5Cache = md5Cache
    }

    public func items() async throws -> [SourceItem] {
        try scan()
    }

    private func scan() throws -> [SourceItem] {
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw SyncError.unexpected("The folder \(root.path) doesn't exist.")
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .creationDateKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }
        let rootPath = root.standardizedFileURL.path
        var result: [SourceItem] = []
        for case let url as URL in enumerator {
            guard NameMatching.isImage(url),
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            var relative = url.standardizedFileURL.path
            if relative.hasPrefix(rootPath) { relative.removeFirst(rootPath.count) }
            if relative.hasPrefix("/") { relative.removeFirst() }
            result.append(SourceItem(key: relative, fileName: url.lastPathComponent, fileURL: url,
                                     date: values.creationDate ?? values.contentModificationDate))
        }
        return result.sorted { ($0.date ?? .distantPast, $0.key) < ($1.date ?? .distantPast, $1.key) }
    }

    /// The file names in the folder and its sub-folders.
    func scanNames() throws -> [String] { try scan().map(\.fileName) }

    public func originalMD5(of item: SourceItem) throws -> String? {
        guard let url = item.fileURL else { return nil }
        return try md5Cache.md5(of: url)
    }

    public func fileSize(of item: SourceItem) -> Int64? {
        guard let url = item.fileURL,
              let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    public func originalData(for item: SourceItem) async throws -> Data {
        guard let url = item.fileURL else { throw SyncError.unexpected("No file for \(item.key)") }
        return try Data(contentsOf: url)
    }

    public func payload(for item: SourceItem, options: ImageOptions) async throws -> UploadPayload {
        guard let url = item.fileURL else { throw SyncError.unexpected("No file for \(item.key)") }
        let data = try await originalData(for: item)
        if let jpeg = try ImageProcessing.prepare(data, options: options) {
            let base = (item.fileName as NSString).deletingPathExtension
            return UploadPayload(data: jpeg, fileName: NameMatching.uploadName(base: base, ext: "jpg"), mimeType: "image/jpeg")
        }
        return UploadPayload(data: data, fileName: item.fileName, mimeType: Self.mimeType(for: url.pathExtension))
    }

    static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "gif": return "image/gif"
        case "tif", "tiff": return "image/tiff"
        case "webp": return "image/webp"
        case "bmp": return "image/bmp"
        default: return "application/octet-stream"
        }
    }
}
