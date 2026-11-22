import Testing

@testable import PhotoSyncerCore

@Suite("Photos album tree")
struct AlbumTreeTests {
    @Test func countsFillAlbumsAndLeaveFoldersEmpty() {
        let tree = PhotosAlbumNode(id: "folder", title: "Frames", path: "Frames", count: nil, children: [
            PhotosAlbumNode(id: "a", title: "A", path: "Frames › A", count: nil, children: nil),
            PhotosAlbumNode(id: "inner", title: "Inner", path: "Frames › Inner", count: nil, children: [
                PhotosAlbumNode(id: "b", title: "B", path: "Frames › Inner › B", count: nil, children: nil),
                PhotosAlbumNode(id: "gone", title: "Gone", path: "Frames › Inner › Gone", count: nil, children: nil),
            ]),
        ])
        let counted = tree.withCounts { ["a": 3, "b": 0, "folder": 99, "inner": 99][$0] }
        #expect(counted.count == nil)
        #expect(counted.children?[0].count == 3)
        #expect(counted.children?[1].count == nil)
        #expect(counted.children?[1].children?[0].count == 0)
        #expect(counted.children?[1].children?[1].count == nil)
        #expect(counted.children?[1].children?[1].path == "Frames › Inner › Gone")
    }
}
