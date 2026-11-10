import AppKit
import PhotoSyncerCore
import SwiftUI

/// What the window shows for one mapping.
struct MappingStatus {
    var progress: SyncProgress?
    var outcome: SyncOutcome?
    var syncedCount: Int = 0
}

@MainActor
final class AppModel: ObservableObject {
    let storage = Storage()
    let log: SyncLog
    private(set) var engine: SyncEngine!

    @Published var config: AppConfig
    @Published var statuses: [UUID: MappingStatus] = [:]
    @Published var accountMessages: [UUID: String] = [:]
    @Published var isSyncing = false
    @Published var logLines: [String] = []
    @Published var signingIn: Account?
    @Published var pane: Pane? = .sync

    private var syncTask: Task<Void, Never>?
    /// Service clients made during a sync, so refreshed cookies can be saved afterwards.
    private var liveServices: [UUID: RemoteService] = [:]

    init() {
        log = SyncLog(directory: storage.logsDirectory)
        config = storage.loadConfig()
        engine = SyncEngine(storage: storage, serviceFactory: { [weak self] account in
            guard let self else { throw SyncError.cancelled }
            return try await self.makeService(account)
        }, log: log)
        log.onLine = { [weak self] line in
            Task { @MainActor in
                self?.logLines.append(line)
                if (self?.logLines.count ?? 0) > 500 { self?.logLines.removeFirst(100) }
            }
        }
        if let today = try? String(contentsOf: log.todayURL, encoding: .utf8) {
            logLines = today.split(separator: "\n").suffix(300).map(String.init)
        }
        refreshCounts()
    }

    // MARK: Config

    func save() {
        do { try storage.saveConfig(config) } catch { log.write("Couldn't save settings: \(error.localizedDescription)") }
    }

    func account(_ id: UUID) -> Account? { config.account(id) }

    func refreshCounts() {
        for mapping in config.mappings {
            statuses[mapping.id, default: MappingStatus()].syncedCount = engine.ledger(for: mapping).count
        }
    }

    func addAccount(_ account: Account) {
        config.accounts.append(account)
        save()
    }

    func updateAccount(_ account: Account) {
        guard let index = config.accounts.firstIndex(where: { $0.id == account.id }) else { return }
        config.accounts[index] = account
        save()
    }

    func removeAccount(_ account: Account) {
        for mapping in config.mappings where mapping.accountId == account.id { removeMapping(mapping) }
        config.accounts.removeAll { $0.id == account.id }
        try? storage.setSecret("google.\(account.id.uuidString)", nil)
        save()
        Task { await WebSessions.remove(account) }
    }

    func upsertMapping(_ mapping: Mapping) {
        if let index = config.mappings.firstIndex(where: { $0.id == mapping.id }) {
            config.mappings[index] = mapping
        } else {
            config.mappings.append(mapping)
        }
        save()
        refreshCounts()
    }

    func removeMapping(_ mapping: Mapping) {
        config.mappings.removeAll { $0.id == mapping.id }
        engine.forget(mapping)
        statuses[mapping.id] = nil
        save()
    }

    // MARK: Services

    func makeService(_ account: Account) async throws -> RemoteService {
        if let live = liveServices[account.id] { return live }
        let service: RemoteService
        switch account.service {
        case .amazon:
            let cookies = await WebSessions.cookies(for: account)
            guard cookies.contains(where: { $0.name == "session-id" && $0.domain.hasSuffix("amazon.com") }) else {
                throw SyncError.notSignedIn("Amazon Photos (\(account.name))")
            }
            service = AmazonPhotosService(cookies: cookies)
        case .pixstar:
            let cookies = await WebSessions.cookies(for: account)
            guard cookies.contains(where: { $0.name == "csrftoken" && $0.domain.hasSuffix("pix-star.com") }) else {
                throw SyncError.notSignedIn("Pix-Star (\(account.name))")
            }
            service = PixStarService(cookies: cookies)
        case .google:
            guard let client = config.google, let secret = storage.secret("google.clientSecret") else {
                throw SyncError.unexpected("Set up Google first: Accounts › Google Photos setup.")
            }
            let key = "google.\(account.id.uuidString)"
            guard let stored = storage.secret(key), let tokens = try? JSONDecoder().decode(GoogleTokens.self, from: Data(stored.utf8)) else {
                throw SyncError.notSignedIn("Google Photos (\(account.name))")
            }
            let storage = storage
            service = GooglePhotosService(tokens: GoogleTokenSource(clientId: client.clientId, clientSecret: secret, tokens: tokens, save: { updated in
                if let data = try? JSONEncoder().encode(updated) { try? storage.setSecret(key, String(decoding: data, as: UTF8.self)) }
            }))
        case .folder:
            guard let path = account.folderPath else { throw SyncError.unexpected("Choose a folder for \(account.name).") }
            service = FolderDestinationService(path: path)
        }
        if isSyncing { liveServices[account.id] = service }
        return service
    }

