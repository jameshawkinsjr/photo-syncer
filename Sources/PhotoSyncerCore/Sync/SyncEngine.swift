import Foundation

/// Progress of the mapping being synced, for the window.
public struct SyncProgress: Sendable {
    public var mappingId: UUID
    public var phase: String
    public var done: Int
    public var total: Int
    public var failed: Int

    public init(mappingId: UUID, phase: String, done: Int = 0, total: Int = 0, failed: Int = 0) {
        self.mappingId = mappingId
        self.phase = phase
        self.done = done
        self.total = total
        self.failed = failed
    }
}

/// How a mapping's sync ended.
public enum SyncOutcome: Sendable {
    case finished(uploaded: Int, matched: Int, failed: Int, upToDate: Int)
    /// A first sync that would upload many photos waits for the person to choose: upload them,
    /// or mark them as already there.
    case needsReview(SyncPlan)
    case failed(String)

    public var summary: String {
        switch self {
        case .finished(let uploaded, let matched, let failed, let upToDate):
            var parts: [String] = []
            if uploaded > 0 { parts.append("\(uploaded) uploaded") }
            if matched > 0 { parts.append("\(matched) already there") }
            if failed > 0 { parts.append("\(failed) failed") }
            if parts.isEmpty { parts.append("Up to date (\(upToDate))") }
            return parts.joined(separator: ", ")
        case .needsReview(let plan):
            return "First sync: \(plan.toUpload.count) to upload. Review before syncing."
        case .failed(let message):
            return message
        }
    }
}

/// Builds the service client for an account (the app supplies cookies and tokens).
public typealias ServiceFactory = @Sendable (Account) async throws -> RemoteService

/// Runs syncs. One mapping at a time; within a mapping, uploads run a few at once.
public final class SyncEngine: @unchecked Sendable {
    public let storage: Storage
    let ledgers: LedgerStore
    let md5Cache: MD5Cache
    let serviceFactory: ServiceFactory
    let log: SyncLog
    let albumLimit: @Sendable (ServiceKind) -> Int?

    public init(storage: Storage, serviceFactory: @escaping ServiceFactory, log: SyncLog,
                albumLimit: @escaping @Sendable (ServiceKind) -> Int? = { $0.albumPhotoLimit }) {
        self.storage = storage
        self.ledgers = LedgerStore(storage: storage)
        self.md5Cache = MD5Cache(url: storage.md5CacheURL)
        self.serviceFactory = serviceFactory
        self.log = log
        self.albumLimit = albumLimit
    }

    public func source(for ref: SourceRef) -> PhotoSource {
        switch ref {
        case .folder(let path): return FolderSource(path: path, md5Cache: md5Cache)
        case .photosAlbum(let id, _): return PhotosAlbumSource(localIdentifier: id)
        }
    }

    public func ledger(for mapping: Mapping) -> Ledger { ledgers.load(mapping.id) }

    public func forget(_ mapping: Mapping) { ledgers.delete(mapping.id) }

    /// Compares the source with the ledger and (only if something is new) the destination.
    public func plan(_ mapping: Mapping, account: Account, progress: @escaping @Sendable (SyncProgress) -> Void) async throws -> SyncPlan {
        let source = source(for: mapping.source)
        progress(SyncProgress(mappingId: mapping.id, phase: "Reading \(mapping.source.shortName)…"))
        let items = try await source.items()
        let ledger = ledgers.load(mapping.id)
        let fresh = items.filter { !ledger.contains($0.key) }
        if fresh.isEmpty {
            return SyncPlanner.plan(items: items, ledger: ledger, remote: [], md5: { _ in nil })
        }

        let service = try await serviceFactory(account)
        var remote: [RemoteItem] = []
        for destination in mapping.allDestinations {
            progress(SyncProgress(mappingId: mapping.id, phase: "Listing \(destination.name) on \(account.name)…"))
            remote += try await service.items(in: destination)
        }

        // MD5s only help where the service keeps the original bytes and reports them (Amazon).
        let useMD5 = remote.contains { $0.md5 != nil }
        if useMD5 {
            progress(SyncProgress(mappingId: mapping.id, phase: "Fingerprinting \(fresh.count) photos…", total: fresh.count))
        }
        let plan = SyncPlanner.plan(items: items, ledger: ledger, remote: remote, md5: { item in
            useMD5 ? (try? source.originalMD5(of: item)) ?? nil : nil
        })
        md5Cache.save()
        return plan
    }

