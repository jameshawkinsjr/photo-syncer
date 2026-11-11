import Foundation
import SystemConfiguration

/// Where Photo Syncer keeps its files. There are two places:
///
/// The **sync data folder** (default ~/Documents/Photo Syncer), which can be a shared or synced
/// folder (iCloud Drive, Dropbox, a network share) so several Macs use the same setup:
///
///     config.json             accounts, mappings, settings
///     ledger/<mapping>.json   what each mapping has already pushed
///     logs/<date> (<Mac>).log one log per day per Mac
///     sync.lock               which Mac is syncing right now
///
/// **This Mac's folder**, ~/Library/Application Support/Photo Syncer, for things that must not
/// be shared:
///
///     location.json           where the sync data folder is
///     secrets.json            Google client secret and tokens (mode 0600)
///     md5-cache.json          MD5s of source files, by path, size and date
///
/// Amazon and Pix-Star sign-ins live in WebKit's per-account stores, also per Mac.
public struct Storage: Sendable {
    /// Per-Mac files.
    public let localRoot: URL
    /// Shareable files.
    public let dataRoot: URL

    /// The default sync data folder.
    public static let defaultDataPath = "~/Documents/Photo Syncer"

    /// Both kinds of file in one folder (tests, and PHOTO_SYNCER_HOME).
    public init(root: URL) {
        self.init(localRoot: root, dataRoot: root)
    }

    public init(localRoot: URL, dataRoot: URL) {
        self.localRoot = localRoot
        self.dataRoot = dataRoot
        try? FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
    }

