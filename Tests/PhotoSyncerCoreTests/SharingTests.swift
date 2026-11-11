import Foundation
import Testing

@testable import PhotoSyncerCore

/// Sharing one setup between Macs: where data lives, moving it, the sync lock, merging ledgers,
/// and keys and paths that mean the same thing on every Mac.
@Suite("Sharing between Macs")
struct SharingTests {
    final class Folders {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("photo-syncer-sharing-\(UUID().uuidString)")
        var local: URL { root.appendingPathComponent("Application Support/Photo Syncer") }
        var documents: URL { root.appendingPathComponent("Documents/Photo Syncer") }
        var dropbox: URL { root.appendingPathComponent("Dropbox/Photo Syncer") }
        deinit { try? FileManager.default.removeItem(at: root) }
    }

    func config(named name: String) -> AppConfig {
        var config = AppConfig()
        config.accounts = [Account(service: .folder, name: name, folderPath: "~/Pictures/Out")]
        return config
    }

    @Test func dataFromBeforeSharingMovesToTheDataFolder() throws {
        let folders = Folders()
        // An earlier version kept everything in Application Support.
        let old = Storage(root: folders.local)
        try old.saveConfig(config(named: "Old"))
        try LedgerStore(storage: old).save({ var l = Ledger(); l.record("a", .init(how: .uploaded)); return l }(), for: UUID())
        try old.setSecret("google.clientSecret", "s")

        let storage = Storage(localRoot: folders.local, dataRoot: folders.documents)
        storage.adoptLegacyData()

        #expect(storage.loadConfig().accounts.first?.name == "Old")
        #expect(try FileManager.default.contentsOfDirectory(atPath: storage.ledgerDirectory.path).count == 1)
        #expect(!FileManager.default.fileExists(atPath: folders.local.appendingPathComponent("config.json").path))
        #expect(storage.secret("google.clientSecret") == "s", "secrets stay on this Mac")
        #expect(!FileManager.default.fileExists(atPath: folders.documents.appendingPathComponent("secrets.json").path))
    }

    @Test func existingSharedSettingsAreNotOverwritten() throws {
        let folders = Folders()
        try Storage(root: folders.local).saveConfig(config(named: "This Mac's old"))
        try Storage(root: folders.documents).saveConfig(config(named: "Shared"))

        let storage = Storage(localRoot: folders.local, dataRoot: folders.documents)
        storage.adoptLegacyData()
        #expect(storage.loadConfig().accounts.first?.name == "Shared")
    }

    @Test func movingTheDataFolderTakesTheDataAlong() throws {
        let folders = Folders()
        let storage = Storage(localRoot: folders.local, dataRoot: folders.documents)
        try storage.saveConfig(config(named: "Mine"))
        storage.log("hello")

        let moved = try storage.relocate(to: folders.dropbox, moveData: true)
        #expect(moved.loadConfig().accounts.first?.name == "Mine")
        #expect(!Storage.hasSyncData(at: folders.documents))
        #expect(Storage.dataPath(in: folders.local) == PortablePath.portable(folders.dropbox.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: moved.logsDirectory.path).count == 1)
    }

    @Test func pointingAtAnotherMacsFolderUsesItsSettings() throws {
        let folders = Folders()
        try Storage(root: folders.dropbox).saveConfig(config(named: "Shared"))
        let storage = Storage(localRoot: folders.local, dataRoot: folders.documents)
        try storage.saveConfig(config(named: "Mine"))

        #expect(throws: (any Error).self) { try storage.relocate(to: folders.dropbox, moveData: true) }
        let joined = try storage.relocate(to: folders.dropbox, moveData: false)
        #expect(joined.loadConfig().accounts.first?.name == "Shared")
        #expect(storage.loadConfig().accounts.first?.name == "Mine", "this Mac's old data is left alone")
    }

    @Test func onlyOneMacSyncsAtATime() throws {
        let folders = Folders()
        let url = Storage(root: folders.documents).lockURL
        let kitchen = SyncLock(url: url, mac: "Kitchen iMac")
        let laptop = SyncLock(url: url, mac: "Laptop")
        let start = Date()

        try kitchen.acquire(now: start)
        #expect(throws: SyncLock.Failure.self) { try laptop.acquire(now: start.addingTimeInterval(60)) }
        #expect(laptop.blocker(now: start.addingTimeInterval(60))?.mac == "Kitchen iMac")

        // The kitchen Mac keeps it fresh while it syncs...
        kitchen.touch(now: start.addingTimeInterval(9 * 60))
        #expect(throws: SyncLock.Failure.self) { try laptop.acquire(now: start.addingTimeInterval(15 * 60)) }

        // ...and a lock nobody has touched for ten minutes is treated as abandoned.
        try laptop.acquire(now: start.addingTimeInterval(20 * 60))
        #expect(kitchen.blocker(now: start.addingTimeInterval(20 * 60))?.mac == "Laptop")

        // Releasing someone else's lock does nothing; releasing your own clears it.
        kitchen.release()
        #expect(laptop.current()?.mac == "Laptop")
        laptop.release()
        #expect(laptop.current() == nil)
    }

