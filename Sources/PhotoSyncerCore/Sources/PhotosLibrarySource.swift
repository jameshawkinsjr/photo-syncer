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
public struct PhotosAlbumSource: PhotoSource {
    public let localIdentifier: String

    public init(localIdentifier: String) { self.localIdentifier = localIdentifier }

    private func album() throws -> PHAssetCollection {
        guard PhotosLibrary.isAuthorized else {
            throw SyncError.unexpected("Photo Syncer isn't allowed to read your Photos library. Allow it in System Settings › Privacy & Security › Photos.")
        }
        guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            throw SyncError.unexpected("The Photos album was deleted or renamed. Pick it again in the mapping.")
        }
        return album
    }

    public func items() async throws -> [SourceItem] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let assets = PHAsset.fetchAssets(in: try album(), options: options)
        var items: [SourceItem] = []
        items.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            let resources = PHAssetResource.assetResources(for: asset)
            let original = resources.first { $0.type == .photo } ?? resources.first
            let name = original?.originalFilename ?? "Photo.jpg"
            items.append(SourceItem(key: asset.localIdentifier, fileName: name, date: asset.creationDate))
        }
        return items.sorted { ($0.date ?? .distantPast, $0.key) < ($1.date ?? .distantPast, $1.key) }
    }

    public func originalMD5(of item: SourceItem) throws -> String? { nil }

    public func payload(for item: SourceItem, maxPixelSize: Int?, preferJPEG: Bool) async throws -> UploadPayload {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.key], options: nil).firstObject else {
            throw SyncError.unexpected("\(item.fileName) is no longer in the Photos library.")
        }
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        let data: Data = try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    let error = info?[PHImageErrorKey] as? Error
                    continuation.resume(throwing: error ?? SyncError.unexpected("Photos couldn't export \(item.fileName)."))
                }
            }
        }

        let base = (item.fileName as NSString).deletingPathExtension
        let needsResize: Bool = {
            guard let maxPixelSize, let size = ImageProcessing.pixelSize(of: data) else { return false }
            return max(size.width, size.height) > CGFloat(maxPixelSize)
        }()
        // Frames and Pix-Star can't all show HEIC, so photos go up as JPEG.
        if !ImageProcessing.isJPEG(data) || needsResize {
            let jpeg = try ImageProcessing.jpeg(from: data, maxPixelSize: maxPixelSize)
            return UploadPayload(data: jpeg, fileName: NameMatching.uploadName(base: base, ext: "jpg"), mimeType: "image/jpeg")
        }
        return UploadPayload(data: data, fileName: NameMatching.uploadName(base: base, ext: "jpg"), mimeType: "image/jpeg")
    }
}
