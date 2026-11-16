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
    /// Photos the person asked to upload again (their copy in the destination was bad and has
    /// been deleted). The next sync uploads them without matching them to anything already
    /// there, since a leftover copy with the same name would otherwise count as "already there".
    public var reupload: Set<String> = []
    /// Keys renamed away since loading, so a merge on save doesn't bring them back.
    var removed: Set<String> = []

    enum CodingKeys: String, CodingKey { case entries, reupload }

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decode([String: Entry].self, forKey: .entries)
        reupload = try container.decodeIfPresent(Set<String>.self, forKey: .reupload) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entries, forKey: .entries)
        if !reupload.isEmpty { try container.encode(reupload.sorted(), forKey: .reupload) }
    }

    public func contains(_ key: String) -> Bool { entries[key] != nil }

    public mutating func record(_ key: String, _ entry: Entry) {
        entries[key] = entry
        removed.remove(key)
        reupload.remove(key)
    }

    /// Forgets that these photos were pushed, so the next sync uploads them again (see `reupload`).
    public mutating func uploadAgain(_ keys: [String]) {
        for key in keys {
            entries.removeValue(forKey: key)
            removed.insert(key)
            reupload.insert(key)
        }
    }

    /// Moves an entry to a new key (a photo's Mac-only id to its iCloud id).
    public mutating func rename(_ oldKey: String, to newKey: String) {
        guard oldKey != newKey, let entry = entries.removeValue(forKey: oldKey) else { return }
        removed.insert(oldKey)
        if entries[newKey] == nil { entries[newKey] = entry }
    }

    /// Re-keys entries recorded under one of an item's other ids. Returns how many changed.
    @discardableResult
    public mutating func reconcile(_ items: [SourceItem]) -> Int {
        var changed = 0
        for item in items where !contains(item.key) {
            if let alias = item.aliases.first(where: contains) {
                rename(alias, to: item.key)
                changed += 1
            }
        }
        return changed
    }

    /// Drops "matched" entries that point at a remote photo another entry already holds: a
    /// photo matched by name to a different photo with the same name (cameras reuse names),
    /// which was then never uploaded. Entries that uploaded the photo are kept over matches.
    /// Returns how many were dropped, so the next sync uploads them.
    @discardableResult
    public mutating func releaseSharedMatches() -> Int {
        var holders: [String: [String]] = [:]
        for (key, entry) in entries {
            if let id = entry.remoteId { holders[id, default: []].append(key) }
        }
        var released = 0
        for keys in holders.values where keys.count > 1 {
            let matched = keys.filter { entries[$0]?.how == .matched }.sorted()
            // Keep one holder: an upload if there is one, else the first match.
            let drop = matched.count == keys.count ? Array(matched.dropFirst()) : matched
            for key in drop {
                entries.removeValue(forKey: key)
                removed.insert(key)
                released += 1
            }
        }
        return released
    }

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

    /// Saves a ledger, merged with what's on disk: entries another Mac added since this one
    /// loaded the file are kept, so two Macs syncing the same mapping never lose each other's work.
    public func save(_ ledger: Ledger, for mappingId: UUID) throws {
        var merged = ledger
        let onDisk = load(mappingId)
        for (key, entry) in onDisk.entries where merged.entries[key] == nil && !ledger.removed.contains(key) {
            merged.entries[key] = entry
        }
        merged.reupload.formUnion(onDisk.reupload.filter { merged.entries[$0] == nil })
        try JSONEncoder.syncer.encode(merged).write(to: url(mappingId), options: .atomic)
    }

    public func delete(_ mappingId: UUID) {
        try? FileManager.default.removeItem(at: url(mappingId))
    }
}
