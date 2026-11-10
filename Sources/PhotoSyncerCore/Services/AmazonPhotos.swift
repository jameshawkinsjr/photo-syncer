import Foundation

/// Amazon Photos, through the same web API amazon.com/photos uses, with the cookies of a
/// sign-in in the app's web view. Amazon has no public Photos API.
///
/// - Albums made from a folder (the "smart" albums the web app makes when you upload a
///   folder) are filled by uploading into that folder.
/// - Other albums get their photos uploaded into a "Photo Syncer/<album>" folder and then
///   added to the album.
/// - Amazon refuses a second copy of the same bytes (409, naming the existing photo), so a
///   photo already in the account is linked into the folder instead of uploaded again.
public final class AmazonPhotosService: RemoteService, @unchecked Sendable {
    public let kind = ServiceKind.amazon
    public let preferredBatchSize = 1

    let http: HTTPClient
    let base = URL(string: "https://www.amazon.com/drive/v1/")!
    let uploadURL = URL(string: "https://upload-photos.amazon.com/v2/upload")!
    private var applicationId: String?
    private var rootId: String?

    public init(cookies: [HTTPCookie]) {
        http = HTTPClient(cookies: cookies)
    }

    /// The session's cookies now, including any the server refreshed, to save back.
    public var currentCookies: [HTTPCookie] { http.allCookies }

    private var sessionId: String? { http.cookie(named: "session-id", domain: "amazon.com") }

    private func request(_ path: String, query: [String: String] = [:], method: String = "GET", json: Any? = nil) throws -> URLRequest {
        guard let sessionId else { throw SyncError.notSignedIn("Amazon Photos") }
        var q = query
        q["resourceVersion"] = "V2"
        q["ContentType"] = "JSON"
        var request = URLRequest(url: URL(string: path, relativeTo: base)!.absoluteURL.adding(q))
        request.httpMethod = method
        request.setValue(sessionId, forHTTPHeaderField: "x-amzn-sessionid")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://www.amazon.com/photos/all", forHTTPHeaderField: "Referer")
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func call(_ path: String, query: [String: String] = [:], method: String = "GET", json: Any? = nil) async throws -> [String: Any] {
        do {
            return try await http.json(try request(path, query: query, method: method, json: json))
        } catch SyncError.http(let status, _) where status == 401 || status == 403 {
            throw SyncError.notSignedIn("Amazon Photos")
        }
    }

    /// All pages of a node listing.
    private func list(_ path: String, query: [String: String]) async throws -> [[String: Any]] {
        var all: [[String: Any]] = []
        var token: String?
        repeat {
            var q = query
            q["limit"] = "200"
            if let token { q["startToken"] = token }
            let page = try await call(path, query: q)
            all += page["data"] as? [[String: Any]] ?? []
            token = page["nextToken"] as? String
        } while token != nil && !(token?.isEmpty ?? true)
        return all
    }

    public func verify() async throws -> String? {
        _ = try await root()
        return nil
    }

    func root() async throws -> String {
        if let rootId { return rootId }
        let result = try await call("nodes", query: ["filters": "isRoot:true"])
        guard let id = (result["data"] as? [[String: Any]])?.first?["id"] as? String else {
            throw SyncError.unexpected("Amazon didn't return the root folder.")
        }
        rootId = id
        return id
    }

    /// The web app's application id, read from the Photos page (uploads need it).
    func appId() async throws -> String {
        if let applicationId { return applicationId }
        let (data, _) = try await http.send(URLRequest(url: URL(string: "https://www.amazon.com/photos/all")!))
        let html = String(decoding: data, as: UTF8.self)
        guard let id = AmazonParsing.applicationId(inPage: html) else {
            throw SyncError.notSignedIn("Amazon Photos")
        }
        applicationId = id
        return id
    }

    public func albums() async throws -> [RemoteAlbum] {
        let nodes = try await list("nodes", query: [
            "asset": "ALL",
            "filters": "kind:VISUAL_COLLECTION AND status:(AVAILABLE*)",
            "sort": "['name ASC']",
        ])
        var albums: [RemoteAlbum] = []
        for node in nodes {
            guard var album = AmazonParsing.album(from: node) else { continue }
            // Folder-based albums are often all named after the parent ("Pictures");
            // show the folder's name so they can be told apart.
            if let folderId = album.ref.uploadFolderId,
               let folder = try? await call("nodes/\(folderId)"),
               let folderName = folder["name"] as? String {
                album.ref.name = folderName
                album.note = "Album of the folder \"\(folderName)\""
            }
            albums.append(album)
        }
        return albums.sorted { $0.ref.name.localizedStandardCompare($1.ref.name) == .orderedAscending }
    }

    /// Creates a folder at the top level ("Photo Syncer/<name>") and an album for it.
    public func createAlbum(named name: String) async throws -> DestinationRef {
        let folder = try await folder(named: name, in: try await container())
        let album = try await call("nodes", method: "POST", json: ["kind": "VISUAL_COLLECTION", "name": name])
        guard let albumId = album["id"] as? String else { throw SyncError.unexpected("Amazon didn't create the album.") }
        return DestinationRef(id: albumId, name: name, uploadFolderId: folder, addsToAlbum: true)
    }

    private func container() async throws -> String {
        try await folder(named: "Photo Syncer", in: try await root())
    }

    private func folder(named name: String, in parent: String) async throws -> String {
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: " ", with: "\\ ")
            .replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)")
        let existing = try await call("nodes/\(parent)/children", query: ["filters": "kind:FOLDER AND name:\(escaped)"])
        if let match = (existing["data"] as? [[String: Any]])?.first(where: { ($0["name"] as? String) == name }),
           let id = match["id"] as? String {
            return id
        }
        let created = try await call("nodes", method: "POST", json: ["kind": "FOLDER", "name": name, "parents": [parent]])
        guard let id = created["id"] as? String else { throw SyncError.unexpected("Amazon didn't create the folder \(name).") }
        return id
    }

    /// Where uploads for an album go: its own folder, or a Photo Syncer folder for a plain album.
    private func uploadFolder(for destination: DestinationRef) async throws -> String {
        if let folder = destination.uploadFolderId { return folder }
        return try await folder(named: destination.name, in: try await container())
    }

    public func items(in destination: DestinationRef) async throws -> [RemoteItem] {
        var nodes: [[String: Any]] = []
        if let folder = destination.uploadFolderId, !destination.addsToAlbum {
            nodes = try await list("nodes/\(folder)/children", query: ["filters": "kind:FILE"])
        } else {
            nodes = try await list("nodes/\(destination.id)/children", query: [:])
        }
        return nodes.compactMap(AmazonParsing.item(from:))
    }

    public func upload(_ payloads: [UploadPayload], to destination: DestinationRef) async -> [Result<UploadResult, Error>] {
        var results: [Result<UploadResult, Error>] = []
        for payload in payloads {
            do {
                results.append(.success(try await upload(payload, to: destination)))
            } catch {
                results.append(.failure(error))
            }
        }
        return results
    }

    private func upload(_ payload: UploadPayload, to destination: DestinationRef) async throws -> UploadResult {
        let folder = try await uploadFolder(for: destination)
        let appId = try await appId()
        var upload = URLRequest(url: uploadURL.adding([
            "conflictResolution": "RENAME",
            "fileSize": String(payload.data.count),
            "name": payload.fileName,
            "parentNodeId": folder,
        ]))
        upload.httpMethod = "POST"
        upload.httpBody = payload.data
        upload.setValue(payload.md5, forHTTPHeaderField: "x-amzn-file-md5")
        upload.setValue(appId, forHTTPHeaderField: "x-amz-clouddrive-appid")
        upload.setValue("https://www.amazon.com", forHTTPHeaderField: "Origin")
        upload.setValue("https://www.amazon.com/", forHTTPHeaderField: "Referer")
        upload.setValue(payload.mimeType, forHTTPHeaderField: "Content-Type")

        let (data, response) = try await http.send(upload, accept: [200, 201, 409])
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        var nodeId: String
        var deduplicated = false
        if response.statusCode == 409 {
            // Already in the account: link the existing photo into this folder.
            guard let existing = AmazonParsing.duplicateNodeId(fromConflict: body) else {
                throw SyncError.http(409, String(decoding: data, as: UTF8.self))
            }
            nodeId = existing
            deduplicated = true
            try await http.send(try request("nodes/\(folder)/children/\(existing)", method: "PUT"))
        } else {
            guard let id = body["id"] as? String else { throw SyncError.unexpected("Amazon didn't return the new photo's id.") }
            nodeId = id
        }

        // A plain (not folder-based) album also needs the photo added to it.
        if destination.addsToAlbum {
            _ = try await call("nodes/\(destination.id)/children", method: "PATCH", json: ["op": "add", "value": [nodeId]])
        }
        return UploadResult(remoteId: nodeId, remoteName: (body["name"] as? String) ?? payload.fileName, deduplicated: deduplicated)
    }
}

