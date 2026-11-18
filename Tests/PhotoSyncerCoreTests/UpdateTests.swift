import Foundation
import Testing

@testable import PhotoSyncerCore

/// Finding a newer release in a folder and keeping a verified copy of it. The versions,
/// builds and folders here are made up; the "disk images" are a few bytes of text.
@Suite("Updates")
struct UpdateTests {
    final class Folders {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("photo-syncer-updates-\(UUID().uuidString)")
        var releases: URL { root.appendingPathComponent("Dropbox/Photo Syncer Releases") }
        var staging: URL { root.appendingPathComponent("Caches/Updates") }
        var local: URL { root.appendingPathComponent("Application Support/Photo Syncer") }

        init() { try? FileManager.default.createDirectory(at: releases, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: root) }

        /// Writes a disk image and a `latest.json` announcing it, as scripts/publish.sh would.
        @discardableResult
        func publish(version: String = "1.2.0", build: Int = 42, contents: String = "disk image 42",
                     sha256: String? = nil, writeImage: Bool = true) throws -> ReleaseInfo {
            let file = "Photo-Syncer-\(version)-\(build).dmg"
            let image = releases.appendingPathComponent(file)
            if writeImage { try Data(contents.utf8).write(to: image) }
            let checksum = try sha256 ?? Hashing.sha256(of: image)
            let json = """
                {
                  "build" : \(build),
                  "file" : "\(file)",
                  "notes" : "Faster first sync.",
                  "publishedAt" : "2026-01-02T03:04:05Z",
                  "sha256" : "\(checksum)",
                  "version" : "\(version)"
                }
                """
            try Data(json.utf8).write(to: releases.appendingPathComponent("latest.json"))
            return try ReleaseInfo.decode(Data(json.utf8))
        }

        func checker(currentBuild: Int) -> UpdateChecker {
            UpdateChecker(source: FolderReleaseSource(folder: releases), currentBuild: currentBuild, stagingDirectory: staging)
        }
    }

    static let checksum = String(repeating: "ab", count: 32)

    func json(_ fields: String) -> Data { Data("{\(fields)}".utf8) }

    // MARK: latest.json

    @Test func readsLatestJson() throws {
        let release = try ReleaseInfo.decode(json("""
            "version": "1.2.0", "build": 42, "file": "Photo-Syncer-1.2.0-42.dmg",
            "sha256": "\(Self.checksum)", "publishedAt": "2026-01-02T03:04:05Z", "notes": "Faster first sync."
            """))
        #expect(release.version == "1.2.0")
        #expect(release.build == 42)
        #expect(release.file == "Photo-Syncer-1.2.0-42.dmg")
        #expect(release.sha256 == Self.checksum)
        #expect(release.publishedAt == Date(timeIntervalSince1970: 1_767_323_045))
        #expect(release.notes == "Faster first sync.")
        #expect(release.label == "1.2.0 (build 42)")
    }

    @Test func notesAndDateAreOptional() throws {
        let release = try ReleaseInfo.decode(json("""
            "version": "1.2.0", "build": 42, "file": "Photo-Syncer-1.2.0-42.dmg", "sha256": "\(Self.checksum)"
            """))
        #expect(release.notes == nil)
        #expect(release.publishedAt == nil)
    }

