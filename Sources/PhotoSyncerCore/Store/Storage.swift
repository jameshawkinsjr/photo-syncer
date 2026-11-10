import Foundation

/// Where Photo Syncer keeps its files: ~/Library/Application Support/Photo Syncer.
///
///     config.json          accounts, mappings, settings
///     ledger/<mapping>.json what each mapping has already pushed
///     secrets.json         Google tokens (mode 0600)
///     md5-cache.json       MD5s of source files, by path, size and date
///     logs/                one log per sync
public struct Storage: Sendable {
    public let root: URL

    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else if let override = ProcessInfo.processInfo.environment["PHOTO_SYNCER_HOME"], !override.isEmpty {
            // For trying the app out without touching the real settings.
            self.root = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.root = support.appendingPathComponent("Photo Syncer", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    public var configURL: URL { root.appendingPathComponent("config.json") }
    public var secretsURL: URL { root.appendingPathComponent("secrets.json") }
    public var md5CacheURL: URL { root.appendingPathComponent("md5-cache.json") }
    public var ledgerDirectory: URL { directory("ledger") }
    public var logsDirectory: URL { directory("logs") }
    public var exportCacheDirectory: URL { directory("export-cache") }

    private func directory(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Config

    public func loadConfig() -> AppConfig {
        guard let data = try? Data(contentsOf: configURL) else { return AppConfig() }
        return (try? JSONDecoder.syncer.decode(AppConfig.self, from: data)) ?? AppConfig()
    }

    public func saveConfig(_ config: AppConfig) throws {
        try JSONEncoder.syncer.encode(config).write(to: configURL, options: .atomic)
    }

    // MARK: Secrets

    /// Small secrets (OAuth tokens). Kept in a file only this user can read rather than the
    /// keychain, because the app is signed ad hoc and the keychain would ask again after
    /// every rebuild. Web sign-ins (Amazon, Pix-Star) live in WebKit's own per-account stores.
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
