import Foundation

/// What one mapping has already pushed, by source item key. A photo in the ledger is never
/// uploaded again by that mapping, even if it disappears from the destination.
public struct Ledger: Codable, Sendable {
    public enum How: String, Codable, Sendable {
        /// Photo Syncer uploaded it.
        case uploaded
        /// It was already in the destination (same MD5 or file name) on a sync.
        case matched
        /// The person said everything in the source was already there.
        case markedSynced
    }

    public struct Entry: Codable, Sendable, Equatable {
        public var how: How
        public var date: Date
        /// The album it went to (differs from the mapping's first album once Pix-Star overflows).
        public var destinationId: String?
        /// The name it has in the destination.
        public var remoteName: String?
        public var remoteId: String?

        public init(how: How, date: Date = Date(), destinationId: String? = nil, remoteName: String? = nil, remoteId: String? = nil) {
            self.how = how
            self.date = date
            self.destinationId = destinationId
            self.remoteName = remoteName
            self.remoteId = remoteId
        }
    }

    public var entries: [String: Entry] = [:]

    public init() {}

    public func contains(_ key: String) -> Bool { entries[key] != nil }

    public mutating func record(_ key: String, _ entry: Entry) { entries[key] = entry }

    public var count: Int { entries.count }

    /// How many photos this mapping has put in an album (for the Pix-Star limit).
    public func count(in destinationId: String) -> Int {
        entries.values.filter { $0.destinationId == destinationId }.count
    }
}

/// Loads and saves ledgers, one JSON file per mapping.
public struct LedgerStore: Sendable {
    public let storage: Storage

    public init(storage: Storage) { self.storage = storage }

    private func url(_ mappingId: UUID) -> URL {
        storage.ledgerDirectory.appendingPathComponent("\(mappingId.uuidString).json")
    }

    public func load(_ mappingId: UUID) -> Ledger {
        guard let data = try? Data(contentsOf: url(mappingId)) else { return Ledger() }
        return (try? JSONDecoder.syncer.decode(Ledger.self, from: data)) ?? Ledger()
    }

    public func save(_ ledger: Ledger, for mappingId: UUID) throws {
        try JSONEncoder.syncer.encode(ledger).write(to: url(mappingId), options: .atomic)
    }

    public func delete(_ mappingId: UUID) {
        try? FileManager.default.removeItem(at: url(mappingId))
    }
}