/// The parts of Amazon's JSON the app reads, kept separate so they can be tested.
public enum AmazonParsing {
    public static func applicationId(inPage html: String) -> String? {
        guard let range = html.range(of: "\"applicationId\":\"([^\"]+)\"", options: .regularExpression) else { return nil }
        let match = String(html[range])
        return match.components(separatedBy: "\"").dropLast().last
    }

    public static func album(from node: [String: Any]) -> RemoteAlbum? {
        guard let id = node["id"] as? String else { return nil }
        let name = node["name"] as? String ?? "Untitled"
        var folderId: String?
        if let properties = node["collectionProperties"] as? [String: Any],
           let query = properties["query"] as? [String: Any],
           let include = query["include"] as? [[String: Any]] {
            let folders = include.flatMap { $0["folderIds"] as? [String] ?? [] }
            if folders.count == 1 { folderId = folders[0] }
        }
        let count = (node["childAssetTypeInfo"] as? [[String: Any]])?.compactMap { $0["count"] as? Int }.reduce(0, +)
        return RemoteAlbum(ref: DestinationRef(id: id, name: name, uploadFolderId: folderId, addsToAlbum: folderId == nil),
                           count: count == 0 ? nil : count)
    }

    public static func item(from node: [String: Any]) -> RemoteItem? {
        guard let id = node["id"] as? String, (node["kind"] as? String ?? "FILE") == "FILE" else { return nil }
        let name = node["name"] as? String ?? ""
        let md5 = (node["contentProperties"] as? [String: Any])?["md5"] as? String
        return RemoteItem(id: id, name: name, md5: md5)
    }

    /// "Duplicate files already exist with FILE_MD5='…' in following node(s): '[AbCdEfGhIjKlMnOpQrStUv]' …"
    public static func duplicateNodeId(fromConflict body: [String: Any]) -> String? {
        if let info = body["info"] as? [String: Any], let id = info["nodeId"] as? String { return id }
        guard let message = body["message"] as? String,
              let range = message.range(of: "\\[[A-Za-z0-9_-]+", options: .regularExpression) else { return nil }
        return String(message[range].dropFirst())
    }
}
