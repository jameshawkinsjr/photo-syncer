import Foundation

/// What a sync of one mapping will do.
public struct SyncPlan: Sendable {
    public var sourceCount: Int
    /// Already in the ledger: pushed (or matched) before.
    public var alreadySynced: Int
    /// Not in the ledger but already in the destination, found by MD5 or file name.
    public var matched: [(item: SourceItem, remote: RemoteItem)]
    public var toUpload: [SourceItem]

    public init(sourceCount: Int = 0, alreadySynced: Int = 0, matched: [(item: SourceItem, remote: RemoteItem)] = [], toUpload: [SourceItem] = []) {
        self.sourceCount = sourceCount
        self.alreadySynced = alreadySynced
        self.matched = matched
        self.toUpload = toUpload
    }
}

public enum SyncPlanner {
    /// Splits a source into what's done, what's already in the destination, and what to upload.
    ///
    /// A remote photo matches a source photo with the same MD5 (when both are known) or else
    /// the same comparable name. Each remote photo matches at most one source photo, so two
    /// different "IMG_0001.jpg"s from different folders both still get uploaded once, and a
    /// remote photo the ledger already holds for another source photo is never matched again
    /// (a camera's file names repeat, so a new "IMG_1234" isn't the old one).
    public static func plan(items: [SourceItem], ledger: Ledger, remote: [RemoteItem],
                            md5: (SourceItem) -> String?) -> SyncPlan {
        var plan = SyncPlan(sourceCount: items.count)
        let fresh = items.filter { !ledger.contains($0.key) }
        plan.alreadySynced = items.count - fresh.count
        guard !fresh.isEmpty else { return plan }

        var byMD5: [String: [RemoteItem]] = [:]
        var byName: [String: [RemoteItem]] = [:]
        for item in remote {
            if let md5 = item.md5 { byMD5[md5, default: []].append(item) }
            if !item.nameKey.isEmpty { byName[item.nameKey, default: []].append(item) }
        }
        var used = Set(ledger.entries.values.compactMap(\.remoteId))
        // Entries without an id (older ones) still claim their remote photo by name.
        let claimedNames = Set(ledger.entries.values.filter { $0.remoteId == nil }.compactMap(\.remoteName))
        for item in remote where item.md5 == nil && claimedNames.contains(item.name) { used.insert(item.id) }

        func take(_ candidates: [RemoteItem]?) -> RemoteItem? {
            guard let found = candidates?.first(where: { !used.contains($0.id) }) else { return nil }
            used.insert(found.id)
            return found
        }

        var unmatched: [SourceItem] = []
        // MD5 matches first, so a name match can't take a remote photo an exact match needs.
        for item in fresh {
            if let hash = md5(item), let hit = take(byMD5[hash]) {
                plan.matched.append((item, hit))
            } else {
                unmatched.append(item)
            }
        }
        for item in unmatched {
            if let hit = take(byName[NameMatching.key(item.fileName)]) {
                plan.matched.append((item, hit))
            } else {
                plan.toUpload.append(item)
            }
        }
        return plan
    }

    /// What to do when every album of a mapping is full: reuse an album already in the account
    /// with the next name ("Family 2") if it has room, or create one with the first free name.
    public enum Overflow: Equatable {
        case reuse(DestinationRef)
        case create(String)
    }

    public static func nextOverflow(base: String, used: [DestinationRef], accountAlbums: [RemoteAlbum], limit: Int) -> Overflow {
        let usedIds = Set(used.map(\.id))
        var n = 2
        while true {
            let name = "\(base) \(n)"
            let sameName = accountAlbums.filter { $0.ref.name == name }
            if sameName.isEmpty { return .create(name) }
            if let free = sameName.first(where: { !usedIds.contains($0.id) && ($0.count ?? 0) < limit && $0.note == nil }) {
                return .reuse(free.ref)
            }
            n += 1
        }
    }

    /// Which album the next photo goes into, given how many each holds and the service's limit.
    /// Returns nil when every album is full and a new one is needed.
    public static func destinationWithRoom(_ destinations: [DestinationRef], counts: [String: Int], limit: Int?) -> DestinationRef? {
        guard let limit else { return destinations.first }
        return destinations.first { (counts[$0.id] ?? 0) < limit }
    }
}
