import AppKit
import PhotoSyncerCore

/// The running app, when it's a built "Photo Syncer.app" (not `swift run`).
struct InstalledApp: Equatable {
    let bundleURL: URL
    let bundleID: String
    let version: String
    let build: Int

    var label: String { "\(version) (build \(build))" }

    static let current: InstalledApp? = {
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension == "app", let bundleID = bundle.bundleIdentifier,
              let build = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init) else { return nil }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return InstalledApp(bundleURL: bundle.bundleURL, bundleID: bundleID, version: version, build: build)
    }()
}

/// Publish → release → update, the app's side of it.
///
/// `scripts/publish.sh` puts a disk image and `latest.json` in the release folder. This looks
/// there (at launch, when the app comes forward, and on Check Now), copies a newer build's
/// disk image into the caches folder and checks its sha256, and then waits: nothing is
/// installed until the person clicks Install & Restart. Finding and verifying a release is
/// `UpdateChecker` in PhotoSyncerCore; replacing the app is `UpdateInstaller` below.
@MainActor
final class Updater: ObservableObject {
    enum Status: Equatable {
        case notChecked
        case checking
        case upToDate
        case downloading(ReleaseInfo)
        case ready(ReleaseInfo)
        case installing(ReleaseInfo)
        case failed(String)
    }

    @Published private(set) var status: Status = .notChecked
    @Published private(set) var settings: UpdateSettings
    /// What happened to the last install, when it needs saying (it failed).
    @Published private(set) var notice: String?

    /// Nil when this isn't a built app: there's no build number to compare and no bundle to replace.
    let app: InstalledApp?

    /// How often the app checks by itself while it stays open (it also checks at launch).
    static let automaticInterval: TimeInterval = 60 * 60

    private let storage: Storage
    private let log: (String) -> Void
    private let isSyncing: () -> Bool
    /// With PHOTO_SYNCER_SNAPSHOT the app only draws its panes: no checking, copying or installing.
    private let inert: Bool
    /// For testing the installer from a script, against a throwaway home and a scratch copy of
    /// the app: installs a ready update without waiting for the click.
    private let installsWithoutAsking: Bool
    private var lastAttempt: Date?
    private var lastLoggedFailure: String?
    /// Bumped whenever a running check should no longer report (a new check, a new folder, an install).
    private var generation = 0
    private var isChecking = false

    init(storage: Storage, app: InstalledApp? = .current, log: @escaping (String) -> Void, isSyncing: @escaping () -> Bool) {
        self.storage = storage
        self.app = app
        self.log = log
        self.isSyncing = isSyncing
        settings = storage.loadUpdateSettings()
        let environment = ProcessInfo.processInfo.environment
        inert = !(environment["PHOTO_SYNCER_SNAPSHOT"] ?? "").isEmpty
        installsWithoutAsking = environment["PHOTO_SYNCER_UPDATE_AUTOINSTALL"] == "1"
            && !(environment["PHOTO_SYNCER_HOME"] ?? "").isEmpty
    }

    var releaseFolder: URL? { settings.releaseFolderURL() }

    /// Whether Install & Restart has something to install.
    var readyRelease: ReleaseInfo? {
        if case .ready(let release) = status { return release }
        return nil
    }

    var isBusy: Bool {
        switch status {
        case .checking, .downloading, .installing: return true
        default: return isChecking
        }
    }

    private var stagingDirectory: URL { storage.updateStagingDirectory }

    // MARK: Settings

    func setReleaseFolder(_ folder: URL) {
        settings.releaseFolder = PortablePath.portable(folder.path)
        saveSettings()
        status = .notChecked
        check()
    }

    func setCheckAutomatically(_ on: Bool) {
        settings.checkAutomatically = on
        saveSettings()
        if on { checkIfDue() }
    }

    private func saveSettings() {
        do {
            try storage.saveUpdateSettings(settings)
        } catch {
            log("Couldn't save the update settings: \(error.localizedDescription)")
        }
    }

    // MARK: Checking and downloading

    /// At launch: reports how the last install went, then checks.
    func start() {
        guard !inert, app != nil else { return }
        switch UpdateInstaller.takeResult(in: stagingDirectory) {
        case .installed:
            log("Updated to version \(app?.label ?? "?")")
        case .failed:
            notice = "The last update couldn't be installed, so the previous version was kept. What happened is in \(PortablePath.display(UpdateInstaller.logURL(in: stagingDirectory).path))."
            log("The last update couldn't be installed; the previous version was kept.")
        case .none:
            break
        }
        checkIfDue()
    }

    /// The automatic check: at launch, and when the app comes forward if it's been a while.
    func checkIfDue() {
        guard settings.checkAutomatically else { return }
        if let lastAttempt, Date().timeIntervalSince(lastAttempt) < Updater.automaticInterval { return }
        check()
    }

