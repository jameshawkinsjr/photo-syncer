import Foundation
import Photos

/// An album in the Photos library, for the album picker.
public struct PhotosAlbumNode: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    /// "Frames › Family"
    public var path: String
    /// Albums have a count; folders have children.
    public var count: Int?
    public var children: [PhotosAlbumNode]?

    public var isFolder: Bool { children != nil }

    public init(id: String, title: String, path: String, count: Int?, children: [PhotosAlbumNode]?) {
        self.id = id
        self.title = title
        self.path = path
        self.count = count
        self.children = children
    }
}

public enum PhotosLibrary {
    public static var isAuthorized: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

    public static func requestAccess() async -> Bool {
        if isAuthorized { return true }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    /// Prefix of ledger keys that are iCloud Photos identifiers (the same on every Mac using the
    /// library) rather than this Mac's local identifiers.
    public static let cloudKeyPrefix = "icloud:"

    /// iCloud identifiers for local identifiers (assets or albums), where iCloud Photos knows them.
    /// Photos not yet uploaded to iCloud, and libraries without iCloud Photos, have none.
    public static func cloudIdentifiers(for localIdentifiers: [String]) -> [String: String] {
        guard isAuthorized, !localIdentifiers.isEmpty else { return [:] }
        var result: [String: String] = [:]
        let library = PHPhotoLibrary.shared()
        for start in stride(from: 0, to: localIdentifiers.count, by: 500) {
            let chunk = Array(localIdentifiers[start..<min(start + 500, localIdentifiers.count)])
            for (local, mapping) in library.cloudIdentifierMappings(forLocalIdentifiers: chunk) {
                if case .success(let cloud) = mapping { result[local] = cloud.stringValue }
            }
        }
        return result
    }

    /// This Mac's local identifier for an iCloud identifier, if the library has it.
    public static func localIdentifier(forCloud cloud: String) -> String? {
        guard isAuthorized else { return nil }
        let identifier = PHCloudIdentifier(stringValue: cloud)
        if case .success(let local) = PHPhotoLibrary.shared().localIdentifierMappings(for: [identifier])[identifier] {
            return local
        }
        return nil
    }

    /// Finds an album chosen on this or another Mac: by this Mac's id, then its iCloud id, then
    /// its path in the sidebar ("Frames › Family").
    public static func resolveAlbum(localIdentifier: String, cloudIdentifier: String?, path: String) -> PHAssetCollection? {
        if let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [localIdentifier], options: nil).firstObject {
            return album
        }
        if let cloudIdentifier, let local = self.localIdentifier(forCloud: cloudIdentifier),
           let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [local], options: nil).firstObject {
            return album
        }
        func search(_ nodes: [PhotosAlbumNode]) -> String? {
            for node in nodes {
                if !node.isFolder && node.path == path { return node.id }
                if let found = search(node.children ?? []) { return found }
            }
            return nil
        }
        guard let id = search(albumTree()) else { return nil }
        return PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
    }

    /// Whether iCloud Photos identifiers work for this library (checked on a few recent photos).
    public static func cloudIdentifiersAvailable() -> Bool {
        guard isAuthorized else { return false }
        let options = PHFetchOptions()
        options.fetchLimit = 10
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        var ids: [String] = []
        PHAsset.fetchAssets(with: .image, options: options).enumerateObjects { asset, _, _ in ids.append(asset.localIdentifier) }
        return !cloudIdentifiers(for: ids).isEmpty
    }

    /// The person's albums and folders, as Photos shows them in its sidebar.
    public static func albumTree() -> [PhotosAlbumNode] {
        let top = PHCollectionList.fetchTopLevelUserCollections(with: nil)
        return nodes(in: top, parentPath: nil)
    }

    private static func nodes(in result: PHFetchResult<PHCollection>, parentPath: String?) -> [PhotosAlbumNode] {
        var nodes: [PhotosAlbumNode] = []
        result.enumerateObjects { collection, _, _ in
            let title = collection.localizedTitle ?? "Untitled"
            let path = parentPath.map { "\($0) › \(title)" } ?? title
            if let album = collection as? PHAssetCollection {
                let options = PHFetchOptions()
                options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
                let count = PHAsset.fetchAssets(in: album, options: options).count
                nodes.append(PhotosAlbumNode(id: album.localIdentifier, title: title, path: path, count: count, children: nil))
            } else if let list = collection as? PHCollectionList {
                let children = self.nodes(in: PHCollection.fetchCollections(in: list, options: nil), parentPath: path)
                nodes.append(PhotosAlbumNode(id: list.localIdentifier, title: title, path: path, count: nil, children: children))
            }
        }
        return nodes
    }
}