    @Test(arguments: [
        "not json at all",
        "{}",
        // No build.
        #"{"version": "1.2.0", "file": "a.dmg", "sha256": "\#(checksum)"}"#,
        // The build as text, zero, and negative.
        #"{"version": "1.2.0", "build": "42", "file": "a.dmg", "sha256": "\#(checksum)"}"#,
        #"{"version": "1.2.0", "build": 0, "file": "a.dmg", "sha256": "\#(checksum)"}"#,
        #"{"version": "1.2.0", "build": -3, "file": "a.dmg", "sha256": "\#(checksum)"}"#,
        // No version.
        #"{"version": " ", "build": 42, "file": "a.dmg", "sha256": "\#(checksum)"}"#,
        // A checksum that's too short, or not hex.
        #"{"version": "1.2.0", "build": 42, "file": "a.dmg", "sha256": "abc123"}"#,
        #"{"version": "1.2.0", "build": 42, "file": "a.dmg", "sha256": "\#(String(repeating: "zz", count: 32))"}"#,
        // A file that isn't a disk image next to latest.json.
        #"{"version": "1.2.0", "build": 42, "file": "../Elsewhere/a.dmg", "sha256": "\#(checksum)"}"#,
        #"{"version": "1.2.0", "build": 42, "file": "/tmp/a.dmg", "sha256": "\#(checksum)"}"#,
        #"{"version": "1.2.0", "build": 42, "file": "sub/a.dmg", "sha256": "\#(checksum)"}"#,
        #"{"version": "1.2.0", "build": 42, "file": ".dmg", "sha256": "\#(checksum)"}"#,
        #"{"version": "1.2.0", "build": 42, "file": "a.pkg", "sha256": "\#(checksum)"}"#,
        #"{"version": "1.2.0", "build": 42, "file": "", "sha256": "\#(checksum)"}"#,
        // A date that isn't one.
        #"{"version": "1.2.0", "build": 42, "file": "a.dmg", "sha256": "\#(checksum)", "publishedAt": "yesterday"}"#,
    ])
    func malformedLatestJsonIsRejected(_ text: String) {
        #expect { try ReleaseInfo.decode(Data(text.utf8)) } throws: { error in
            guard case UpdateError.malformed = error else { return false }
            return true
        }
    }

    // MARK: Newer, same, older

    @Test func onlyAHigherBuildIsNewer() {
        let release = ReleaseInfo(version: "1.2.0", build: 42, file: "a.dmg", sha256: Self.checksum)
        #expect(release.isNewer(than: 41))
        #expect(!release.isNewer(than: 42))
        #expect(!release.isNewer(than: 43))
    }

    @Test func theVersionTextDoesNotDecide() {
        // A lower version with a higher build is still the newer build, and the other way round.
        #expect(ReleaseInfo(version: "0.9", build: 50, file: "a.dmg", sha256: Self.checksum).isNewer(than: 42))
        #expect(!ReleaseInfo(version: "9.0", build: 7, file: "a.dmg", sha256: Self.checksum).isNewer(than: 42))
    }

    @Test func checkerReportsOnlyNewerReleases() async throws {
        let folders = Folders()
        let published = try folders.publish(build: 42)
        #expect(try await folders.checker(currentBuild: 41).newerRelease() == published)
        #expect(try await folders.checker(currentBuild: 42).newerRelease() == nil)
        #expect(try await folders.checker(currentBuild: 43).newerRelease() == nil)
    }

    // MARK: The release folder

    @Test func folderSourceFindsTheImageNextToLatestJson() async throws {
        let folders = Folders()
        try folders.publish(version: "1.2.0", build: 42)
        let source = FolderReleaseSource(folder: folders.releases)
        let release = try await source.latest()
        #expect(release.build == 42)
        let image = try source.imageURL(for: release)
        #expect(image.deletingLastPathComponent().standardizedFileURL == folders.releases.standardizedFileURL)
        #expect(image.lastPathComponent == "Photo-Syncer-1.2.0-42.dmg")
        #expect(FileManager.default.fileExists(atPath: image.path))
    }

    @Test func folderSourceNeverLooksOutsideItsFolder() {
        let source = FolderReleaseSource(folder: Folders().releases)
        let escaping = ReleaseInfo(version: "1.2.0", build: 42, file: "../../secrets.dmg", sha256: Self.checksum)
        #expect(throws: UpdateError.self) { try source.imageURL(for: escaping) }
    }

    @Test func aFolderWithoutLatestJsonHasNoRelease() async {
        let folders = Folders()
        await #expect(throws: UpdateError.noRelease(PortablePath.display(folders.releases.path))) {
            try await FolderReleaseSource(folder: folders.releases).latest()
        }
    }

    @Test func aMissingFolderIsReported() async {
        let folders = Folders()
        let gone = folders.root.appendingPathComponent("Not Mounted/Releases")
        await #expect(throws: UpdateError.folderMissing(PortablePath.display(gone.path))) {
            try await FolderReleaseSource(folder: gone).latest()
        }
    }

    @Test func malformedLatestJsonInTheFolderIsReported() async throws {
        let folders = Folders()
        try Data("{ \"version\": ".utf8).write(to: folders.releases.appendingPathComponent("latest.json"))
        await #expect(throws: UpdateError.malformed("it isn't valid JSON.")) {
            try await FolderReleaseSource(folder: folders.releases).latest()
        }
    }

    // MARK: Downloading and verifying

    @Test func downloadKeepsAVerifiedCopy() async throws {
        let folders = Folders()
        let release = try folders.publish(contents: "disk image 42")
        let checker = folders.checker(currentBuild: 41)

        let staged = try await checker.download(release)
        #expect(staged == checker.stagedImage(for: release))
        #expect(try String(contentsOf: staged, encoding: .utf8) == "disk image 42")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folders.staging.path) == [release.file], "no partial file is left")
    }

    @Test func aVerifiedCopyIsNotFetchedAgain() async throws {
        let folders = Folders()
        let release = try folders.publish()
        let checker = folders.checker(currentBuild: 41)
        _ = try await checker.download(release)

        // The release folder going away (a drive unmounted) doesn't matter once the copy is here.
        try FileManager.default.removeItem(at: folders.releases)
        let again = try await checker.download(release)
        #expect(FileManager.default.fileExists(atPath: again.path))
    }

    @Test func aBadChecksumIsRejected() async throws {
        let folders = Folders()
        let release = try folders.publish(sha256: Self.checksum)
        let checker = folders.checker(currentBuild: 41)

        await #expect(throws: UpdateError.checksumMismatch(release.file)) { try await checker.download(release) }
        #expect(!FileManager.default.fileExists(atPath: checker.stagedImage(for: release).path))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: folders.staging.path)) ?? [] == [], "the bad copy isn't kept")
    }

    @Test func aStagedCopyThatNoLongerMatchesIsReplaced() async throws {
        let folders = Folders()
        let release = try folders.publish(contents: "the real image")
        let checker = folders.checker(currentBuild: 41)
        try FileManager.default.createDirectory(at: folders.staging, withIntermediateDirectories: true)
        try Data("half a download".utf8).write(to: checker.stagedImage(for: release))

        let staged = try await checker.download(release)
        #expect(try String(contentsOf: staged, encoding: .utf8) == "the real image")
    }

    @Test func aMissingImageIsReported() async throws {
        let folders = Folders()
        // latest.json arrived, the disk image hasn't (a folder that's still syncing).
        let release = try folders.publish(sha256: Self.checksum, writeImage: false)
        await #expect(throws: UpdateError.missingImage(release.file)) {
            try await folders.checker(currentBuild: 41).download(release)
        }
    }

    @Test func verifyComparesTheSha256() throws {
        let folders = Folders()
        let file = folders.releases.appendingPathComponent("a.dmg")
        try Data("abc".utf8).write(to: file)
        let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        #expect(try Hashing.sha256(of: file) == expected)
        try UpdateChecker.verify(file, sha256: expected)
        try UpdateChecker.verify(file, sha256: expected.uppercased())
        #expect(throws: UpdateError.checksumMismatch("a.dmg")) { try UpdateChecker.verify(file, sha256: Self.checksum) }
    }

    @Test func olderStagedImagesAreCleared() async throws {
        let folders = Folders()
        let checker = folders.checker(currentBuild: 41)
        let old = try folders.publish(build: 42, contents: "42")
        _ = try await checker.download(old)
        let new = try folders.publish(build: 43, contents: "43")
        _ = try await checker.download(new)

        checker.removeStaged(except: new)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folders.staging.path) == [new.file])
        checker.removeStaged()
        #expect(try FileManager.default.contentsOfDirectory(atPath: folders.staging.path) == [])
    }

    // MARK: This Mac's settings

    @Test func releaseFolderRoundTripsThroughPortablePath() {
        let settings = UpdateSettings(releaseFolder: "/Users/sam/Dropbox/Photo Syncer Releases")
        let stored = settings.withPortablePath(home: "/Users/sam")
        #expect(stored.releaseFolder == "~/Dropbox/Photo Syncer Releases")
        // The same setting on a Mac with another user name.
        #expect(stored.releaseFolderURL(home: "/Users/alex")?.path == "/Users/alex/Dropbox/Photo Syncer Releases")
        // A folder outside the home folder is kept as it is.
        let shared = UpdateSettings(releaseFolder: "/Volumes/Shared/Releases").withPortablePath(home: "/Users/sam")
        #expect(shared.releaseFolder == "/Volumes/Shared/Releases")
        #expect(UpdateSettings().releaseFolderURL() == nil)
        #expect(UpdateSettings(releaseFolder: "").withPortablePath().releaseFolder == nil)
    }

    @Test func updateSettingsStayOnThisMac() throws {
        let folders = Folders()
        let shared = folders.root.appendingPathComponent("Documents/Photo Syncer")
        let storage = Storage(localRoot: folders.local, dataRoot: shared)
        #expect(storage.loadUpdateSettings() == UpdateSettings(), "defaults: no folder, checking automatically")
        #expect(storage.loadUpdateSettings().checkAutomatically)

        let checked = Date(timeIntervalSince1970: 1_767_323_045)
        let folder = NSHomeDirectory() + "/Dropbox/Photo Syncer Releases"
        try storage.saveUpdateSettings(UpdateSettings(releaseFolder: folder, checkAutomatically: false, lastChecked: checked))

        let loaded = storage.loadUpdateSettings()
        #expect(loaded.releaseFolder == "~/Dropbox/Photo Syncer Releases")
        #expect(loaded.releaseFolderURL()?.path == folder)
        #expect(!loaded.checkAutomatically)
        #expect(loaded.lastChecked == checked)
        let onDisk = try String(contentsOf: storage.updateSettingsURL, encoding: .utf8).replacingOccurrences(of: "\\/", with: "/")
        #expect(onDisk.contains("~/Dropbox") && !onDisk.contains(NSHomeDirectory()), "the file holds the ~ form")
        #expect(FileManager.default.fileExists(atPath: folders.local.appendingPathComponent("updates.json").path))
        #expect(!FileManager.default.fileExists(atPath: shared.appendingPathComponent("updates.json").path))
        #expect(storage.updateStagingDirectory.path.hasPrefix(folders.local.path), "a throwaway home keeps its downloads to itself")
    }

    @Test func settingsFromAnOlderFileGetDefaults() throws {
        let settings = try JSONDecoder.syncer.decode(UpdateSettings.self, from: Data(#"{"releaseFolder": "~/Releases"}"#.utf8))
        #expect(settings.checkAutomatically)
        #expect(settings.lastChecked == nil)
    }
}