    public static var defaultLocalRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photo Syncer", isDirectory: true)
    }

    /// The app's storage: PHOTO_SYNCER_HOME if set (everything in one throwaway folder),
    /// otherwise this Mac's folder plus the sync data folder it points at. Data from before
    /// the sync data folder existed is moved into it the first time.
    public static func standard() -> Storage {
        if let override = ProcessInfo.processInfo.environment["PHOTO_SYNCER_HOME"], !override.isEmpty {
            return Storage(root: URL(fileURLWithPath: PortablePath.expand(override), isDirectory: true))
        }
        let local = defaultLocalRoot
        try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let data = URL(fileURLWithPath: PortablePath.expand(dataPath(in: local) ?? defaultDataPath), isDirectory: true)
        let storage = Storage(localRoot: local, dataRoot: data)
        if dataPath(in: local) == nil {
            storage.adoptLegacyData()
            try? storage.saveDataPath(defaultDataPath)
        }
        return storage
    }

    // MARK: Files

    public var configURL: URL { dataRoot.appendingPathComponent("config.json") }
    public var ledgerDirectory: URL { directory("ledger", in: dataRoot) }
    public var logsDirectory: URL { directory("logs", in: dataRoot) }
    public var lockURL: URL { dataRoot.appendingPathComponent("sync.lock") }

    public var secretsURL: URL { localRoot.appendingPathComponent("secrets.json") }
    public var md5CacheURL: URL { localRoot.appendingPathComponent("md5-cache.json") }
    var locationURL: URL { localRoot.appendingPathComponent("location.json") }

    private func directory(_ name: String, in root: URL) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The sync data folder as the settings store it ("~/Documents/Photo Syncer").
    public var dataPath: String { PortablePath.portable(dataRoot.path) }

    // MARK: Where the data lives

    private struct Location: Codable { var dataFolder: String }

    static func dataPath(in localRoot: URL) -> String? {
        guard let data = try? Data(contentsOf: localRoot.appendingPathComponent("location.json")),
              let location = try? JSONDecoder().decode(Location.self, from: data) else { return nil }
        return location.dataFolder
    }

    func saveDataPath(_ path: String) throws {
        let data = try JSONEncoder.syncer.encode(Location(dataFolder: PortablePath.portable(path)))
        try data.write(to: locationURL, options: .atomic)
    }

    /// The names of the shareable files, which move together.
    static let dataItems = ["config.json", "ledger", "logs"]

    /// Moves config, ledgers and logs that an earlier version kept in this Mac's folder into the
    /// sync data folder, unless the data folder already has settings (another Mac set it up).
    func adoptLegacyData() {
        guard localRoot.standardizedFileURL != dataRoot.standardizedFileURL,
              FileManager.default.fileExists(atPath: localRoot.appendingPathComponent("config.json").path),
              !FileManager.default.fileExists(atPath: configURL.path) else { return }
        try? Storage.moveDataItems(from: localRoot, to: dataRoot)
    }

    static func moveDataItems(from source: URL, to target: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: target, withIntermediateDirectories: true)
        for name in dataItems {
            let from = source.appendingPathComponent(name)
            let to = target.appendingPathComponent(name)
            guard files.fileExists(atPath: from.path) else { continue }
            var isDirectory: ObjCBool = false
            files.fileExists(atPath: from.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                // Merge folders file by file; a file already at the target is kept.
                try files.createDirectory(at: to, withIntermediateDirectories: true)
                for item in try files.contentsOfDirectory(atPath: from.path) {
                    let destination = to.appendingPathComponent(item)
                    if !files.fileExists(atPath: destination.path) {
                        try files.moveItem(at: from.appendingPathComponent(item), to: destination)
                    }
                }
                try? files.removeItem(at: from)
            } else if !files.fileExists(atPath: to.path) {
                try files.moveItem(at: from, to: to)
            }
        }
    }

    /// Whether a folder already holds Photo Syncer settings.
    public static func hasSyncData(at folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("config.json").path)
    }

    /// Points this Mac at another sync data folder. With `moveData`, the current settings,
    /// ledgers and logs move there (the folder must not already have settings); without it,
    /// the settings already in that folder are used and the current ones are left where they are.
    public func relocate(to folder: URL, moveData: Bool) throws -> Storage {
        if moveData {
            guard !Storage.hasSyncData(at: folder) else {
                throw SyncError.unexpected("\(PortablePath.display(folder.path)) already has Photo Syncer settings.")
            }
            try Storage.moveDataItems(from: dataRoot, to: folder)
        } else {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try saveDataPath(folder.path)
        return Storage(localRoot: localRoot, dataRoot: folder)
    }

    // MARK: Config

    public func loadConfig() -> AppConfig {
        guard let data = try? Data(contentsOf: configURL) else { return AppConfig() }
        return ((try? JSONDecoder.syncer.decode(AppConfig.self, from: data)) ?? AppConfig()).withPortablePaths()
    }

    public func saveConfig(_ config: AppConfig) throws {
        try JSONEncoder.syncer.encode(config.withPortablePaths()).write(to: configURL, options: .atomic)
    }

    /// When config.json last changed, to notice edits made on another Mac.
    public var configModified: Date? {
        (try? configURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // MARK: Secrets

    /// Small secrets (OAuth tokens). Kept in this Mac's folder, readable only by this user,
    /// rather than the keychain, because the app is signed ad hoc and the keychain would ask
    /// again after every rebuild. Never in the shared data folder.
    public func loadSecrets() -> [String: String] {
        guard let data = try? Data(contentsOf: secretsURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    public func saveSecrets(_ secrets: [String: String]) throws {
        let data = try JSONEncoder().encode(secrets)
        try data.write(to: secretsURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretsURL.path)
    }

    public func secret(_ key: String) -> String? { loadSecrets()[key] }

    public func setSecret(_ key: String, _ value: String?) throws {
        var secrets = loadSecrets()
        secrets[key] = value
        try saveSecrets(secrets)
    }
}

/// This Mac's name, as set in System Settings › General › Sharing ("Sam's MacBook Pro").
public enum ThisMac {
    public static let name: String = {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty { return name }
        return ProcessInfo.processInfo.hostName
    }()
}

/// Keeps two Macs sharing a sync data folder from syncing at the same time.
///
/// `sync.lock` records which Mac is syncing; the syncing Mac touches it every minute. A lock
/// that hasn't been touched for `staleAfter` is treated as left behind by a Mac that crashed or
/// went to sleep. With a synced folder (iCloud Drive, Dropbox) the other Mac only sees the lock
/// once the folder has synced, so this is a guard, not a guarantee; the ledgers merge on save
/// as a second line of defence.
public final class SyncLock: @unchecked Sendable {
    public struct Holder: Codable, Equatable, Sendable {
        public var mac: String
        public var token: String
        public var started: Date
        public var heartbeat: Date
    }

    public enum Failure: Error, LocalizedError {
        case busy(Holder)
        public var errorDescription: String? {
            switch self {
            case .busy(let holder):
                let formatter = RelativeDateTimeFormatter()
                return "\(holder.mac) is syncing (started \(formatter.localizedString(for: holder.started, relativeTo: Date())))."
            }
        }
    }

    public static let staleAfter: TimeInterval = 10 * 60

    let url: URL
    let mac: String
    let token = UUID().uuidString
    private let lock = NSLock()
    private var held = false

    public init(url: URL, mac: String = ThisMac.name) {
        self.url = url
        self.mac = mac
    }

    /// Who holds the lock now, if anyone (stale locks included).
    public func current() -> Holder? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.syncer.decode(Holder.self, from: data)
    }

    /// Another Mac's lock that's still fresh, if any.
    public func blocker(now: Date = Date()) -> Holder? {
        guard let holder = current(), holder.token != token else { return nil }
        guard now.timeIntervalSince(holder.heartbeat) < SyncLock.staleAfter else { return nil }
        return holder
    }

    /// Takes the lock. Throws `.busy` if another Mac holds a fresh one, unless `force`.
    public func acquire(force: Bool = false, now: Date = Date()) throws {
        if !force, let holder = blocker(now: now) { throw Failure.busy(holder) }
        try write(Holder(mac: mac, token: token, started: now, heartbeat: now))
        lock.withLock { held = true }
    }

    /// Marks the lock as still in use.
    public func touch(now: Date = Date()) {
        guard lock.withLock({ held }), var holder = current(), holder.token == token else { return }
        holder.heartbeat = now
        try? write(holder)
    }

    /// Gives the lock up, if this Mac still holds it.
    public func release() {
        lock.withLock { held = false }
        if current()?.token == token { try? FileManager.default.removeItem(at: url) }
    }

    private func write(_ holder: Holder) throws {
        try JSONEncoder.syncer.encode(holder).write(to: url, options: .atomic)
    }
}

extension JSONEncoder {
    static let syncer: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension JSONDecoder {
    static let syncer: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
