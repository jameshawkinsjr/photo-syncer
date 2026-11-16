import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PhotoSyncerCore

// Synthetic images of the kinds a frame may show as black: wide gamut, HDR gain maps, Apple's
// HDR tags, transparency and 16-bit samples. All made in code; no real photos.

/// A flat grey image (`level` 0–1) in the given colour space, with optional transparency.
func makeFlatImage(width: Int = 64, height: Int = 48, level: CGFloat = 0.5, space: CFString = CGColorSpace.sRGB,
                   bitsPerComponent: Int = 8, alpha: CGFloat = 1) -> CGImage {
    let colorSpace = CGColorSpace(name: space)!
    let info: UInt32 = bitsPerComponent == 16
        ? CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        : CGImageAlphaInfo.premultipliedLast.rawValue
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: bitsPerComponent, bytesPerRow: 0,
                            space: colorSpace, bitmapInfo: info)!
    context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(colorSpace: colorSpace, components: [level, level, level, alpha])!)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

/// A JPEG like an iPhone HDR photo: Display P3, Apple's HDR maker tags, and an HDR gain map.
func makeHDRJPEG(level: CGFloat = 0.5) -> Data {
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
    let properties: [CFString: Any] = [
        kCGImagePropertyMakerAppleDictionary: ["33": 0.8, "48": 0.01],
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2020:01:02 03:04:05"],
    ]
    CGImageDestinationAddImage(destination, makeFlatImage(level: level, space: CGColorSpace.displayP3), properties as CFDictionary)
    let (width, height) = (32, 24)
    let metadata = CGImageMetadataCreateMutable()
    CGImageMetadataRegisterNamespaceForPrefix(metadata, "http://ns.apple.com/HDRGainMap/1.0/" as CFString, "HDRGainMap" as CFString, nil)
    CGImageMetadataSetValueWithPath(metadata, nil, "HDRGainMap:HDRGainMapVersion" as CFString, 65536 as CFNumber)
    let gainMap: [CFString: Any] = [
        kCGImageAuxiliaryDataInfoData: Data(repeating: 200, count: width * height),
        kCGImageAuxiliaryDataInfoDataDescription: ["Width": width, "Height": height, "BytesPerRow": width,
                                                   "PixelFormat": kCVPixelFormatType_OneComponent8] as [String: Any],
        kCGImageAuxiliaryDataInfoMetadata: metadata,
    ]
    CGImageDestinationAddAuxiliaryDataInfo(destination, kCGImageAuxiliaryDataTypeHDRGainMap, gainMap as CFDictionary)
    CGImageDestinationFinalize(destination)
    return output as Data
}

/// Expects a plain, visible JPEG: 8-bit sRGB, opaque, no extra images or Apple HDR tags,
/// about as bright as `luma` (0–255).
func expectPlain(_ data: Data, luma expected: Double, sourceLocation: SourceLocation = #_sourceLocation) {
    guard let report = ImageReport(data) else {
        Issue.record("doesn't decode", sourceLocation: sourceLocation)
        return
    }
    #expect(report.format == "jpeg", sourceLocation: sourceLocation)
    #expect(report.profile?.hasPrefix("sRGB") ?? true, "profile \(report.profile ?? "-")", sourceLocation: sourceLocation)
    #expect(report.bitDepth == 8, sourceLocation: sourceLocation)
    #expect(!report.hasAlpha, sourceLocation: sourceLocation)
    #expect(report.auxiliary.isEmpty, sourceLocation: sourceLocation)
    #expect(!report.hasAppleHDRTags, sourceLocation: sourceLocation)
    #expect(ImageProcessing.isPlainJPEG(data), sourceLocation: sourceLocation)
    let luma = report.meanLuma ?? -1
    #expect(abs(luma - expected) < 12, "brightness \(luma), expected about \(expected)", sourceLocation: sourceLocation)
}

/// sRGB-encoded grey at 50% shows as about 128.
let midGrey = 128.0

@Suite("Images frames can show")
struct ImageSafetyTests {
    @Test func hdrPhotosBecomePlainJPEGs() throws {
        let hdr = makeHDRJPEG()
        let original = try #require(ImageReport(hdr))
        #expect(original.auxiliary == ["HDR gain map"])
        #expect(original.hasAppleHDRTags)
        #expect(original.profile == "Display P3")
        #expect(!ImageProcessing.isPlainJPEG(hdr))

        // Photos-library uploads prefer JPEG: an HDR JPEG is converted, not passed through.
        let prepared = try #require(try ImageProcessing.prepare(hdr, options: ImageOptions(preferJPEG: true)))
        expectPlain(prepared, luma: original.meanLuma ?? midGrey)
        // The capture date survives.
        #expect(ImageProcessing.captureDate(of: prepared) != nil)
    }

