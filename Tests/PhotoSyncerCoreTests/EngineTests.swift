import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PhotoSyncerCore

/// A service that keeps albums in memory.
final class FakeService: RemoteService, @unchecked Sendable {
    let kind: ServiceKind
    let preferredBatchSize = 2
    private let lock = NSLock()
    var store: [String: [RemoteItem]] = [:]
    var names: [String: String] = [:]
    var uploads = 0

    init(kind: ServiceKind = .amazon, albums: [String: String] = ["dest": "Family"]) {
        self.kind = kind
        names = albums
        for id in albums.keys { store[id] = [] }
    }

    func verify() async throws -> String? { "fake" }

    func albums() async throws -> [RemoteAlbum] {
        lock.withLock { names.map { RemoteAlbum(ref: DestinationRef(id: $0.key, name: $0.value), count: store[$0.key]?.count) } }
    }

    func createAlbum(named name: String) async throws -> DestinationRef {
        lock.withLock {
            let id = "album-\(names.count + 1)"
            names[id] = name
            store[id] = []
            return DestinationRef(id: id, name: name)
        }
    }

    func items(in destination: DestinationRef) async throws -> [RemoteItem] {
        lock.withLock { store[destination.id] ?? [] }
    }

    func upload(_ payloads: [UploadPayload], to destination: DestinationRef) async -> [Result<UploadResult, Error>] {
        lock.withLock {
            payloads.map { payload in
                uploads += 1
                let item = RemoteItem(id: UUID().uuidString, name: payload.fileName, md5: payload.md5)
                store[destination.id, default: []].append(item)
                return .success(UploadResult(remoteId: item.id, remoteName: item.name))
            }
        }
    }
}

final class Sandbox {
    let root: URL
    let source: URL
    let storage: Storage

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("photo-syncer-tests-\(UUID().uuidString)")
        source = root.appendingPathComponent("Source/Family")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        storage = Storage(root: root.appendingPathComponent("support"))
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// Writes a small, distinct JPEG.
    @discardableResult
    func addPhoto(_ name: String, shade: Int, size: Int = 64, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? source).appendingPathComponent(name)
        try makeJPEG(width: size, height: size * 3 / 4, shade: shade).write(to: url)
        return url
    }
}

func makeImage(width: Int, height: Int, shade: Int) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: CGFloat(shade * 37 % 256) / 255, green: CGFloat(shade * 91 % 256) / 255, blue: 0.6, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

/// An image with per-pixel noise, which (like a real photo) doesn't compress to almost nothing.
func makeNoisyImage(width: Int, height: Int) -> CGImage {
    var generator = SystemRandomNumberGenerator()
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for index in stride(from: 0, to: pixels.count, by: 4) {
        pixels[index] = UInt8.random(in: 0...255, using: &generator)
        pixels[index + 1] = UInt8.random(in: 0...255, using: &generator)
        pixels[index + 2] = UInt8.random(in: 0...255, using: &generator)
    }
    let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    return context.makeImage()!
}

func encode(_ image: CGImage, as type: UTType, quality: Double? = nil) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
    let properties = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
    CGImageDestinationAddImage(destination, image, properties)
    CGImageDestinationFinalize(destination)
    return data as Data
}

func makeJPEG(width: Int, height: Int, shade: Int) -> Data {
    encode(makeImage(width: width, height: height, shade: shade), as: .jpeg)
}

@Suite("Sync engine")
struct SyncEngineTests {
    func setUp(service: FakeService, limit: Int? = nil) throws -> (Sandbox, SyncEngine, Account, Mapping) {
        let sandbox = try Sandbox()
        let engine = SyncEngine(storage: sandbox.storage, serviceFactory: { _ in service },
                                log: SyncLog(directory: sandbox.storage.logsDirectory), albumLimit: { _ in limit })
        let account = Account(service: service.kind, name: "Test")
        let mapping = Mapping(source: .folder(path: sandbox.source.path), accountId: account.id,
                              destination: DestinationRef(id: "dest", name: "Family"))
        return (sandbox, engine, account, mapping)
    }