    /// Syncs one mapping. `confirmed` lets a big first sync go ahead.
    public func sync(_ mapping: Mapping, account: Account, threshold: Int, confirmed: Bool,
                     updateMapping: @escaping @Sendable (Mapping) -> Void,
                     progress: @escaping @Sendable (SyncProgress) -> Void) async -> SyncOutcome {
        do {
            var mapping = mapping
            let plan = try await plan(mapping, account: account, progress: progress)
            var ledger = ledgers.load(mapping.id)

            for match in plan.matched {
                ledger.record(match.item.key, .init(how: .matched, destinationId: nil, remoteName: match.remote.name, remoteId: match.remote.id))
            }
            try ledgers.save(ledger, for: mapping.id)

            // A first sync that was confirmed and then stopped part-way carries on without asking again.
            let startedBefore = ledger.entries.values.contains { $0.how == .uploaded }
            if mapping.lastSynced == nil && !startedBefore && !confirmed && plan.toUpload.count > threshold {
                return .needsReview(plan)
            }
            if plan.toUpload.isEmpty {
                mapping.lastSynced = Date()
                updateMapping(mapping)
                log.write("\(label(mapping, account)): up to date (\(plan.sourceCount) photos, \(plan.matched.count) found already there)")
                return .finished(uploaded: 0, matched: plan.matched.count, failed: 0, upToDate: plan.alreadySynced)
            }

            let service = try await serviceFactory(account)
            let source = source(for: mapping.source)
            let limit = albumLimit(account.service)
            var counts: [String: Int] = [:]
            var accountAlbums: [RemoteAlbum] = []
            if limit != nil {
                accountAlbums = try await service.albums()
                for album in accountAlbums { counts[album.ref.id] = album.count ?? 0 }
            }

            let total = plan.toUpload.count
            var done = 0
            var failed = 0
            var uploaded = 0
            progress(SyncProgress(mappingId: mapping.id, phase: "Uploading to \(account.name)…", done: 0, total: total))
            log.write("\(label(mapping, account)): uploading \(total) photos")

            let batchSize = max(1, service.preferredBatchSize)
            let parallel = limit == nil ? 3 : 1
            var queue = plan.toUpload[...]

            while !queue.isEmpty {
                try Task.checkCancellation()
                // Take up to `parallel` batches, all for the same album.
                var destination: DestinationRef
                if let room = SyncPlanner.destinationWithRoom(mapping.allDestinations, counts: counts, limit: limit) {
                    destination = room
                } else if let limit {
                    // Every album so far is full: carry on in "<name> 2", "<name> 3", …
                    switch SyncPlanner.nextOverflow(base: mapping.destination.name, used: mapping.allDestinations,
                                                    accountAlbums: accountAlbums, limit: limit) {
                    case .reuse(let existing):
                        destination = existing
                        log.write("\(label(mapping, account)): albums full; continuing in the existing album \(existing.name)")
                    case .create(let name):
                        destination = try await service.createAlbum(named: name)
                        counts[destination.id] = 0
                        accountAlbums.append(RemoteAlbum(ref: destination, count: 0))
                        log.write("\(label(mapping, account)): albums full; created \(name). Add it to the frame's slideshow.")
                    }
                    mapping.overflowDestinations.append(destination)
                    updateMapping(mapping)
                } else {
                    destination = mapping.destination
                }
                let room = limit.map { $0 - (counts[destination.id] ?? 0) } ?? Int.max
                let take = min(batchSize * parallel, room, queue.count)
                let chunk = Array(queue.prefix(take))
                queue = queue.dropFirst(take)
                let batches = stride(from: 0, to: chunk.count, by: batchSize).map { Array(chunk[$0..<min($0 + batchSize, chunk.count)]) }

                let preferJPEG = account.service == .pixstar || account.service == .google
                let results = await withTaskGroup(of: [(SourceItem, Result<UploadResult, Error>)].self) { group in
                    for batch in batches {
                        group.addTask {
                            var payloads: [UploadPayload] = []
                            var prepared: [SourceItem] = []
                            var out: [(SourceItem, Result<UploadResult, Error>)] = []
                            for item in batch {
                                do {
                                    payloads.append(try await source.payload(for: item, maxPixelSize: account.maxPixelSize, preferJPEG: preferJPEG))
                                    prepared.append(item)
                                } catch {
                                    out.append((item, .failure(error)))
                                }
                            }
                            if !payloads.isEmpty {
                                let uploads = await service.upload(payloads, to: destination)
                                out += zip(prepared, uploads).map { ($0, $1) }
                            }
                            return out
                        }
                    }
                    var all: [(SourceItem, Result<UploadResult, Error>)] = []
                    for await part in group { all += part }
                    return all
                }

                for (item, result) in results {
                    done += 1
                    switch result {
                    case .success(let upload):
                        uploaded += 1
                        counts[destination.id, default: 0] += 1
                        ledger.record(item.key, .init(how: upload.deduplicated ? .matched : .uploaded, destinationId: destination.id,
                                                      remoteName: upload.remoteName, remoteId: upload.remoteId))
                    case .failure(let error):
                        if case SyncError.notSignedIn = error { throw error }
                        failed += 1
                        log.write("  ✗ \(item.fileName): \(error.localizedDescription)")
                    }
                }
                try ledgers.save(ledger, for: mapping.id)
                progress(SyncProgress(mappingId: mapping.id, phase: "Uploading to \(destination.name) on \(account.name)…",
                                      done: done, total: total, failed: failed))
            }

            mapping.lastSynced = Date()
            updateMapping(mapping)
            log.write("\(label(mapping, account)): \(uploaded) uploaded, \(failed) failed")
            return .finished(uploaded: uploaded, matched: plan.matched.count, failed: failed, upToDate: plan.alreadySynced)
        } catch is CancellationError {
            return .failed("Cancelled")
        } catch SyncError.cancelled {
            return .failed("Cancelled")
        } catch let error as URLError where error.code == .cancelled {
            return .failed("Cancelled")
        } catch {
            log.write("\(label(mapping, account)): \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }

    /// Records everything currently in the source as already pushed, without uploading.
    @discardableResult
    public func markAllSynced(_ mapping: Mapping) async throws -> Int {
        let items = try await source(for: mapping.source).items()
        var ledger = ledgers.load(mapping.id)
        var added = 0
        for item in items where !ledger.contains(item.key) {
            ledger.record(item.key, .init(how: .markedSynced))
            added += 1
        }
        try ledgers.save(ledger, for: mapping.id)
        log.write("\(mapping.source.displayName) → \(mapping.destination.name): marked \(added) photos as already synced")
        return added
    }

    /// Downloads every photo in a remote album into a folder (skipping files already there).
    public func backup(account: Account, album: DestinationRef, to folder: URL,
                       progress: @escaping @Sendable (Int, Int) -> Void) async throws -> (saved: Int, skipped: Int, failed: Int) {
        let service = try await serviceFactory(account)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let items = try await service.items(in: album)
        var saved = 0, skipped = 0, failed = 0
        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            let target = folder.appendingPathComponent(item.name.replacingOccurrences(of: "/", with: "-"))
            if FileManager.default.fileExists(atPath: target.path) {
                skipped += 1
            } else {
                do {
                    let (data, name) = try await service.download(item)
                    let url = name == item.name ? target : folder.appendingPathComponent(name.replacingOccurrences(of: "/", with: "-"))
                    try data.write(to: url, options: .atomic)
                    saved += 1
                } catch {
                    if case SyncError.notSignedIn = error { throw error }
                    failed += 1
                    log.write("  ✗ backup \(item.name): \(error.localizedDescription)")
                }
            }
            progress(index + 1, items.count)
        }
        log.write("Backed up \(album.name) from \(account.name) to \(folder.path): \(saved) saved, \(skipped) already there, \(failed) failed")
        return (saved, skipped, failed)
    }

    /// Copies the backed-up photos that have no counterpart (by name) in a local folder into
    /// "<backup>/Not in <folder>", to see what's missing locally.
    public func copyMissing(backup: URL, comparedWith local: URL, service: ServiceKind) throws -> Int {
        let localItems = try FolderSource(path: local.path, md5Cache: md5Cache).scanNames()
        let localKeys = Set(localItems.map(NameMatching.key))
        let target = backup.appendingPathComponent("Not in \(local.lastPathComponent)", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: backup, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter(NameMatching.isImage)
        var missing = 0
        for file in files {
            let key = service == .pixstar ? NameMatching.pixStarKey(file.lastPathComponent) : NameMatching.key(file.lastPathComponent)
            guard !localKeys.contains(key) else { continue }
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let copy = target.appendingPathComponent(file.lastPathComponent)
            if !FileManager.default.fileExists(atPath: copy.path) { try FileManager.default.copyItem(at: file, to: copy) }
            missing += 1
        }
        log.write("\(missing) of \(files.count) photos in \(backup.lastPathComponent) have no match in \(local.path)")
        return missing
    }

    private func label(_ mapping: Mapping, _ account: Account) -> String {
        "\(mapping.source.displayName) → \(account.name) / \(mapping.destination.name)"
    }
}

/// Appends to today's log file in Application Support/Photo Syncer/logs.
public final class SyncLog: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    public var onLine: (@Sendable (String) -> Void)?

    public init(directory: URL) { self.directory = directory }

    public var todayURL: URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return directory.appendingPathComponent("\(formatter.string(from: Date())).log")
    }

    public func write(_ line: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let text = "\(formatter.string(from: Date()))  \(line)\n"
        lock.lock()
        defer { lock.unlock() }
        let url = todayURL
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
        onLine?(line)
    }
}