    @Test func displayP3BecomesSRGB() throws {
        let p3 = encode(makeFlatImage(space: CGColorSpace.displayP3), as: .jpeg)
        #expect(!ImageProcessing.isPlainJPEG(p3))
        let output = try ImageProcessing.jpeg(from: p3)
        expectPlain(output, luma: midGrey)
    }

    @Test func sixteenBitImagesBecomeEightBit() throws {
        let png = encode(makeFlatImage(bitsPerComponent: 16), as: .png)
        #expect(ImageReport(png)?.bitDepth == 16)
        let output = try #require(try ImageProcessing.prepare(png, options: ImageOptions(preferJPEG: true)))
        expectPlain(output, luma: midGrey)
    }

    @Test func transparencyIsFlattenedOntoWhiteNotBlack() throws {
        let clear = encode(makeFlatImage(level: 0, alpha: 0), as: .png)
        // A viewer that ignores transparency shows this as black.
        #expect(ImageReport(clear)?.hasAlpha == true)
        #expect(ImageProcessing.looksBlack(clear))
        let output = try ImageProcessing.jpeg(from: clear)
        expectPlain(output, luma: 255)
    }

    @Test func plainJPEGsArePassedThroughUntouched() throws {
        let plain = encode(makeFlatImage(), as: .jpeg)
        #expect(ImageProcessing.isPlainJPEG(plain))
        #expect(try ImageProcessing.prepare(plain, options: ImageOptions(preferJPEG: true)) == nil)
    }

    @Test func redatingKeepsThePictureVisible() throws {
        let inputs = [
            encode(makeFlatImage(), as: .jpeg),
            encode(makeFlatImage(space: CGColorSpace.displayP3), as: .jpeg),
            encode(makeFlatImage(bitsPerComponent: 16), as: .png),
            makeHDRJPEG(),
        ]
        for input in inputs {
            let before = try #require(ImageProcessing.meanLuma(of: input))
            let dated = try ImageProcessing.settingCaptureDate(input, to: Date(timeIntervalSince1970: 1_500_000_000))
            let after = try #require(ImageProcessing.meanLuma(of: dated))
            #expect(abs(after - before) < 3)
        }
    }

    @Test func photosLibraryUploadsArePlainAndDated() throws {
        let taken = Date(timeIntervalSince1970: 1_600_000_000)
        for input in [makeHDRJPEG(), encode(makeFlatImage(space: CGColorSpace.displayP3), as: .heic),
                      encode(makeFlatImage(bitsPerComponent: 16), as: .png)] {
            let result = try PhotosAlbumSource.uploadData(from: input, date: taken, options: ImageOptions())
            expectPlain(result.data, luma: midGrey)
            #expect(result.redated)
            #expect(ImageProcessing.captureDate(of: result.data)?.date == taken)
        }
    }

    @Test func darkPhotosAreNotMistakenForBrokenOnes() throws {
        // A photo that really is black uploads; only a black copy of a visible photo is refused.
        let night = encode(makeFlatImage(level: 0), as: .jpeg)
        #expect(ImageProcessing.looksBlack(night))
        #expect(try PhotosAlbumSource.uploadData(from: night, date: nil, options: ImageOptions()).data == night)
    }
}

@Suite("Check Photos")
struct PhotoCheckTests {
    @Test func daysAreRead() {
        #expect(PhotoDiagnostics.days(from: "2021-03-04, 2022-12-31")?.count == 2)
        #expect(PhotoDiagnostics.days(from: "2021-03-04 2022-12-31\n2020-01-01")?.count == 3)
        #expect(PhotoDiagnostics.days(from: "") == nil)
        #expect(PhotoDiagnostics.days(from: "2021-02-30") == nil)
        #expect(PhotoDiagnostics.days(from: "March 4") == nil)
    }

