import Foundation

/// The services Photo Syncer can push photos to.
public enum ServiceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case amazon
    case google
    case pixstar
    case folder

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .amazon: return "Amazon Photos"
        case .google: return "Google Photos"
        case .pixstar: return "Pix-Star"
        case .folder: return "Folder"
        }
    }

    /// Services signed in through an embedded web view, whose cookies the app then uses.
    public var usesWebSession: Bool { self == .amazon || self == .pixstar }

    /// Whether the service keeps the exact bytes uploaded, so an MD5 identifies a photo.
    public var keepsOriginalBytes: Bool { self == .amazon || self == .folder }

    /// Whether photos are converted to JPEG for this service (frames and Pix-Star can't all show HEIC).
    public var uploadsAsJPEG: Bool { self == .pixstar || self == .google }

    /// The largest number of photos one album can usefully hold, if the service has a limit.
    /// Pix-Star frames only sync the first 3,000 photos of an album.
    public var albumPhotoLimit: Int? { self == .pixstar ? 3000 : nil }
}

/// One signed-in account (or, for `.folder`, one destination folder on disk).
public struct Account: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var service: ServiceKind
    /// What the person calls it ("Pix-Star (group)", "James's Amazon").
    public var name: String
    /// For `.folder`: the folder photos are copied into.
    public var folderPath: String?
    /// Who the service says is signed in, when known (an email address).
    public var signedInAs: String?
    /// Downsize photos before upload (long edge, in pixels). Pix-Star stores small copies anyway.
    public var maxPixelSize: Int?
    /// Compress photos before upload: re-encode them as JPEG at this quality (0–1), to save
    /// space on services that count it (Google Photos). `nil` uploads them at their own quality.
    public var jpegQuality: Double?

    public init(id: UUID = UUID(), service: ServiceKind, name: String, folderPath: String? = nil,
                signedInAs: String? = nil, maxPixelSize: Int? = nil, jpegQuality: Double? = nil) {
        self.id = id
        self.service = service
        self.name = name
        self.folderPath = folderPath
        self.signedInAs = signedInAs
        self.maxPixelSize = maxPixelSize ?? (service == .pixstar ? 2048 : nil)
        self.jpegQuality = jpegQuality
    }
}

/// Where photos come from.
public enum SourceRef: Codable, Hashable, Sendable {
    /// A folder on disk, stored relative to the home folder where possible
    /// ("~/Pictures/Frames/Family") so the same mapping works on another Mac. Sub-folders are included.
    case folder(path: String)
    /// An album in the Photos library, with its path for display ("Frames › Family").
    /// `localIdentifier` only means something on the Mac that chose the album;
    /// `cloudIdentifier` (iCloud Photos) finds the same album on another Mac.
    case photosAlbum(localIdentifier: String, title: String, cloudIdentifier: String? = nil)

    public var displayName: String {
        switch self {
        case .folder(let path):
            return PortablePath.display(path)
        case .photosAlbum(_, let title, _):
            return "Photos › " + title
        }
    }

    public var shortName: String {
        switch self {
        case .folder(let path): return (path as NSString).lastPathComponent
        case .photosAlbum(_, let title, _): return title.components(separatedBy: " › ").last ?? title
        }
    }

    /// Whether two references mean the same source, whichever Mac each was made on.
    public func isSameSource(as other: SourceRef) -> Bool {
        switch (self, other) {
        case (.folder(let a), .folder(let b)):
            return PortablePath.portable(a) == PortablePath.portable(b)
        case (.photosAlbum(let localA, let titleA, let cloudA), .photosAlbum(let localB, let titleB, let cloudB)):
            if localA == localB { return true }
            if let cloudA, let cloudB { return cloudA == cloudB }
            return titleA == titleB
        default:
            return false
        }
    }

    /// For grouping mappings by source in the window.
    public var groupKey: String {
        switch self {
        case .folder(let path): return "folder:" + PortablePath.portable(path)
        case .photosAlbum(_, let title, _): return "album:" + title
        }
    }
}