    /// Saves refreshed cookies and forgets the clients made for a sync.
    private func finishServices() async {
        for (id, service) in liveServices {
            guard let account = account(id) else { continue }
            if let amazon = service as? AmazonPhotosService { await WebSessions.save(amazon.currentCookies, for: account) }
            if let pixstar = service as? PixStarService { await WebSessions.save(pixstar.currentCookies, for: account) }
        }
        liveServices = [:]
    }

    func verify(_ account: Account) async {
        accountMessages[account.id] = "Checking…"
        do {
            let who = try await makeService(account).verify()
            var updated = account
            if let who, account.service != .folder { updated.signedInAs = who }
            updateAccount(updated)
            accountMessages[account.id] = "Signed in" + (who.map { " as \($0)" } ?? "")
        } catch {
            accountMessages[account.id] = error.localizedDescription
        }
    }

    // MARK: Google

    func signInToGoogle(_ account: Account) async {
        guard let client = config.google, let secret = storage.secret("google.clientSecret") else {
            accountMessages[account.id] = "Set up Google first (Google Photos setup)."
            return
        }
        accountMessages[account.id] = "Finish signing in in your browser…"
        do {
            let tokens = try await GoogleOAuth.authorize(clientId: client.clientId, clientSecret: secret) { url in
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            }
            let data = try JSONEncoder().encode(tokens)
            try storage.setSecret("google.\(account.id.uuidString)", String(decoding: data, as: UTF8.self))
            var updated = account
            updated.signedInAs = tokens.email
            updateAccount(updated)
            accountMessages[account.id] = "Signed in" + (tokens.email.map { " as \($0)" } ?? "")
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            accountMessages[account.id] = error.localizedDescription
        }
    }

    func saveGoogleClient(id: String, secret: String) {
        config.google = GoogleClientConfig(clientId: id.trimmingCharacters(in: .whitespacesAndNewlines))
        try? storage.setSecret("google.clientSecret", secret.trimmingCharacters(in: .whitespacesAndNewlines))
        save()
    }

    var hasGoogleClient: Bool { config.google != nil && storage.secret("google.clientSecret") != nil }

    // MARK: Syncing

    func syncAll() {
        run(config.mappings.filter(\.enabled), confirmed: [])
    }

    func sync(_ mapping: Mapping, confirmed: Bool = false) {
        run([mapping], confirmed: confirmed ? [mapping.id] : [])
    }

    func cancel() {
        syncTask?.cancel()
    }

    private func run(_ mappings: [Mapping], confirmed: Set<UUID>) {
        guard !isSyncing, !mappings.isEmpty else { return }
        isSyncing = true
        for mapping in mappings {
            statuses[mapping.id, default: MappingStatus()].progress = SyncProgress(mappingId: mapping.id, phase: "Waiting…")
            statuses[mapping.id]?.outcome = nil
        }
        log.write("Sync started (\(mappings.count) \(mappings.count == 1 ? "mapping" : "mappings"))")
        syncTask = Task {
            for mapping in mappings {
                if Task.isCancelled {
                    statuses[mapping.id]?.progress = nil
                    continue
                }
                // Use the latest copy: an earlier mapping may have changed it.
                guard let current = config.mappings.first(where: { $0.id == mapping.id }),
                      let account = account(current.accountId) else { continue }
                let outcome = await engine.sync(
                    current, account: account, threshold: config.firstSyncReviewThreshold,
                    confirmed: confirmed.contains(current.id),
                    updateMapping: { updated in Task { @MainActor in self.upsertMapping(updated) } },
                    progress: { progress in Task { @MainActor in
                        if self.isSyncing { self.statuses[progress.mappingId]?.progress = progress }
                    } })
                statuses[current.id]?.progress = nil
                statuses[current.id]?.outcome = outcome
            }
            await finishServices()
            refreshCounts()
            log.write(Task.isCancelled ? "Sync cancelled" : "Sync finished")
            isSyncing = false
        }
    }

    /// The person says everything in the source is already in the destination.
    func markAllSynced(_ mapping: Mapping) {
        Task {
            do {
                let count = try await engine.markAllSynced(mapping)
                var updated = mapping
                updated.lastSynced = Date()
                upsertMapping(updated)
                statuses[mapping.id]?.outcome = .finished(uploaded: 0, matched: count, failed: 0, upToDate: 0)
            } catch {
                statuses[mapping.id, default: MappingStatus()].outcome = .failed(error.localizedDescription)
            }
        }
    }

    /// Forgets what a mapping has pushed, so the next sync compares everything again.
    func resetHistory(_ mapping: Mapping) {
        engine.forget(mapping)
        var updated = mapping
        updated.lastSynced = nil
        upsertMapping(updated)
        statuses[mapping.id]?.outcome = nil
    }

    func openLogFolder() {
        NSWorkspace.shared.open(storage.logsDirectory)
    }
}