    @Test func forcingTakesTheLock() throws {
        let folders = Folders()
        let url = Storage(root: folders.documents).lockURL
        try SyncLock(url: url, mac: "Kitchen iMac").acquire()
        let laptop = SyncLock(url: url, mac: "Laptop")
        try laptop.acquire(force: true)
        #expect(laptop.current()?.mac == "Laptop")
    }

    @Test func ledgersFromTwoMacsMerge() throws {
        let folders = Folders()
        let id = UUID()
        let storeA = LedgerStore(storage: Storage(root: folders.documents))
        let storeB = LedgerStore(storage: Storage(root: folders.documents))
        var a = storeA.load(id)
        var b = storeB.load(id)
        a.record("photo-1", .init(how: .uploaded))
        b.record("photo-2", .init(how: .uploaded))
        try storeA.save(a, for: id)
        try storeB.save(b, for: id)  // B never saw photo-1, but must not drop it.
        #expect(Set(storeA.load(id).entries.keys) == ["photo-1", "photo-2"])
    }

    @Test func photosRecordedBeforeICloudIdsAreRekeyed() throws {
        let folders = Folders()
        let id = UUID()
        let store = LedgerStore(storage: Storage(root: folders.documents))
        var ledger = Ledger()
        ledger.record("ABC-123/L0/001", .init(how: .markedSynced))
        try store.save(ledger, for: id)

        var loaded = store.load(id)
        let item = SourceItem(key: "icloud:XYZ", fileName: "IMG_1.jpg", aliases: ["ABC-123/L0/001"], assetIdentifier: "ABC-123/L0/001")
        #expect(loaded.reconcile([item]) == 1)
        try store.save(loaded, for: id)

        let reread = store.load(id)
        #expect(reread.contains("icloud:XYZ"))
        #expect(!reread.contains("ABC-123/L0/001"), "the merge on save doesn't bring the old key back")
        #expect(reread.entries["icloud:XYZ"]?.how == .markedSynced)

        // The planner then sees it as already synced.
        let plan = SyncPlanner.plan(items: [item], ledger: reread, remote: [], md5: { _ in nil })
        #expect(plan.alreadySynced == 1 && plan.toUpload.isEmpty)
    }

    @Test func pathsAreStoredRelativeToHome() {
        let home = "/Users/sam"
        #expect(PortablePath.portable("/Users/sam/Pictures/Frames", home: home) == "~/Pictures/Frames")
        #expect(PortablePath.portable("/Users/samantha/Pictures", home: home) == "/Users/samantha/Pictures")
        #expect(PortablePath.portable("/Volumes/Photos/Frames", home: home) == "/Volumes/Photos/Frames")
        #expect(PortablePath.expand("~/Pictures/Frames", home: "/Users/alex") == "/Users/alex/Pictures/Frames")

        var config = AppConfig()
        config.accounts = [Account(service: .folder, name: "Out", folderPath: "/Users/sam/Dashboard")]
        config.mappings = [Mapping(source: .folder(path: "/Users/sam/Pictures/Frames"), accountId: config.accounts[0].id,
                                   destination: DestinationRef(id: "Family", name: "Family"))]
        let portable = config.withPortablePaths(home: home)
        #expect(portable.accounts[0].folderPath == "~/Dashboard")
        #expect(portable.mappings[0].source == .folder(path: "~/Pictures/Frames"))
    }

    @Test func theSameAlbumIsRecognisedOnAnyMac() {
        let here = SourceRef.photosAlbum(localIdentifier: "AAA/L0/040", title: "Frames › Family", cloudIdentifier: "cloud-1")
        let there = SourceRef.photosAlbum(localIdentifier: "BBB/L0/040", title: "Frames › Family", cloudIdentifier: "cloud-1")
        let other = SourceRef.photosAlbum(localIdentifier: "CCC/L0/040", title: "Frames › Travel", cloudIdentifier: "cloud-2")
        #expect(here.isSameSource(as: there))
        #expect(!here.isSameSource(as: other))
        #expect(here.groupKey == there.groupKey)
        #expect(SourceRef.folder(path: NSHomeDirectory() + "/Pictures").isSameSource(as: .folder(path: "~/Pictures")))
    }

    @Test func settingsFromTheEarlierVersionStillLoad() throws {
        // An album mapping saved before albums had an iCloud id.
        let json = """
        {"accounts":[],"firstSyncReviewThreshold":50,"mappings":[{"accountId":"11111111-1111-1111-1111-111111111111",
        "destination":{"id":"1","name":"Family"},"enabled":true,"id":"22222222-2222-2222-2222-222222222222","overflowDestinations":[],
        "source":{"photosAlbum":{"localIdentifier":"AAA/L0/040","title":"Frames › Family"}}}]}
        """
        let config = try JSONDecoder.syncer.decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.mappings.first?.source == .photosAlbum(localIdentifier: "AAA/L0/040", title: "Frames › Family", cloudIdentifier: nil))
    }
}

extension Storage {
    /// Writes a line to today's log in this storage (for tests).
    func log(_ line: String) { SyncLog(directory: logsDirectory).write(line) }
}
