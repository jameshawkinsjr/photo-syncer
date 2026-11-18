import Foundation

/// A published build, as `latest.json` in the release folder describes it:
///
///     {
///       "version": "1.2.0",                       shown to the person; not compared
///       "build": 42,                              what decides "newer" (the git commit count)
///       "file": "Photo-Syncer-1.2.0-42.dmg",      the disk image, next to latest.json
///       "sha256": "…64 hex digits…",              of that disk image
///       "publishedAt": "2026-01-02T03:04:05Z",
///       "notes": "Optional, one or two lines."
///     }
///
/// `scripts/publish.sh` writes it, after the disk image is in place.
public struct ReleaseInfo: Codable, Equatable, Sendable {
    public var version: String
    public var build: Int
    public var file: String
    public var sha256: String
    public var publishedAt: Date?
    public var notes: String?

    public init(version: String, build: Int, file: String, sha256: String, publishedAt: Date? = nil, notes: String? = nil) {
        self.version = version
        self.build = build
        self.file = file
        self.sha256 = sha256
        self.publishedAt = publishedAt
        self.notes = notes
    }

    /// The name of the file releases are announced in.
    public static let fileName = "latest.json"

    /// Whether this release should replace an app with the given build number.
    public func isNewer(than build: Int) -> Bool { self.build > build }

    /// "1.2.0 (build 42)".
    public var label: String { "\(version) (build \(build))" }

    /// Reads `latest.json`. Everything the updater relies on is checked here, so a release
    /// that decodes is safe to act on: the build is a positive number, the checksum looks
    /// like one, and the file is a bare disk-image name (never a path out of the folder).
    public static func decode(_ data: Data) throws -> ReleaseInfo {
        let release: ReleaseInfo
        do {
            release = try JSONDecoder.syncer.decode(ReleaseInfo.self, from: data)
        } catch {
            throw UpdateError.malformed(Self.describe(error))
        }
        guard !release.version.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw UpdateError.malformed("it has no version.")
        }
        guard release.build > 0 else {
            throw UpdateError.malformed("its build number isn't a positive number.")
        }
        guard release.sha256.count == 64, release.sha256.allSatisfy(\.isHexDigit) else {
            throw UpdateError.malformed("its sha256 isn't 64 hex digits.")
        }
        guard Self.isSafeFileName(release.file) else {
            throw UpdateError.malformed("its file must be the name of a .dmg in the same folder.")
        }
        return release
    }

    /// A bare ".dmg" file name: no folders, no "..", nothing hidden.
    static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains(":")
            && !name.contains("\0") && name.lowercased().hasSuffix(".dmg") && name.count > 4
    }

    private static func describe(_ error: Error) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch error as? DecodingError {
        case .keyNotFound(let key, _): return "it has no \(key.stringValue)."
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "its \(path(context)) is the wrong kind of value."
        case .dataCorrupted(let context) where !context.codingPath.isEmpty:
            return "its \(path(context)) can't be read."
        default: return "it isn't valid JSON."
        }
    }
}

public enum UpdateError: Error, LocalizedError, Equatable, Sendable {
    /// The release folder isn't there (not mounted, not synced yet, renamed).
    case folderMissing(String)
    /// The folder has no `latest.json`: nothing has been published to it.
    case noRelease(String)
    /// `latest.json` is there but can't be used; the text says why.
    case malformed(String)
    /// `latest.json` names a disk image that isn't in the folder.
    case missingImage(String)
    /// The disk image isn't the one `latest.json` describes.
    case checksumMismatch(String)
    /// A file in a cloud folder didn't download in time.
    case notDownloaded(String)