    final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    func run(_ engine: SyncEngine, _ mapping: Box<Mapping>, _ account: Account, threshold: Int = 100, confirmed: Bool = false) async -> SyncOutcome {
        await engine.sync(mapping.value, account: account, threshold: threshold, confirmed: confirmed,
                          updateMapping: { mapping.value = $0 }, progress: { _ in })
    }

    @Test func onlyNewPhotosAreUploaded() async throws {
        let service = FakeService()
        let (sandbox, engine, account, start) = try setUp(service: service)
        let mapping = Box(start)
        try sandbox.addPhoto("a.jpg", shade: 1)
        try sandbox.addPhoto("b.jpg", shade: 2)

        guard case .finished(let first, _, 0, _) = await run(engine, mapping, account) else { Issue.record("first sync failed"); return }
        #expect(first == 2)
        #expect(mapping.value.lastSynced != nil)

        guard case .finished(let second, _, _, let upToDate) = await run(engine, mapping, account) else { Issue.record("second sync failed"); return }
        #expect(second == 0)
        #expect(upToDate == 2)

        try sandbox.addPhoto("c.jpg", shade: 3)
        guard case .finished(let third, _, _, _) = await run(engine, mapping, account) else { Issue.record("third sync failed"); return }
        #expect(third == 1)
        #expect(service.uploads == 3)
    }

    @Test func photosAlreadyThereAreMatchedByMD5NotUploaded() async throws {
        let service = FakeService()
        let (sandbox, engine, account, start) = try setUp(service: service)
        let url = try sandbox.addPhoto("Family - 2 of 3.jpeg", shade: 9)
        // Already in the destination under another name, with the same bytes.
        service.store["dest"] = [RemoteItem(id: "existing", name: "something else.jpeg", md5: try Hashing.md5(of: url))]
        let mapping = Box(start)

        guard case .finished(let uploaded, let matched, _, _) = await run(engine, mapping, account) else { Issue.record("sync failed"); return }
        #expect(uploaded == 0)
        #expect(matched == 1)
        #expect(engine.ledger(for: mapping.value).entries["Family - 2 of 3.jpeg"]?.how == .matched)
    }

    @Test func bigFirstSyncWaitsForReview() async throws {
        let service = FakeService()
        let (sandbox, engine, account, start) = try setUp(service: service)
        for n in 0..<5 { try sandbox.addPhoto("p\(n).jpg", shade: n) }
        let mapping = Box(start)

        guard case .needsReview(let plan) = await run(engine, mapping, account, threshold: 3) else { Issue.record("expected review"); return }
        #expect(plan.toUpload.count == 5)
        #expect(service.uploads == 0)

        // "These are already there."
        #expect(try await engine.markAllSynced(mapping.value) == 5)
        guard case .finished(let uploaded, _, _, _) = await run(engine, mapping, account, threshold: 3) else { Issue.record("sync failed"); return }
        #expect(uploaded == 0)

        // After that, new photos go straight up.
        try sandbox.addPhoto("new.jpg", shade: 99)
        guard case .finished(let later, _, _, _) = await run(engine, mapping, account, threshold: 3) else { Issue.record("sync failed"); return }
        #expect(later == 1)
    }

    @Test func confirmedFirstSyncUploadsEverything() async throws {
        let service = FakeService()
        let (sandbox, engine, account, start) = try setUp(service: service)
        for n in 0..<5 { try sandbox.addPhoto("p\(n).jpg", shade: n) }
        let mapping = Box(start)
        guard case .finished(let uploaded, _, _, _) = await run(engine, mapping, account, threshold: 3, confirmed: true) else { Issue.record("sync failed"); return }
        #expect(uploaded == 5)
    }

    @Test func fullAlbumsOverflowIntoNumberedAlbums() async throws {
        let service = FakeService(kind: .pixstar)
        let (sandbox, engine, account, start) = try setUp(service: service, limit: 2)
        for n in 0..<5 { try sandbox.addPhoto("p\(n).jpg", shade: n) }
        let mapping = Box(start)

        guard case .finished(let uploaded, _, 0, _) = await run(engine, mapping, account) else { Issue.record("sync failed"); return }
        #expect(uploaded == 5)
        #expect(mapping.value.overflowDestinations.map(\.name) == ["Family 2", "Family 3"])
        let counts = mapping.value.allDestinations.map { service.store[$0.id]?.count ?? 0 }
        #expect(counts == [2, 2, 1])
    }