    /// Looks for a newer release now, and downloads and verifies it if there is one.
    func check() {
        guard !inert, let app else { return }
        if case .installing = status { return }
        guard let folder = releaseFolder else {
            status = .notChecked
            return
        }
        generation += 1
        let run = generation
        lastAttempt = Date()
        // A re-check while an update is waiting keeps showing it (and keeps the button usable).
        let waiting = readyRelease
        if waiting == nil { status = .checking }
        isChecking = true
        let checker = UpdateChecker(source: FolderReleaseSource(folder: folder), currentBuild: app.build, stagingDirectory: stagingDirectory)

        Task {
            do {
                let release = try await Task.detached { try await checker.newerRelease() }.value
                guard run == generation else { return }
                recordCheck()
                guard let release else {
                    checker.removeStaged()
                    finish(.upToDate)
                    return
                }
                if release != waiting { status = .downloading(release) }
                _ = try await Task.detached { try await checker.download(release) }.value
                guard run == generation else { return }
                checker.removeStaged(except: release)
                if release != waiting { log("Version \(release.label) is downloaded and ready to install.") }
                finish(.ready(release))
                if installsWithoutAsking { install() }
            } catch {
                guard run == generation else { return }
                recordCheck()
                let message = error.localizedDescription
                if message != lastLoggedFailure { log("Checking for updates: \(message)") }
                lastLoggedFailure = message
                // A build that's already downloaded and checked stays installable when the
                // release folder can't be reached (a shared drive that isn't connected).
                if let waiting, FileManager.default.fileExists(atPath: checker.stagedImage(for: waiting).path) {
                    isChecking = false
                } else {
                    finish(.failed(message))
                }
            }
        }
    }

    private func finish(_ status: Status) {
        isChecking = false
        if case .failed = status {} else { lastLoggedFailure = nil }
        self.status = status
    }

    private func recordCheck() {
        settings.lastChecked = Date()
        saveSettings()
    }

    // MARK: Installing

    /// Install & Restart: checks the downloaded build, hands the swap to a helper that outlives
    /// the app, and quits. The helper puts the new app in place and opens it.
    func install() {
        guard !inert, let app, let release = readyRelease, !isSyncing() else { return }
        generation += 1
        isChecking = false
        status = .installing(release)
        notice = nil
        let staging = stagingDirectory
        let image = staging.appendingPathComponent(release.file)

        Task {
            do {
                let payload = try await Task.detached {
                    try UpdateInstaller.prepare(image: image, release: release, replacing: app, in: staging)
                }.value
                // A sync may have started while the build was being checked: don't quit under it.
                guard !isSyncing() else {
                    status = .ready(release)
                    return
                }
                try UpdateInstaller.handOff(payload: payload, replacing: app, in: staging)
                log("Installing version \(release.label); Photo Syncer will reopen.")
                // An ordinary quit, so the sync lock is released and settings are flushed.
                NSApp.terminate(nil)
            } catch {
                let message = "Version \(release.label) couldn't be installed: \(error.localizedDescription)"
                log(message)
                status = .failed(message)
            }
        }
    }
}

/// Replaces the running app with a downloaded build. The app can't overwrite itself while it
/// runs, so the swap is done by a small shell script that waits for the app to quit.
enum UpdateInstaller {
    enum Failure: Error, LocalizedError {
        case translocated
        case notWritable(String)
        case noApp
        case wrongBuild(found: String, expected: Int)
        case notNewer(Int)
        case badSignature(String)
        case differentSigner
        case tool(String, String)

        var errorDescription: String? {
            switch self {
            case .translocated:
                return "macOS is running Photo Syncer from a temporary, read-only place. Move it to your Applications folder, open it from there, and try again."
            case .notWritable(let folder):
                return "Photo Syncer can't change \(folder), where it's installed."
            case .noApp:
                return "the disk image doesn't contain Photo Syncer."
            case .wrongBuild(let found, let expected):
                return "the disk image contains build \(found), not the build \(expected) that was announced."
            case .notNewer(let build):
                return "the disk image contains build \(build), which isn't newer than this one."
            case .badSignature(let details):
                return "the new app's code signature doesn't check out (\(details))."
            case .differentSigner:
                return "the new app is signed by someone other than the signer of this one."
            case .tool(let name, let output):
                return "\(name) failed: \(output)"
            }
        }
    }

    enum Result: String {
        case installed, failed
    }

    static func logURL(in staging: URL) -> URL { staging.appendingPathComponent("install.log") }
    private static func resultURL(in staging: URL) -> URL { staging.appendingPathComponent("install-result") }
    private static func workDirectory(in staging: URL) -> URL { staging.appendingPathComponent("Install", isDirectory: true) }

