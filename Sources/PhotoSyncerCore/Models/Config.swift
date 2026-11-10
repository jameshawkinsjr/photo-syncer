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

    public init(id: UUID = UUID(), service: ServiceKind, name: String, folderPath: String? = nil,
                signedInAs: String? = nil, maxPixelSize: Int? = nil) {
        self.id = id
        self.service = service
        self.name = name
        self.folderPath = folderPath
        self.signedInAs = signedInAs
        self.maxPixelSize = maxPixelSize ?? (service == .pixstar ? 2048 : nil)
    }
}

/// Where photos come from.
public enum SourceRef: Codable, Hashable, Sendable {
    /// A folder on disk (for example ~/Pictures/Frames/Family). Sub-folders are included.
    case folder(path: String)
    /// An album in the Photos library, by its local identifier, with its path for display
    /// ("Frames › Family").
    case photosAlbum(localIdentifier: String, title: String)

    public var displayName: String {
        switch self {
        case .folder(let path):
            return (path as NSString).abbreviatingWithTildeInPath
        case .photosAlbum(_, let title):
            return "Photos › " + title
        }
    }

    public var shortName: String {
        switch self {
        case .folder(let path): return (path as NSString).lastPathComponent
        case .photosAlbum(_, let title): return title.components(separatedBy: " › ").last ?? title
        }
    }
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

/// Everything the person has set up. Saved as JSON in Application Support.
public struct AppConfig: Codable, Sendable {
    public var accounts: [Account] = []
    public var mappings: [Mapping] = []
    public var google: GoogleClientConfig?
    /// A first sync that would upload more than this many photos waits for the person to
    /// confirm it (or mark the photos as already there).
    public var firstSyncReviewThreshold: Int = 50

    public init() {}

    public func account(_ id: UUID) -> Account? { accounts.first { $0.id == id } }
}
