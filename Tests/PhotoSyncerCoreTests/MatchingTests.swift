import Foundation
import Testing

@testable import PhotoSyncerCore

@Suite("Name matching")
struct NameMatchingTests {
    @Test func localAndPixStarNamesMatch() {
        // Real names: the local export, and what Pix-Star made of it.
        #expect(NameMatching.key("Summer Trip - 1 of 180.jpeg") == "summertrip1of180")
        #expect(NameMatching.pixStarKey("Summer_Trip_-_1_of_180_5985.jpg") == "summertrip1of180")
    }

    @Test func pixStarOnlyStripsItsOwnSuffix() {
        // "scan_0141.jpg" uploaded becomes "scan_0141_1234.jpg".
        #expect(NameMatching.pixStarKey("scan_0141_1234.jpg") == NameMatching.key("scan_0141.jpg"))
        #expect(NameMatching.pixStarKey("scan_0141_1234.jpg") != NameMatching.key("scan.jpg"))
    }

    @Test func caseAndExtensionDoNotMatter() {
        #expect(NameMatching.key("IMG_1234.HEIC") == NameMatching.key("img_1234.jpg"))
    }

    @Test func imagesAreRecognised() {
        #expect(NameMatching.isImage(URL(fileURLWithPath: "/a/b.JPEG")))
        #expect(!NameMatching.isImage(URL(fileURLWithPath: "/a/.DS_Store")))
        #expect(!NameMatching.isImage(URL(fileURLWithPath: "/a/clip.mov")))
    }
}

@Suite("Sync planner")
struct SyncPlannerTests {
    func item(_ key: String, _ name: String? = nil) -> SourceItem {
        SourceItem(key: key, fileName: name ?? key)
    }

    @Test func ledgerEntriesAreSkipped() {
        var ledger = Ledger()
        ledger.record("a.jpg", .init(how: .uploaded))
        let plan = SyncPlanner.plan(items: [item("a.jpg"), item("b.jpg")], ledger: ledger, remote: [], md5: { _ in nil })
        #expect(plan.alreadySynced == 1)
        #expect(plan.toUpload.map(\.key) == ["b.jpg"])
    }

    @Test func md5MatchesBeatNames() {
        let remote = [
            RemoteItem(id: "1", name: "renamed.jpg", md5: "aaa"),
            RemoteItem(id: "2", name: "x.jpg", md5: "zzz"),
        ]
        let plan = SyncPlanner.plan(items: [item("x.jpg"), item("y.jpg")], ledger: Ledger(), remote: remote,
                                    md5: { $0.key == "x.jpg" ? "aaa" : "bbb" })
        // x.jpg matches by MD5 to "renamed.jpg"; y.jpg has no MD5 or name match.
        #expect(plan.matched.map(\.item.key) == ["x.jpg"])
        #expect(plan.matched.first?.remote.id == "1")
        #expect(plan.toUpload.map(\.key) == ["y.jpg"])
    }

    @Test func eachRemotePhotoMatchesOnce() {
        // Two different IMG_0001s in different sub-folders, one already uploaded.
        let remote = [RemoteItem(id: "1", name: "IMG_0001.jpg")]
        let plan = SyncPlanner.plan(items: [item("2019/IMG_0001.jpg", "IMG_0001.jpg"), item("2020/IMG_0001.jpg", "IMG_0001.jpg")],
                                    ledger: Ledger(), remote: remote, md5: { _ in nil })
        #expect(plan.matched.count == 1)
        #expect(plan.toUpload.count == 1)
    }

    @Test func pixStarNamesMatchLocalFiles() {
        let remote = PixStarParsing.photos(PixStarFixtures.photoPage)
        let plan = SyncPlanner.plan(items: [item("Summer Trip - 1 of 180.jpeg"), item("New photo.jpg")],
                                    ledger: Ledger(), remote: remote, md5: { _ in nil })
        #expect(plan.matched.map(\.item.key) == ["Summer Trip - 1 of 180.jpeg"])
        #expect(plan.toUpload.map(\.key) == ["New photo.jpg"])
    }

    @Test func overflowAlbumsAreNumbered() {
        let first = DestinationRef(id: "1", name: "Family")
        let albums = [RemoteAlbum(ref: first, count: 5480)]
        #expect(SyncPlanner.nextOverflow(base: "Family", used: [first], accountAlbums: albums, limit: 3000) == .create("Family 2"))
    }

    @Test func existingOverflowAlbumWithRoomIsReused() {
        let first = DestinationRef(id: "1", name: "Family")
        let second = DestinationRef(id: "2", name: "Family 2")
        let albums = [RemoteAlbum(ref: first, count: 3000), RemoteAlbum(ref: second, count: 120)]
        #expect(SyncPlanner.nextOverflow(base: "Family", used: [first], accountAlbums: albums, limit: 3000) == .reuse(second))
    }

    @Test func fullOrTakenOverflowAlbumsAreSkipped() {
        let first = DestinationRef(id: "1", name: "Family")
        let fullSecond = DestinationRef(id: "2", name: "Family 2")
        let usedThird = DestinationRef(id: "3", name: "Family 3")
        let albums = [RemoteAlbum(ref: first, count: 3000), RemoteAlbum(ref: fullSecond, count: 3000), RemoteAlbum(ref: usedThird, count: 3000)]
        #expect(SyncPlanner.nextOverflow(base: "Family", used: [first, usedThird], accountAlbums: albums, limit: 3000) == .create("Family 4"))
    }

    @Test func fullAlbumsAreSkipped() {
        let a = DestinationRef(id: "a", name: "A"), b = DestinationRef(id: "b", name: "B")
        #expect(SyncPlanner.destinationWithRoom([a, b], counts: ["a": 3000, "b": 10], limit: 3000) == b)
        #expect(SyncPlanner.destinationWithRoom([a, b], counts: ["a": 5480, "b": 3000], limit: 3000) == nil)
        #expect(SyncPlanner.destinationWithRoom([a, b], counts: ["a": 5480], limit: nil) == a)
    }
}