    /// How the last install ended, if one ran since this was last asked. Also clears what an
    /// install leaves behind (the helper script, an unpacked app that was never installed).
    static func takeResult(in staging: URL) -> Result? {
        let files = FileManager.default
        let work = workDirectory(in: staging)
        if files.fileExists(atPath: work.path) {
            let mount = work.appendingPathComponent("mount", isDirectory: true)
            if ((try? files.contentsOfDirectory(atPath: mount.path)) ?? []).isEmpty == false { detach(mount) }
            try? files.removeItem(at: work)
        }
        let url = resultURL(in: staging)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        try? files.removeItem(at: url)
        return Result(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Unpacks the verified disk image and checks the app inside it: the same bundle id, the
    /// announced build, newer than this one, a valid code signature, and the same signing team
    /// when this app has one. Returns the unpacked app, ready for `handOff`. Blocking.
    static func prepare(image: URL, release: ReleaseInfo, replacing app: InstalledApp, in staging: URL) throws -> URL {
        let files = FileManager.default
        // Gatekeeper runs a quarantined app from a random read-only mount: there's nothing to replace.
        guard !app.bundleURL.path.contains("/AppTranslocation/") else { throw Failure.translocated }
        let parent = app.bundleURL.deletingLastPathComponent()
        guard files.isWritableFile(atPath: parent.path) else { throw Failure.notWritable(PortablePath.display(parent.path)) }

        // The disk image has sat in the caches folder since it was checked; check it again.
        try UpdateChecker.verify(image, sha256: release.sha256)

        let work = workDirectory(in: staging)
        let mount = work.appendingPathComponent("mount", isDirectory: true)
        if files.fileExists(atPath: mount.path) { _ = try? run("/usr/bin/hdiutil", "detach", mount.path, "-force") }
        try? files.removeItem(at: work)
        try files.createDirectory(at: mount, withIntermediateDirectories: true)

        try attach(image, at: mount)
        let payload = work.appendingPathComponent(app.bundleURL.lastPathComponent, isDirectory: true)
        do {
            defer { detach(mount) }
            let apps = try files.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil).filter { $0.pathExtension == "app" }
            guard let source = apps.first(where: { info($0)?["CFBundleIdentifier"] as? String == app.bundleID }) else {
                throw Failure.noApp
            }
            try run("/usr/bin/ditto", source.path, payload.path)
        }

        do {
            try check(payload, is: release, replacing: app)
        } catch {
            try? files.removeItem(at: payload)
            throw error
        }
        return payload
    }

    private static func check(_ payload: URL, is release: ReleaseInfo, replacing app: InstalledApp) throws {
        guard let info = info(payload), info["CFBundleIdentifier"] as? String == app.bundleID else { throw Failure.noApp }
        let found = info["CFBundleVersion"] as? String ?? "?"
        guard Int(found) == release.build else { throw Failure.wrongBuild(found: found, expected: release.build) }
        guard release.build > app.build else { throw Failure.notNewer(release.build) }
        do {
            try run("/usr/bin/codesign", "--verify", "--deep", "--strict", payload.path)
        } catch Failure.tool(_, let output) {
            throw Failure.badSignature(output)
        }
        // An ad hoc signature has no team, so there's nothing to compare; a real one must match.
        if let team = signingTeam(of: app.bundleURL), signingTeam(of: payload) != team { throw Failure.differentSigner }
    }

    /// Starts the helper that swaps the bundles once this process has quit. Call
    /// `NSApp.terminate` straight after.
    static func handOff(payload: URL, replacing app: InstalledApp, in staging: URL) throws {
        let script = workDirectory(in: staging).appendingPathComponent("install.sh")
        try helperScript.write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: resultURL(in: staging))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // nohup and "&" detach the helper, so it carries on when the app (its parent) is gone.
        process.arguments = [
            "-c", #"/usr/bin/nohup /bin/sh "$0" "$@" >/dev/null 2>&1 &"#, script.path,
            String(ProcessInfo.processInfo.processIdentifier), payload.path, app.bundleURL.path,
            logURL(in: staging).path, resultURL(in: staging).path,
        ]
        // The reopened app gets the helper's environment; the testing switch stops here.
        process.environment = ProcessInfo.processInfo.environment.filter { $0.key != "PHOTO_SYNCER_UPDATE_AUTOINSTALL" }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    /// The helper. The new app is copied next to the installed one first, so the installed app
    /// is only touched by two renames; if the second fails, the first is undone.
    static let helperScript = #"""
        #!/bin/sh
        # Photo Syncer's update helper: puts a new build in place once the app has quit, then
        # opens it. Written and started by the app (Updater.swift); never run by hand.
        #   $1  the app's process id       $2  the new app, already checked by the app
        #   $3  the installed app          $4  a log of what happened
        #   $5  where to leave "installed" or "failed" for the app to read when it reopens
        pid="$1"
        new="$2"
        target="$3"
        log="$4"
        result="$5"
        case "$target" in
            /*.app) ;;
            *) exit 64 ;;
        esac
        [ -d "$new" ] && [ -n "$log" ] && [ -n "$result" ] || exit 64
        incoming="$target.incoming"
        backup="$target.previous"

        : >"$log"
        exec >>"$log" 2>&1
        say() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

        reopen() {
            # A throwaway home (PHOTO_SYNCER_HOME) carries over; `open` wouldn't pass it on.
            if [ -n "${PHOTO_SYNCER_HOME:-}" ]; then
                /usr/bin/open --env "PHOTO_SYNCER_HOME=$PHOTO_SYNCER_HOME" "$target"
            else
                /usr/bin/open "$target"
            fi
        }

        give_up() {
            say "$1"
            echo "failed" >"$result"
            rm -rf "$incoming"
        }

        say "Waiting for Photo Syncer (process $pid) to quit"
        waited=0
        while kill -0 "$pid" 2>/dev/null; do
            waited=$((waited + 1))
            if [ "$waited" -gt 300 ]; then
                give_up "It was still running after a minute; nothing was changed."
                exit 1
            fi
            sleep 0.2
        done

        rm -rf "$incoming" "$backup"
        if ! /usr/bin/ditto "$new" "$incoming" || ! /usr/bin/codesign --verify --deep --strict "$incoming"; then
            give_up "Couldn't copy the new version next to the installed one; nothing was changed."
            reopen
            exit 1
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$incoming" 2>/dev/null

        if ! mv "$target" "$backup"; then
            give_up "Couldn't move the installed version aside; nothing was changed."
            reopen
            exit 1
        fi

        if mv "$incoming" "$target"; then
            touch "$target"
            rm -rf "$backup" "$new"
            say "Installed the new version at $target"
            echo "installed" >"$result"
            status=0
        else
            say "Couldn't move the new version into place; putting the previous one back."
            if mv "$backup" "$target"; then
                give_up "The previous version is back in place."
            else
                give_up "Couldn't put it back either: the previous version is at $backup"
            fi
            status=1
        fi

        reopen
        exit "$status"

        """#

    // MARK: Tools

    private static func info(_ app: URL) -> [String: Any]? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
    }

    /// The Team ID an app is signed with; nil for ad hoc and self-signed apps.
    private static func signingTeam(of app: URL) -> String? {
        guard let output = try? run("/usr/bin/codesign", "-dv", "--verbose=2", app.path) else { return nil }
        for line in output.split(separator: "\n") where line.hasPrefix("TeamIdentifier=") {
            let team = String(line.dropFirst("TeamIdentifier=".count))
            return team == "not set" ? nil : team
        }
        return nil
    }

    /// Mounts a disk image where Finder won't show it. `hdiutil attach` works on every macOS
    /// the app supports but is deprecated from macOS 27, which points at `diskutil image`
    /// instead; that's the fallback for when hdiutil stops doing it.
    private static func attach(_ image: URL, at mount: URL) throws {
        do {
            try run("/usr/bin/hdiutil", "attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, image.path)
        } catch {
            guard (try? run("/usr/sbin/diskutil", "image", "attach", "--readOnly", "--nobrowse", "--mountPoint", mount.path, image.path)) != nil else {
                throw error
            }
        }
    }

    private static func detach(_ mount: URL) {
        if (try? run("/usr/bin/hdiutil", "detach", mount.path)) != nil { return }
        if (try? run("/usr/sbin/diskutil", "eject", mount.path)) != nil { return }
        _ = try? run("/usr/bin/hdiutil", "detach", mount.path, "-force")
    }

    /// Runs a tool and returns what it printed; throws with that output if it fails. The output
    /// goes through a file, not a pipe: hdiutil leaves a helper running that would hold a pipe
    /// open, and reading it to the end would wait on that helper.
    @discardableResult
    private static func run(_ tool: String, _ arguments: String...) throws -> String {
        let files = FileManager.default
        let capture = files.temporaryDirectory.appendingPathComponent("photo-syncer-update-\(UUID().uuidString).txt")
        files.createFile(atPath: capture.path, contents: nil)
        defer { try? files.removeItem(at: capture) }
        let output = try FileHandle(forWritingTo: capture)
        defer { try? output.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        let printed = ((try? String(contentsOf: capture, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw Failure.tool(URL(fileURLWithPath: tool).lastPathComponent, printed.isEmpty ? "exit \(process.terminationStatus)" : printed)
        }
        return printed
    }
}
