import Foundation

/// An album (or folder) in an account, for the destination picker.
public struct RemoteAlbum: Identifiable, Hashable, Sendable {
    public var ref: DestinationRef
    public var count: Int?
    /// Why uploads may not work here (for example a Pix-Star album managed by a multi-frame account).
    public var note: String?

    public var id: String { ref.id }

    public init(ref: DestinationRef, count: Int? = nil, note: String? = nil) {
        self.ref = ref
        self.count = count
        self.note = note
    }
}

/// A photo already in a destination.
public struct RemoteItem: Hashable, Sendable {
    public var id: String
    public var name: String
    /// The name in comparable form (see `NameMatching`).
    public var nameKey: String
    public var md5: String?

    public init(id: String, name: String, nameKey: String? = nil, md5: String? = nil) {
        self.id = id
        self.name = name
        self.nameKey = nameKey ?? NameMatching.key(name)
        self.md5 = md5
    }
}

public struct UploadResult: Sendable {
    public var remoteId: String?
    public var remoteName: String
    /// The photo was already in the account and was added to this album rather than uploaded.
    public var deduplicated: Bool

    public init(remoteId: String?, remoteName: String, deduplicated: Bool = false) {
        self.remoteId = remoteId
        self.remoteName = remoteName
        self.deduplicated = deduplicated
    }
}

/// One account's albums, contents and uploads.
public protocol RemoteService: Sendable {
    var kind: ServiceKind { get }
    /// How many photos `upload` takes at once.
    var preferredBatchSize: Int { get }
    /// How many `upload` calls may run at the same time.
    var maxParallelUploads: Int { get }

    /// Checks the sign-in and returns who is signed in, if the service says.
    func verify() async throws -> String?
    func albums() async throws -> [RemoteAlbum]
    func createAlbum(named name: String) async throws -> DestinationRef
    func items(in destination: DestinationRef) async throws -> [RemoteItem]
    /// Uploads photos into an album. One result per payload, in order.
    func upload(_ payloads: [UploadPayload], to destination: DestinationRef) async -> [Result<UploadResult, Error>]
    /// The photo's bytes and file name, for backing an album up.
    func download(_ item: RemoteItem) async throws -> (Data, String)
}

extension RemoteService {
    public var maxParallelUploads: Int { 3 }

    public func download(_ item: RemoteItem) async throws -> (Data, String) {
        throw SyncError.unexpected("\(kind.displayName) doesn't support downloading yet.")
    }
}