    @Test func subfoldersAndHiddenFiles() async throws {
        let service = FakeService()
        let (sandbox, engine, account, start) = try setUp(service: service)
        let sub = sandbox.source.appendingPathComponent("2024")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try sandbox.addPhoto("x.jpg", shade: 1, in: sub)
        try Data("junk".utf8).write(to: sandbox.source.appendingPathComponent(".DS_Store"))
        try Data("text".utf8).write(to: sandbox.source.appendingPathComponent("notes.txt"))
        let items = try await engine.source(for: start.source).items()
        #expect(items.map(\.key) == ["2024/x.jpg"])
        _ = account
    }
}

@Suite("Images and folders")
struct ImageAndFolderTests {
    @Test func pngBecomesADownsizedJPEG() throws {
        let png = encode(makeImage(width: 4000, height: 3000, shade: 5), as: .png)
        let jpeg = try ImageProcessing.jpeg(from: png, maxPixelSize: 2048)
        #expect(ImageProcessing.isJPEG(jpeg))
        #expect(ImageProcessing.pixelSize(of: jpeg) == CGSize(width: 2048, height: 1536))
    }

    @Test func smallImagesAreNotEnlarged() throws {
        let jpeg = try ImageProcessing.jpeg(from: makeJPEG(width: 300, height: 200, shade: 1), maxPixelSize: 2048)
        #expect(ImageProcessing.pixelSize(of: jpeg) == CGSize(width: 300, height: 200))
    }

    @Test func folderSourceDownsizesOnlyWhenAsked() async throws {
        let sandbox = try Sandbox()
        try sandbox.addPhoto("big.jpg", shade: 1, size: 3000)
        let source = FolderSource(path: sandbox.source.path, md5Cache: MD5Cache(url: sandbox.storage.md5CacheURL))
        let item = try await source.items()[0]
        let original = try await source.payload(for: item, options: ImageOptions())
        #expect(original.md5 == (try source.originalMD5(of: item)), "untouched bytes keep the file's MD5")
        let small = try await source.payload(for: item, options: ImageOptions(maxPixelSize: 1000, preferJPEG: true))
        #expect(ImageProcessing.pixelSize(of: small.data) == CGSize(width: 1000, height: 750))
    }

    @Test func compressionShrinksPhotosWithoutResizingThem() throws {
        let original = encode(makeNoisyImage(width: 800, height: 600), as: .jpeg, quality: 1.0)
        let compressed = try #require(try ImageProcessing.prepare(original, options: ImageOptions(jpegQuality: 0.6)))
        #expect(compressed.count < original.count / 2)
        #expect(ImageProcessing.pixelSize(of: compressed) == CGSize(width: 800, height: 600))
    }

    @Test func compressionKeepsTheOriginalWhenItIsAlreadySmaller() throws {
        let original = encode(makeNoisyImage(width: 400, height: 300), as: .jpeg, quality: 0.3)
        #expect(try ImageProcessing.prepare(original, options: ImageOptions(jpegQuality: 0.85)) == nil)
        #expect(try ImageProcessing.prepare(original, options: ImageOptions()) == nil, "nothing asked, nothing changed")
        // Converting still happens when it's needed, whatever the size.
        let png = encode(makeNoisyImage(width: 400, height: 300), as: .png)
        let converted = try #require(try ImageProcessing.prepare(png, options: ImageOptions(jpegQuality: 0.85, preferJPEG: true)))
        #expect(ImageProcessing.isJPEG(converted))
    }

