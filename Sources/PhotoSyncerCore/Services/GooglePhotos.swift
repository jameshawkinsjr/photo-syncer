import CryptoKit
import Foundation
import Network

/// Google Photos, through the official Library API.
///
/// Since March 2025 the API only lets an app see and fill albums **it created**: it can't
/// list or add to albums made in Google Photos itself. So each Google destination is an
/// album Photo Syncer creates ("New album…" in the picker), and the frame is pointed at it.
public final class GooglePhotosService: RemoteService, @unchecked Sendable {
    public let kind = ServiceKind.google
    /// batchCreate takes up to 50 items.
    public let preferredBatchSize = 20

    let http = HTTPClient()
    let tokens: GoogleTokenSource
    static let api = "https://photoslibrary.googleapis.com/v1/"

    public init(tokens: GoogleTokenSource) {
        self.tokens = tokens
    }

    /// Joined as text: `URL(string:relativeTo:)` would read "mediaItems:" in
    /// "mediaItems:search" as a URL scheme and drop the host ("unsupported URL").
    static func endpoint(_ path: String) -> URL {
        URL(string: api + path)!
    }

    private func request(_ path: String, method: String = "GET", json: Any? = nil) async throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint(path))
        request.httpMethod = method
        request.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func call(_ path: String, method: String = "GET", json: Any? = nil) async throws -> [String: Any] {
        do {
            return try await http.json(try await request(path, method: method, json: json))
        } catch SyncError.http(let status, _) where status == 401 {
            throw SyncError.notSignedIn("Google Photos")
        }
    }

    public func verify() async throws -> String? {
        _ = try await call("albums?pageSize=1&excludeNonAppCreatedData=true")
        return tokens.email
    }

    public func albums() async throws -> [RemoteAlbum] {
        var albums: [RemoteAlbum] = []
        var pageToken: String?
        repeat {
            var path = "albums?pageSize=50&excludeNonAppCreatedData=true"
            if let pageToken { path += "&pageToken=\(pageToken.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? pageToken)" }
            let page = try await call(path)
            for album in page["albums"] as? [[String: Any]] ?? [] {
                guard let id = album["id"] as? String else { continue }
                let count = (album["mediaItemsCount"] as? String).flatMap(Int.init)
                albums.append(RemoteAlbum(ref: DestinationRef(id: id, name: album["title"] as? String ?? "Untitled"), count: count))
            }
            pageToken = page["nextPageToken"] as? String
        } while pageToken != nil
        return albums
    }

    public func createAlbum(named name: String) async throws -> DestinationRef {
        let album = try await call("albums", method: "POST", json: ["album": ["title": name]])
        guard let id = album["id"] as? String else { throw SyncError.unexpected("Google didn't create the album.") }
        return DestinationRef(id: id, name: name)
    }

    public func items(in destination: DestinationRef) async throws -> [RemoteItem] {
        var items: [RemoteItem] = []
        var pageToken: String?
        repeat {
            var body: [String: Any] = ["albumId": destination.id, "pageSize": 100]
            if let pageToken { body["pageToken"] = pageToken }
            let page = try await call("mediaItems:search", method: "POST", json: body)
            for item in page["mediaItems"] as? [[String: Any]] ?? [] {
                guard let id = item["id"] as? String else { continue }
                items.append(RemoteItem(id: id, name: item["filename"] as? String ?? id))
            }
            pageToken = page["nextPageToken"] as? String
        } while pageToken != nil
        return items
    }

    public func upload(_ payloads: [UploadPayload], to destination: DestinationRef) async -> [Result<UploadResult, Error>] {
        var results = [Result<UploadResult, Error>?](repeating: nil, count: payloads.count)
        var pending: [(index: Int, token: String)] = []
        for (index, payload) in payloads.enumerated() {
            do {
                var request = try await request("uploads", method: "POST")
                request.httpBody = payload.data
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                request.setValue(payload.mimeType, forHTTPHeaderField: "X-Goog-Upload-Content-Type")
                request.setValue("raw", forHTTPHeaderField: "X-Goog-Upload-Protocol")
                let (data, _) = try await http.send(request)
                pending.append((index, String(decoding: data, as: UTF8.self)))
            } catch {
                results[index] = .failure(error)
            }
        }
        if !pending.isEmpty {
            do {
                let body: [String: Any] = [
                    "albumId": destination.id,
                    "newMediaItems": pending.map { ["simpleMediaItem": ["fileName": payloads[$0.index].fileName, "uploadToken": $0.token]] },
                ]
                let response = try await call("mediaItems:batchCreate", method: "POST", json: body)
                let created = response["newMediaItemResults"] as? [[String: Any]] ?? []
                for (position, entry) in pending.enumerated() {
                    let result = position < created.count ? created[position] : [:]
                    let status = result["status"] as? [String: Any]
                    let code = status?["code"] as? Int ?? 0
                    if code == 0, let item = result["mediaItem"] as? [String: Any] {
                        results[entry.index] = .success(UploadResult(remoteId: item["id"] as? String,
                                                                     remoteName: item["filename"] as? String ?? payloads[entry.index].fileName))
                    } else {
                        let message = status?["message"] as? String ?? "Google didn't add \(payloads[entry.index].fileName)."
                        results[entry.index] = .failure(SyncError.unexpected(message))
                    }
                }
            } catch {
                for entry in pending { results[entry.index] = .failure(error) }
            }
        }
        return results.map { $0 ?? .failure(SyncError.unexpected("No result from Google.")) }
    }
}

