import Foundation

/// A folder on this Mac (or a mounted share) that photos are copied into, one sub-folder
/// per "album". Useful for anything that reads photos from disk, such as a home dashboard.
///
/// Each album folder also gets an `index.json` listing its photos, newest first, so a
/// dashboard can read one file instead of scanning the folder.
public struct FolderDestinationService: RemoteService {
    public let kind = ServiceKind.folder
    public let preferredBatchSize = 8
    public let root: URL

    public init(path: String) {
        root = URL(fileURLWithPath: PortablePath.expand(path), isDirectory: true)
    }

    public func verify() async throws -> String? {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.path
    }

    public func albums() async throws -> [RemoteAlbum] {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let contents = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                                    options: [.skipsHiddenFiles])
        return contents.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { url in
                let count = (try? FileManager.default.contentsOfDirectory(atPath: url.path))?
                    .filter { NameMatching.isImage(URL(fileURLWithPath: $0)) }.count
                return RemoteAlbum(ref: DestinationRef(id: url.lastPathComponent, name: url.lastPathComponent), count: count)
            }
    }

    public func createAlbum(named name: String) async throws -> DestinationRef {
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(safe, isDirectory: true), withIntermediateDirectories: true)
        return DestinationRef(id: safe, name: safe)
    }

    private func folder(_ destination: DestinationRef) -> URL {
        root.appendingPathComponent(destination.id, isDirectory: true)
    }

    public func items(in destination: DestinationRef) async throws -> [RemoteItem] {
        let folder = folder(destination)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.filter { NameMatching.isImage(URL(fileURLWithPath: $0)) }.map { RemoteItem(id: $0, name: $0) }
    }

    public func upload(_ payloads: [UploadPayload], to destination: DestinationRef) async -> [Result<UploadResult, Error>] {
        let folder = folder(destination)
        let results: [Result<UploadResult, Error>] = payloads.map { payload in
            Result {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let target = uniqueURL(in: folder, for: payload.fileName)
                try payload.data.write(to: target, options: .atomic)
                return UploadResult(remoteId: target.lastPathComponent, remoteName: target.lastPathComponent)
            }
        }
        writeIndex(folder)
        return results
    }

    private func uniqueURL(in folder: URL, for name: String) -> URL {
        var candidate = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    /// index.json: `{"updated": "...", "photos": [{"file": "...", "added": "..."}]}`, newest first.
    private func writeIndex(_ folder: URL) {
        let keys: [URLResourceKey] = [.creationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
        let formatter = ISO8601DateFormatter()
        let photos = files.filter(NameMatching.isImage).map { url -> (String, Date) in
            (url.lastPathComponent, (try? url.resourceValues(forKeys: Set(keys)).creationDate) ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        let index: [String: Any] = [
            "updated": formatter.string(from: Date()),
            "photos": photos.map { ["file": $0.0, "added": formatter.string(from: $0.1)] },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("index.json"), options: .atomic)
        }
    }
}
