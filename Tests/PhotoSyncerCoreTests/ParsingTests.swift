import Foundation
import Testing

@testable import PhotoSyncerCore

/// The shape of pix-star.com markup as seen on 2026-11-09, with made-up ids and names.
enum PixStarFixtures {
    static let albumList = """
    <a href="/accounts/logout/">Log out</a> someone@mypixstar.com
    <ul class="thumbnails">
    <li class="album-image"> <div class="thumbnail album">
      <img class="multiframe-image-icon-album" src="/static/images/multiframe_icon.png" data-content="This album cannot be selected because it is managed by a multi-frame account.">
      <div class="signal"> <span class="see_more_album"><a href="/album/web/1000001/">Open this album</a></span>
      <span class="badge badge-warning" total_photos="5480">5480</span> </div>
      <div id="album_id_1000001" class="album-title web-album-title"> <span>Family</span> </div> </div> </li>
    <li class="album-image"> <div class="thumbnail album">
      <input type="checkbox" class="album-checkbox" value="1000002" name="web_album_list">
      <div class="signal"> <span class="see_more_album"><a href="/album/web/1000002/">Open this album</a></span>
      <span class="badge badge-success" total_photos="2454">2454</span> </div>
      <div id="album_id_1000002" class="album-title web-album-title"> <a href="#" rel="tooltip" class="album_title" data-original-title="Click here to modify the album title">Personal &amp; Friends</a> </div> </div> </li>
    </ul>
    """

    static let photoPage = """
    <li class="album-image" id="small"> <div class="thumbnail"> <div class="photo-top">
      <input type="checkbox" class="image-checkbox" value="2000001" name="images_list">
      </div> <a class="fancybox" id="2000001" rel="big2" href="/get/image/thumbnail?photo_id=2000001&amp;photo_type=1&amp;size=600x800">
      <div class="thumb"> <img class="portrait" src="/media/cache_local/photos/0a1b/Summer_Trip_-_1_of_180_5985.jpg"> </div> </a>
      <h5 class="photo_title" rel="tooltip" title="Summer_Trip_-_1_of_180_5985.jpg">Summer_Trip_-</h5> </div> </li>
    <li class="album-image" id="small"> <div class="thumbnail"> <div class="photo-top">
      <input type="checkbox" class="image-checkbox" value="2000002" name="images_list">
      </div> <a class="fancybox" id="2000002" rel="big2" href="#"> <div class="thumb"> <img src="/media/x/Beach_Day_12.jpg"> </div> </a>
      <h5 class="photo_title" rel="tooltip" title="Beach_Day_12.jpg">Beach_Day</h5> </div> </li>
    """
}

@Suite("Pix-Star pages")
struct PixStarParsingTests {
    @Test func albumsAreRead() {
        let albums = PixStarParsing.albums(PixStarFixtures.albumList)
        #expect(albums.map(\.ref.id) == ["1000001", "1000002"])
        #expect(albums.map(\.ref.name) == ["Family", "Personal & Friends"])
        #expect(albums.map(\.count) == [5480, 2454])
        #expect(albums[0].note != nil, "multi-frame albums are flagged")
        #expect(albums[1].note == nil)
    }

    @Test func signedInFrameIsFound() {
        #expect(PixStarParsing.signedInEmail(PixStarFixtures.albumList) == "someone@mypixstar.com")
        #expect(PixStarParsing.signedInEmail("<html>Sign in</html>") == nil)
    }

    @Test func photosAreRead() {
        let photos = PixStarParsing.photos(PixStarFixtures.photoPage)
        #expect(photos.map(\.id) == ["2000001", "2000002"])
        #expect(photos[0].name == "Summer_Trip_-_1_of_180_5985.jpg")
        #expect(photos[1].nameKey == NameMatching.key("Beach Day.jpg"))
    }

    @Test func createdAlbumIdComesFromTheRedirect() {
        #expect(PixStarParsing.albumId(inPath: "/album/web/4646235/") == "4646235")
        #expect(PixStarParsing.albumId(inPath: "/albums/list/") == nil)
    }

    @Test func downloadNameComesFromTheHeader() {
        #expect(PixStarParsing.fileName(fromContentDisposition: "attachment; filename=\"A_b_1.jpg\"") == "A_b_1.jpg")
    }
}

@Suite("Amazon responses")
struct AmazonParsingTests {
    @Test func applicationIdIsFoundInThePage() {
        let html = #"{"locale":"en_US","applicationId":"QUJDREVGR0hJSktM","urls":{}}"#
        #expect(AmazonParsing.applicationId(inPage: html) == "QUJDREVGR0hJSktM")
    }

    @Test func folderAlbumsUploadIntoTheirFolder() {
        let node: [String: Any] = [
            "id": "AlbumAbCdEfGhIjKlMnOp", "name": "Pictures", "kind": "VISUAL_COLLECTION",
            "collectionProperties": ["query": ["excludedIds": [], "include": [["folderIds": ["FolderAbCdEfGhIjKlMn"]]]]],
        ]
        let album = AmazonParsing.album(from: node)
        #expect(album?.ref.uploadFolderId == "FolderAbCdEfGhIjKlMn")
        #expect(album?.ref.addsToAlbum == false)
    }

    @Test func plainAlbumsGetPhotosAdded() {
        let album = AmazonParsing.album(from: ["id": "x", "name": "Trip", "kind": "VISUAL_COLLECTION"])
        #expect(album?.ref.uploadFolderId == nil)
        #expect(album?.ref.addsToAlbum == true)
    }

    @Test func duplicateConflictNamesTheExistingPhoto() {
        // The shape of the 409 Amazon sends for a duplicate (ids made up).
        let body: [String: Any] = [
            "message": "Duplicate files already exist with FILE_MD5='0123456789abcdef0123456789abcdef' in following node(s): '[AbCdEfGhIjKlMnOpQrStUv]' upload not allowed, please check deduplication settings.",
            "errorCode": "DuplicatesConflictError",
        ]
        #expect(AmazonParsing.duplicateNodeId(fromConflict: body) == "AbCdEfGhIjKlMnOpQrStUv")
    }

    @Test func filesCarryTheirMD5() {
        let item = AmazonParsing.item(from: ["id": "n1", "kind": "FILE", "name": "Family - 2 of 3.jpeg",
                                             "contentProperties": ["md5": "fedcba9876543210fedcba9876543210"]])
        #expect(item?.md5 == "fedcba9876543210fedcba9876543210")
        #expect(item?.nameKey == "family2of3")
    }
}

@Suite("Google sign-in")
struct GoogleTests {
    @Test func emailIsReadFromTheIDToken() {
        let payload = Data(#"{"email":"someone@example.com","sub":"1"}"#.utf8).base64URLEncoded
        #expect(GoogleOAuth.emailFromIDToken("eyJhbGciOiJSUzI1NiJ9.\(payload).sig") == "someone@example.com")
    }

    @Test func endpointsWithAColonKeepTheHost() {
        #expect(GooglePhotosService.endpoint("mediaItems:search").absoluteString
                == "https://photoslibrary.googleapis.com/v1/mediaItems:search")
        #expect(GooglePhotosService.endpoint("mediaItems:batchCreate").host == "photoslibrary.googleapis.com")
        #expect(GooglePhotosService.endpoint("albums?pageSize=1").absoluteString
                == "https://photoslibrary.googleapis.com/v1/albums?pageSize=1")
    }
}