// MARK: - Sign-in

public struct GoogleTokens: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiry: Date
    public var email: String?
}

/// Hands out a fresh access token, refreshing it when it's about to expire.
public final class GoogleTokenSource: @unchecked Sendable {
    let clientId: String
    let clientSecret: String
    private var tokens: GoogleTokens
    private let save: @Sendable (GoogleTokens) -> Void
    private let lock = NSLock()

    public init(clientId: String, clientSecret: String, tokens: GoogleTokens, save: @escaping @Sendable (GoogleTokens) -> Void) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.tokens = tokens
        self.save = save
    }

    public var email: String? { tokens.email }

    public func accessToken() async throws -> String {
        let current = lock.withLock { tokens }
        if current.expiry.timeIntervalSinceNow > 120 { return current.accessToken }
        let refreshed = try await GoogleOAuth.refresh(current, clientId: clientId, clientSecret: clientSecret)
        lock.withLock { tokens = refreshed }
        save(refreshed)
        return refreshed.accessToken
    }
}

/// Google's installed-app OAuth flow: the browser signs in and redirects to a one-off
/// listener on 127.0.0.1, with PKCE.
public enum GoogleOAuth {
    public static let scopes = [
        "https://www.googleapis.com/auth/photoslibrary.appendonly",
        "https://www.googleapis.com/auth/photoslibrary.readonly.appcreateddata",
        "https://www.googleapis.com/auth/photoslibrary.edit.appcreateddata",
        "openid",
        "email",
    ]

    public static func authorize(clientId: String, clientSecret: String,
                                 open: @escaping @Sendable (URL) -> Void) async throws -> GoogleTokens {
        let verifier = randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = randomString(24)
        let receiver = try LoopbackReceiver()
        let port = try await receiver.start()
        let redirect = "http://127.0.0.1:\(port)"

        let authURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!.adding([
            "client_id": clientId,
            "redirect_uri": redirect,
            "response_type": "code",
            "scope": scopes.joined(separator: " "),
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "access_type": "offline",
            "prompt": "consent",
            "state": state,
        ])
        open(authURL)
        let query = try await receiver.waitForRedirect()
        guard query["state"] == state else { throw SyncError.unexpected("Google's answer didn't match the sign-in request.") }
        if let error = query["error"] { throw SyncError.unexpected("Google sign-in failed: \(error)") }
        guard let code = query["code"] else { throw SyncError.unexpected("Google didn't return a sign-in code.") }

        let response = try await tokenRequest([
            ("code", code), ("client_id", clientId), ("client_secret", clientSecret),
            ("redirect_uri", redirect), ("grant_type", "authorization_code"), ("code_verifier", verifier),
        ])
        guard let access = response["access_token"] as? String, let refresh = response["refresh_token"] as? String else {
            throw SyncError.unexpected("Google didn't return tokens.")
        }
        let expiresIn = response["expires_in"] as? Double ?? 3600
        return GoogleTokens(accessToken: access, refreshToken: refresh, expiry: Date().addingTimeInterval(expiresIn),
                            email: (response["id_token"] as? String).flatMap(emailFromIDToken))
    }