/// Paths stored in the settings are written relative to the home folder ("~/Pictures/…"),
/// so settings shared between Macs work whatever each Mac's user name is.
public enum PortablePath {
    public static func portable(_ path: String, home: String = NSHomeDirectory()) -> String {
        let expanded = expand(path, home: home)
        let trimmedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        if expanded == trimmedHome { return "~" }
        if expanded.hasPrefix(trimmedHome + "/") { return "~" + expanded.dropFirst(trimmedHome.count) }
        return expanded
    }

    public static func expand(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        let trimmedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        return trimmedHome + path.dropFirst()
    }

    public static func display(_ path: String) -> String { portable(path) }
}

/// An album (or folder) in a remote account.
public struct DestinationRef: Codable, Hashable, Sendable {
    /// The service's id for it: an Amazon folder or album node id, a Pix-Star album number,
    /// a Google album id, or a path for a folder account.
    public var id: String
    public var name: String
    /// Amazon: the folder that backs a folder-based ("smart") album, where uploads go.
    public var uploadFolderId: String?
    /// Amazon: a plain album, so each upload is also added to the album itself.
    public var addsToAlbum: Bool

    public init(id: String, name: String, uploadFolderId: String? = nil, addsToAlbum: Bool = false) {
        self.id = id
        self.name = name
        self.uploadFolderId = uploadFolderId
        self.addsToAlbum = addsToAlbum
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        uploadFolderId = try container.decodeIfPresent(String.self, forKey: .uploadFolderId)
        addsToAlbum = try container.decodeIfPresent(Bool.self, forKey: .addsToAlbum) ?? false
    }
}

/// "Push the photos in this source to this album in this account."
public struct Mapping: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var source: SourceRef
    public var accountId: UUID
    public var destination: DestinationRef
    public var enabled: Bool
    /// Pix-Star: albums created when the first one is full ("Family 2", ...), in order.
    public var overflowDestinations: [DestinationRef]
    /// Never synced, or the person hasn't reviewed the first sync yet.
    public var lastSynced: Date?

    public init(id: UUID = UUID(), source: SourceRef, accountId: UUID, destination: DestinationRef,
                enabled: Bool = true, overflowDestinations: [DestinationRef] = [], lastSynced: Date? = nil) {
        self.id = id
        self.source = source
        self.accountId = accountId
        self.destination = destination
        self.enabled = enabled
        self.overflowDestinations = overflowDestinations
        self.lastSynced = lastSynced
    }

    /// Every album this mapping writes to, the first one first.
    public var allDestinations: [DestinationRef] { [destination] + overflowDestinations }
}

/// Google needs an OAuth client of the person's own (see README, Google Photos).
public struct GoogleClientConfig: Codable, Hashable, Sendable {
    public var clientId: String
    public init(clientId: String) { self.clientId = clientId }
}

/// Everything the person has set up. Saved as config.json in the sync data folder.
public struct AppConfig: Codable, Sendable {
    public var accounts: [Account] = []
    public var mappings: [Mapping] = []
    public var google: GoogleClientConfig?
    /// A first sync that would upload more than this many photos waits for the person to
    /// confirm it (or mark the photos as already there).
    public var firstSyncReviewThreshold: Int = 50

    public init() {}

    public func account(_ id: UUID) -> Account? { accounts.first { $0.id == id } }

    /// The same settings with every folder path written relative to the home folder.
    public func withPortablePaths(home: String = NSHomeDirectory()) -> AppConfig {
        var copy = self
        for index in copy.accounts.indices {
            if let path = copy.accounts[index].folderPath {
                copy.accounts[index].folderPath = PortablePath.portable(path, home: home)
            }
        }
        for index in copy.mappings.indices {
            if case .folder(let path) = copy.mappings[index].source {
                copy.mappings[index].source = .folder(path: PortablePath.portable(path, home: home))
            }
        }
        return copy
    }
}