    @Test func folderSourceCompressesWhenAsked() async throws {
        let sandbox = try Sandbox()
        let url = sandbox.source.appendingPathComponent("photo.jpg")
        try encode(makeNoisyImage(width: 800, height: 600), as: .jpeg, quality: 1.0).write(to: url)
        let source = FolderSource(path: sandbox.source.path, md5Cache: MD5Cache(url: sandbox.storage.md5CacheURL))
        let item = try await source.items()[0]
        let payload = try await source.payload(for: item, options: ImageOptions(maxPixelSize: 2048, jpegQuality: 0.6, preferJPEG: true))
        #expect(payload.data.count < (try Data(contentsOf: url)).count / 2)
        #expect(payload.fileName == "photo.jpg")
        #expect(payload.mimeType == "image/jpeg")
    }

    @Test func sizeEstimateCoversAnAccountsAlbums() async throws {
        let sandbox = try Sandbox()
        var total: Int64 = 0
        for index in 0..<4 {
            let url = sandbox.source.appendingPathComponent("photo \(index).jpg")
            let data = encode(makeNoisyImage(width: 600, height: 400), as: .jpeg, quality: 1.0)
            try data.write(to: url)
            total += Int64(data.count)
        }
        let engine = SyncEngine(storage: sandbox.storage, serviceFactory: { _ in FakeService() },
                                log: SyncLog(directory: sandbox.storage.logsDirectory))
        let account = Account(service: .google, name: "Google")
        let other = Account(service: .pixstar, name: "Frame")
        let mapping = Mapping(source: .folder(path: sandbox.source.path), accountId: account.id,
                              destination: DestinationRef(id: "a", name: "Family"))
        // The same folder twice for this account, and once for another account: each photo counts once.
        let again = Mapping(source: .folder(path: sandbox.source.path), accountId: account.id,
                            destination: DestinationRef(id: "b", name: "Family too"))
        let elsewhere = Mapping(source: .folder(path: sandbox.source.path), accountId: other.id,
                                destination: DestinationRef(id: "c", name: "Frame"))
        let estimate = try await engine.estimateSizes(for: account, mappings: [mapping, again, elsewhere],
                                                      maxPixelSize: nil, qualities: [nil, 0.85, 0.6], sampleSize: 2)
        #expect(estimate.photoCount == 4)
        #expect(estimate.pendingCount == 4)
        #expect(estimate.originalBytes == total)
        #expect(estimate.sampled == 2)
        #expect(estimate.rows.map(\.quality) == [nil, 0.85, 0.6])
        #expect(estimate.rows[0].totalBytes == total, "JPEGs that don't need changing go up as they are")
        #expect(estimate.rows[2].totalBytes < estimate.rows[1].totalBytes)
        #expect(estimate.rows[2].totalBytes < total / 2)
    }

    @Test func folderDestinationCopiesAndIndexes() async throws {
        let sandbox = try Sandbox()
        let destination = FolderDestinationService(path: sandbox.root.appendingPathComponent("Dashboard").path)
        let album = try await destination.createAlbum(named: "Family")
        let payload = UploadPayload(data: makeJPEG(width: 10, height: 10, shade: 1), fileName: "a.jpg", mimeType: "image/jpeg")
        let first = await destination.upload([payload, payload], to: album)
        #expect(first.compactMap { try? $0.get().remoteName } == ["a.jpg", "a 2.jpg"])
        #expect(try await destination.items(in: album).count == 2)
        let index = sandbox.root.appendingPathComponent("Dashboard/Family/index.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any]
        #expect((json?["photos"] as? [Any])?.count == 2)
    }

    @Test func configRoundTrips() throws {
        let sandbox = try Sandbox()
        var config = AppConfig()
        let account = Account(service: .pixstar, name: "Pix-Star (kitchen)")
        config.accounts = [account]
        config.mappings = [Mapping(source: .photosAlbum(localIdentifier: "X/L0/040", title: "Frames › Family"),
                                   accountId: account.id, destination: DestinationRef(id: "1000001", name: "Family"))]
        try sandbox.storage.saveConfig(config)
        let loaded = sandbox.storage.loadConfig()
        #expect(loaded.accounts.first?.maxPixelSize == 2048, "Pix-Star uploads are downsized by default")
        #expect(loaded.accounts.first?.jpegQuality == nil, "photos aren't compressed unless asked")
        #expect(loaded.mappings.first?.source.shortName == "Family")
        #expect(loaded.mappings.first?.destination.addsToAlbum == false)
    }
}