    static func refresh(_ tokens: GoogleTokens, clientId: String, clientSecret: String) async throws -> GoogleTokens {
        let response: [String: Any]
        do {
            response = try await tokenRequest([
                ("refresh_token", tokens.refreshToken), ("client_id", clientId),
                ("client_secret", clientSecret), ("grant_type", "refresh_token"),
            ])
        } catch SyncError.http(let status, _) where status == 400 || status == 401 {
            throw SyncError.notSignedIn("Google Photos")
        }
        guard let access = response["access_token"] as? String else { throw SyncError.notSignedIn("Google Photos") }
        var updated = tokens
        updated.accessToken = access
        updated.expiry = Date().addingTimeInterval(response["expires_in"] as? Double ?? 3600)
        if let refresh = response["refresh_token"] as? String { updated.refreshToken = refresh }
        return updated
    }

    private static func tokenRequest(_ form: [(String, String)]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.httpBody = formEncoded(form)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        return try await HTTPClient().json(request)
    }

    static func emailFromIDToken(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return claims["email"] as? String
    }

    static func randomString(_ length: Int) -> String {
        let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<length).map { _ in characters.randomElement()! })
    }
}

/// Listens on 127.0.0.1 for the one redirect that ends a browser sign-in.
final class LoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "photo-syncer.oauth")
    private var redirectContinuation: CheckedContinuation<[String: String], Error>?
    /// A redirect that arrived before anyone was waiting for it.
    private var early: [String: String]?
    private var finished = false

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            // State changes arrive on `queue`, one at a time.
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            listener.stateUpdateHandler = { [weak self] state in
                guard !once.done else { return }
                switch state {
                case .ready:
                    once.done = true
                    continuation.resume(returning: self?.listener.port?.rawValue ?? 0)
                case .failed(let error):
                    once.done = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
        }
    }

    /// Waits up to five minutes for the browser to come back.
    func waitForRedirect() async throws -> [String: String] {
        try await withThrowingTaskGroup(of: [String: String].self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.queue.async {
                        if let early = self.early {
                            continuation.resume(returning: early)
                        } else {
                            self.redirectContinuation = continuation
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 300 * 1_000_000_000)
                throw SyncError.unexpected("Google sign-in timed out.")
            }
            defer {
                group.cancelAll()
                listener.cancel()
            }
            return try await group.next()!
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self else { return }
            let text = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let firstLine = text.components(separatedBy: "\r\n").first ?? ""
            let target = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let query = URLComponents(string: "http://127.0.0.1" + target)?.queryItems ?? []
            var values: [String: String] = [:]
            for item in query { values[item.name] = item.value ?? "" }

            let isRedirect = values["code"] != nil || values["error"] != nil
            let page = isRedirect
                ? "<html><body style='font-family:-apple-system;padding:40px'><h2>Signed in to Google Photos</h2><p>You can close this tab and go back to Photo Syncer.</p></body></html>"
                : "<html><body></body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if isRedirect && !self.finished {
                self.finished = true
                if let continuation = self.redirectContinuation {
                    self.redirectContinuation = nil
                    continuation.resume(returning: values)
                } else {
                    self.early = values
                }
            }
        }
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