    @Test func photosWithinADayAreIncluded() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        let days = try #require(PhotoDiagnostics.days(from: "2021-03-04"))
        func at(_ day: Int, _ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: 2021, month: 3, day: day, hour: hour))!
        }
        #expect(PhotoDiagnostics.isNear(at(3, 0), days, calendar: calendar))
        #expect(PhotoDiagnostics.isNear(at(5, 23), days, calendar: calendar))
        #expect(!PhotoDiagnostics.isNear(at(2, 23), days, calendar: calendar))
        #expect(!PhotoDiagnostics.isNear(at(6, 0), days, calendar: calendar))
        #expect(!PhotoDiagnostics.isNear(nil, days, calendar: calendar))
        #expect(PhotoDiagnostics.isOn(at(4, 12), days, calendar: calendar))
        #expect(!PhotoDiagnostics.isOn(at(5, 12), days, calendar: calendar))
    }

    @Test func reportFlagsRisksAndProblems() throws {
        var check = PhotoCheck(key: "k", reference: "ABC/L0/001", fileExtension: "heic", date: nil, ledgerState: .markedSynced)
        PhotoDiagnostics.checkPhotosLibraryPhoto(makeHDRJPEG(), date: nil, options: ImageOptions(), into: &check)
        #expect(check.isOK)
        #expect(check.risks.contains("HDR gain map"))
        #expect(check.risks.contains("Apple HDR tags"))
        #expect(check.logLine.contains("ABC/L0/001 .heic"))
        #expect(check.logLine.hasSuffix("OK | ledger: markedSynced"))

        // A copy that came out black from a visible photo is a problem.
        check.upload = ImageReport(encode(makeFlatImage(level: 0), as: .jpeg))
        #expect(check.problems == ["comes out black"])
    }

    @Test func checkingUploadsNothingAndLogsEachPhoto() async throws {
        let service = FakeService()
        let sandbox = try Sandbox()
        let engine = SyncEngine(storage: sandbox.storage, serviceFactory: { _ in service },
                                log: SyncLog(directory: sandbox.storage.logsDirectory))
        let account = Account(service: .pixstar, name: "Test")
        let mapping = Mapping(source: .folder(path: sandbox.source.path), accountId: account.id,
                              destination: DestinationRef(id: "dest", name: "Family"))
        try sandbox.addPhoto("a.jpg", shade: 1)
        try encode(makeFlatImage(space: CGColorSpace.displayP3), as: .png).write(to: sandbox.source.appendingPathComponent("b.png"))
        let today = Calendar.current.dateComponents([.year, .month, .day], from: Date())

        let checks = try await engine.checkPhotos(mapping, account: account, days: [today])
        #expect(checks.count == 2)
        #expect(checks.allSatisfy { $0.isOK })
        #expect(service.uploads == 0)
        let log = try String(contentsOf: SyncLog(directory: sandbox.storage.logsDirectory).todayURL, encoding: .utf8)
        #expect(log.components(separatedBy: "Check Photos: ").count - 1 == 4) // header, two photos, summary
        // A folder's photos are known by their path in it (a Photos photo by its local id, never its name).
        #expect(log.contains("Check Photos: a.jpg .jpg") && log.contains("Check Photos: b.png .png"))
    }

    @Test func photosCanBeUploadedAgainEvenIfACopyIsStillThere() async throws {
        let service = FakeService()
        let sandbox = try Sandbox()
        let engine = SyncEngine(storage: sandbox.storage, serviceFactory: { _ in service },
                                log: SyncLog(directory: sandbox.storage.logsDirectory))
        let account = Account(service: .pixstar, name: "Test")
        var mapping = Mapping(source: .folder(path: sandbox.source.path), accountId: account.id,
                              destination: DestinationRef(id: "dest", name: "Family"))
        try sandbox.addPhoto("a.jpg", shade: 1)
        try sandbox.addPhoto("b.jpg", shade: 2)
        // Both are already there (by name), as after "They're Already There".
        service.store["dest"] = [RemoteItem(id: "old-a", name: "a.jpg", md5: nil), RemoteItem(id: "old-b", name: "b.jpg", md5: nil)]
        _ = try await engine.markAllSynced(mapping)
        mapping.lastSynced = Date()

        try engine.uploadAgain(["a.jpg"], in: mapping)
        #expect(engine.ledger(for: mapping).reupload == ["a.jpg"])
        let outcome = await engine.sync(mapping, account: account, threshold: 50, confirmed: false,
                                        updateMapping: { _ in }, progress: { _ in })
        guard case .finished(let uploaded, let matched, _, _) = outcome else {
            Issue.record("sync didn't finish: \(outcome.summary)")
            return
        }
        // Uploaded even though a photo with its name is still listed.
        #expect(uploaded == 1 && matched == 0)
        #expect(service.uploads == 1)
        let ledger = engine.ledger(for: mapping)
        #expect(ledger.entries["a.jpg"]?.how == .uploaded)
        #expect(ledger.reupload.isEmpty)
    }

    @Test func uploadAgainSurvivesSavingAndMerging() throws {
        let sandbox = try Sandbox()
        let store = LedgerStore(storage: sandbox.storage)
        let id = UUID()
        var ledger = Ledger()
        ledger.record("a", .init(how: .markedSynced))
        ledger.record("b", .init(how: .markedSynced))
        try store.save(ledger, for: id)

        var mine = store.load(id)
        mine.uploadAgain(["a"])
        try store.save(mine, for: id)
        let saved = store.load(id)
        #expect(saved.entries["a"] == nil) // not merged back from the file
        #expect(saved.reupload == ["a"])

        // Saving again (another photo uploaded) keeps the request; uploading the photo ends it.
        var later = store.load(id)
        later.record("c", .init(how: .uploaded))
        try store.save(later, for: id)
        #expect(store.load(id).reupload == ["a"])
        var done = store.load(id)
        done.record("a", .init(how: .uploaded))
        try store.save(done, for: id)
        #expect(store.load(id).reupload.isEmpty)
    }
}