    public var errorDescription: String? {
        switch self {
        case .folderMissing(let path):
            return "The release folder \(path) can't be found."
        case .noRelease(let path):
            return "Nothing has been published to \(path) yet (it has no latest.json)."
        case .malformed(let why):
            return "The release folder's latest.json can't be used: \(why)"
        case .missingImage(let file):
            return "latest.json announces \(file), but it isn't in the release folder. If the folder is still syncing, check again in a minute."
        case .checksumMismatch(let file):
            return "\(file) doesn't match the checksum in latest.json, so it wasn't kept. If the folder is still syncing, check again in a minute."
        case .notDownloaded(let file):
            return "\(file) is in the cloud and hasn't downloaded to this Mac yet. Check again in a minute."
        }
    }
}

/// Where releases come from. The app only needs these two things, so another kind of source
/// (a URL, GitHub Releases) can be added without touching the rest of the updater.
public protocol ReleaseSource: Sendable {
    /// The newest published release.
    func latest() async throws -> ReleaseInfo
    /// Puts the release's disk image at `destination`: a copy for a folder, a download for a URL.
    /// The caller checks the result against the release's sha256.
    func fetch(_ release: ReleaseInfo, to destination: URL) async throws
}

/// Releases in a folder every Mac can reach (iCloud Drive, Dropbox, a shared drive):
/// `latest.json` and the disk images it has named, side by side.
public struct FolderReleaseSource: ReleaseSource {
    public let folder: URL
    /// How long to wait for a cloud-only file to download: `latest.json`, then the disk image.
    public var manifestTimeout: TimeInterval = 30
    public var imageTimeout: TimeInterval = 15 * 60

    public init(folder: URL) {
        self.folder = folder
    }

    public init(path: String) {
        self.init(folder: URL(fileURLWithPath: PortablePath.expand(path), isDirectory: true))
    }

    public var manifestURL: URL { folder.appendingPathComponent(ReleaseInfo.fileName) }

    public func latest() async throws -> ReleaseInfo {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw UpdateError.folderMissing(PortablePath.display(folder.path))
        }
        guard try await CloudFile.makeLocal(manifestURL, timeout: manifestTimeout) else {
            throw UpdateError.noRelease(PortablePath.display(folder.path))
        }
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw UpdateError.malformed("it can't be read.")
        }
        return try ReleaseInfo.decode(data)
    }

    /// The release's disk image: the file `latest.json` names, in the same folder.
    public func imageURL(for release: ReleaseInfo) throws -> URL {
        guard ReleaseInfo.isSafeFileName(release.file) else {
            throw UpdateError.malformed("its file must be the name of a .dmg in the same folder.")
        }
        return folder.appendingPathComponent(release.file)
    }

    public func fetch(_ release: ReleaseInfo, to destination: URL) async throws {
        let image = try imageURL(for: release)
        guard try await CloudFile.makeLocal(image, timeout: imageTimeout) else {
            throw UpdateError.missingImage(release.file)
        }
        let files = FileManager.default
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? files.removeItem(at: destination)
        try files.copyItem(at: image, to: destination)
    }
}

/// Files in iCloud Drive can be placeholders whose contents are still in the cloud.
enum CloudFile {
    /// Makes sure a file's contents are on this Mac, asking iCloud for them and waiting if
    /// they aren't. Returns false when there's no such file, here or in the cloud.
    static func makeLocal(_ url: URL, timeout: TimeInterval) async throws -> Bool {
        let files = FileManager.default
        // Before macOS 14 a file that hadn't downloaded appeared as ".<name>.icloud".
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        let exists = files.fileExists(atPath: url.path)
        guard exists || files.fileExists(atPath: placeholder.path) else { return false }
        if exists && isLocal(url) { return true }

        try? files.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if files.fileExists(atPath: url.path) && isLocal(url) { return true }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw UpdateError.notDownloaded(url.lastPathComponent)
    }

    /// True for ordinary files, and for iCloud files whose current contents are here.
    static func isLocal(_ url: URL) -> Bool {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        guard let values = try? fresh.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true else { return true }
        return values.ubiquitousItemDownloadingStatus == .current
    }
}

/// Finds a newer release and keeps a verified copy of its disk image ready to install.
/// Nothing here installs anything.
public struct UpdateChecker: Sendable {
    public let source: any ReleaseSource
    /// The build number of the running app.
    public let currentBuild: Int
    /// Where verified disk images wait to be installed.
    public let stagingDirectory: URL