/// An album in the Photos library. Photos only (videos are skipped); edits are applied;
/// photos only in iCloud are downloaded when needed.
///
/// Photos are keyed by their iCloud identifier where iCloud Photos has one, so the ledger means
/// the same thing on every Mac sharing the library; otherwise by this Mac's local identifier.
/// The local identifier is always passed as an alias, so entries recorded under it are re-keyed.
public struct PhotosAlbumSource: PhotoSource {
    public let localIdentifier: String
    public let cloudIdentifier: String?
    public let path: String

    public init(localIdentifier: String, cloudIdentifier: String? = nil, path: String = "") {
        self.localIdentifier = localIdentifier
        self.cloudIdentifier = cloudIdentifier
        self.path = path
    }

    private func album() throws -> PHAssetCollection {
        guard PhotosLibrary.isAuthorized else {
            throw SyncError.unexpected("Photo Syncer isn't allowed to read your Photos library. Allow it in System Settings › Privacy & Security › Photos.")
        }
        guard let album = PhotosLibrary.resolveAlbum(localIdentifier: localIdentifier, cloudIdentifier: cloudIdentifier, path: path) else {
            throw SyncError.unexpected("The Photos album \(path.isEmpty ? "" : "\"\(path)\" ")wasn't found on this Mac. Pick it again in the mapping.")
        }
        return album
    }

    /// The album's iCloud identifier, to store with the mapping.
    public func albumCloudIdentifier() -> String? {
        guard let album = try? album() else { return nil }
        return PhotosLibrary.cloudIdentifiers(for: [album.localIdentifier])[album.localIdentifier]
    }

    public func items() async throws -> [SourceItem] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let assets = PHAsset.fetchAssets(in: try album(), options: options)
        var found: [(asset: PHAsset, name: String)] = []
        found.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            let resources = PHAssetResource.assetResources(for: asset)
            let original = resources.first { $0.type == .photo } ?? resources.first
            found.append((asset, original?.originalFilename ?? "Photo.jpg"))
        }
        let cloud = PhotosLibrary.cloudIdentifiers(for: found.map(\.asset.localIdentifier))
        let items = found.map { asset, name -> SourceItem in
            let local = asset.localIdentifier
            if let cloudId = cloud[local] {
                return SourceItem(key: PhotosLibrary.cloudKeyPrefix + cloudId, fileName: name, date: asset.creationDate,
                                  aliases: [local], assetIdentifier: local)
            }
            return SourceItem(key: local, fileName: name, date: asset.creationDate, assetIdentifier: local)
        }
        return items.sorted { ($0.date ?? .distantPast, $0.key) < ($1.date ?? .distantPast, $1.key) }
    }

    public func originalMD5(of item: SourceItem) throws -> String? { nil }

    private func asset(for item: SourceItem) throws -> PHAsset {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.assetIdentifier ?? item.key], options: nil).firstObject else {
            throw SyncError.unexpected("\(item.fileName) is no longer in the Photos library.")
        }
        return asset
    }

    /// The size Photos records for the photo's current version (the edited one, if it was
    /// edited), without downloading it. PhotoKit only exposes this through key-value coding,
    /// so it's checked for first and is `nil` if a future macOS drops it.
    public func fileSize(of item: SourceItem) -> Int64? {
        guard let asset = try? asset(for: item) else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .fullSizePhoto }) ?? resources.first(where: { $0.type == .photo }),
              resource.responds(to: NSSelectorFromString("fileSize")) else { return nil }
        return (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value
    }

    /// The photo's current version as Photos exports it (downloaded from iCloud if needed).
    public func originalData(for item: SourceItem) async throws -> Data {
        let asset = try asset(for: item)
        let request = PHImageRequestOptions()
        request.version = .current
        request.deliveryMode = .highQualityFormat
        request.isNetworkAccessAllowed = true
        request.isSynchronous = false

        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: request) { data, _, _, info in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    let error = info?[PHImageErrorKey] as? Error
                    continuation.resume(throwing: error ?? SyncError.unexpected("Photos couldn't export \(item.fileName)."))
                }
            }
        }
    }

    public func payload(for item: SourceItem, options: ImageOptions) async throws -> UploadPayload {
        let data = try await originalData(for: item)
        let base = (item.fileName as NSString).deletingPathExtension
        // Frames and Pix-Star can't all show HEIC, so photos go up as JPEG.
        var options = options
        options.preferJPEG = true
        if let jpeg = try ImageProcessing.prepare(data, options: options) {
            return UploadPayload(data: jpeg, fileName: NameMatching.uploadName(base: base, ext: "jpg"), mimeType: "image/jpeg")
        }
        return UploadPayload(data: data, fileName: NameMatching.uploadName(base: base, ext: "jpg"), mimeType: "image/jpeg")
    }
}