    public init(source: any ReleaseSource, currentBuild: Int, stagingDirectory: URL) {
        self.source = source
        self.currentBuild = currentBuild
        self.stagingDirectory = stagingDirectory
    }

    /// The published release, if it's newer than the running app.
    public func newerRelease() async throws -> ReleaseInfo? {
        let release = try await source.latest()
        return release.isNewer(than: currentBuild) ? release : nil
    }

    /// Where a release's verified disk image is kept.
    public func stagedImage(for release: ReleaseInfo) -> URL {
        stagingDirectory.appendingPathComponent(release.file)
    }

    /// A verified copy of the release's disk image, fetched only if one isn't already here.
    /// A copy that doesn't match the release's sha256 is deleted and reported, never kept.
    public func download(_ release: ReleaseInfo) async throws -> URL {
        let staged = stagedImage(for: release)
        let files = FileManager.default
        if files.fileExists(atPath: staged.path) {
            if (try? UpdateChecker.verify(staged, sha256: release.sha256)) != nil { return staged }
            try? files.removeItem(at: staged)
        }
        try files.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let partial = stagingDirectory.appendingPathComponent(release.file + ".partial")
        defer { try? files.removeItem(at: partial) }
        try await source.fetch(release, to: partial)
        try UpdateChecker.verify(partial, sha256: release.sha256, name: release.file)
        try files.moveItem(at: partial, to: staged)
        return staged
    }

    /// Throws `checksumMismatch` unless the file's SHA-256 is the expected one.
    public static func verify(_ file: URL, sha256 expected: String, name: String? = nil) throws {
        let actual = try Hashing.sha256(of: file)
        guard actual == expected.lowercased() else {
            throw UpdateError.checksumMismatch(name ?? file.lastPathComponent)
        }
    }

    /// Deletes staged disk images other than the one to keep (all of them when it's nil).
    public func removeStaged(except keep: ReleaseInfo? = nil) {
        let files = FileManager.default
        let names = (try? files.contentsOfDirectory(atPath: stagingDirectory.path)) ?? []
        for name in names where name.lowercased().hasSuffix(".dmg") || name.hasSuffix(".partial") {
            if name == keep?.file { continue }
            try? files.removeItem(at: stagingDirectory.appendingPathComponent(name))
        }
    }
}

/// This Mac's update settings (`updates.json` in this Mac's folder; never in the shared sync data,
/// because each Mac reaches the release folder its own way and checks on its own schedule).
public struct UpdateSettings: Codable, Equatable, Sendable {
    /// The release folder, stored with `~` like every other folder path.
    public var releaseFolder: String?
    public var checkAutomatically: Bool
    public var lastChecked: Date?

    public init(releaseFolder: String? = nil, checkAutomatically: Bool = true, lastChecked: Date? = nil) {
        self.releaseFolder = releaseFolder
        self.checkAutomatically = checkAutomatically
        self.lastChecked = lastChecked
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        releaseFolder = try container.decodeIfPresent(String.self, forKey: .releaseFolder)
        checkAutomatically = try container.decodeIfPresent(Bool.self, forKey: .checkAutomatically) ?? true
        lastChecked = try container.decodeIfPresent(Date.self, forKey: .lastChecked)
    }

    /// The same settings with the folder written relative to the home folder.
    public func withPortablePath(home: String = NSHomeDirectory()) -> UpdateSettings {
        var copy = self
        copy.releaseFolder = releaseFolder.flatMap { $0.isEmpty ? nil : PortablePath.portable($0, home: home) }
        return copy
    }

    /// The release folder on this Mac, if one is set.
    public func releaseFolderURL(home: String = NSHomeDirectory()) -> URL? {
        guard let releaseFolder, !releaseFolder.isEmpty else { return nil }
        return URL(fileURLWithPath: PortablePath.expand(releaseFolder, home: home), isDirectory: true)
    }
}
