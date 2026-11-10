import Foundation

/// Pix-Star, through the pages and endpoints of pix-star.com's web albums, with the cookies
/// of a sign-in in the app's web view. Pix-Star has no public API.
///
/// - Uploads go through the same "media job" endpoint as the site's uploader: post the photo,
///   then poll until Pix-Star has converted it.
/// - Pix-Star keeps a resized copy and renames it ("My Photo.jpg" -> "My_Photo_1234.jpg"),
///   so photos are matched by name (`NameMatching.pixStarKey`), never by bytes.
/// - A frame syncs at most 3,000 photos per album; the sync engine starts a new album
///   ("Family 2") when one is full.
public final class PixStarService: RemoteService, @unchecked Sendable {
    public let kind = ServiceKind.pixstar
    public let preferredBatchSize = 4

    let http: HTTPClient
    let base = URL(string: "https://www.pix-star.com")!

    public init(cookies: [HTTPCookie]) {
        http = HTTPClient(cookies: cookies)
    }

    /// The session's cookies now, including any the server refreshed, to save back.
    public var currentCookies: [HTTPCookie] { http.allCookies }

    private var csrfToken: String? { http.cookie(named: "csrftoken", domain: "pix-star.com") }

    private func page(_ path: String, query: [String: String] = [:], xhr: Bool = false) async throws -> (String, URL?) {
        var request = URLRequest(url: URL(string: path, relativeTo: base)!.absoluteURL.adding(query))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if xhr { request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With") }
        let (data, response) = try await http.send(request)
        if response.url?.path.contains("/accounts/login") == true || response.url?.path.contains("/login") == true {
            throw SyncError.notSignedIn("Pix-Star")
        }
        return (String(decoding: data, as: UTF8.self), response.url)
    }

    /// A POST the way the site's own scripts send it (Django checks the CSRF token and Referer).
    private func post(_ path: String, body: Data, contentType: String, referer: String) throws -> URLRequest {
        guard let csrfToken else { throw SyncError.notSignedIn("Pix-Star") }
        var request = URLRequest(url: URL(string: path, relativeTo: base)!.absoluteURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(csrfToken, forHTTPHeaderField: "X-CSRFToken")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("https://www.pix-star.com", forHTTPHeaderField: "Origin")
        request.setValue(URL(string: referer, relativeTo: base)!.absoluteString, forHTTPHeaderField: "Referer")
        return request
    }

    public func verify() async throws -> String? {
        let (html, _) = try await page("/my_pixstar/")
        guard let email = PixStarParsing.signedInEmail(html) else { throw SyncError.notSignedIn("Pix-Star") }
        return email
    }

    public func albums() async throws -> [RemoteAlbum] {
        let (html, _) = try await page("/albums/list/")
        if PixStarParsing.signedInEmail(html) == nil { throw SyncError.notSignedIn("Pix-Star") }
        return PixStarParsing.albums(html)
    }

    public func createAlbum(named name: String) async throws -> DestinationRef {
        let (_, finalURL) = try await page("/create/new_album/", query: ["album_name": name])
        guard let id = finalURL.flatMap({ PixStarParsing.albumId(inPath: $0.path) }) else {
            // Some accounts land back on the album list; find the album there.
            if let album = try await albums().last(where: { $0.ref.name == name }) { return album.ref }
            throw SyncError.unexpected("Pix-Star didn't create the album \(name).")
        }
        return DestinationRef(id: id, name: name)
    }

    public func items(in destination: DestinationRef) async throws -> [RemoteItem] {
        var items: [RemoteItem] = []
        var seen = Set<String>()
        for pageNumber in 1... {
            try Task.checkCancellation()
            let (html, _) = try await page("/album/web/\(destination.id)/", query: ["page": String(pageNumber), "size": "small"], xhr: true)
            if html.trimmingCharacters(in: .whitespacesAndNewlines) == "no-more" { break }
            let found = PixStarParsing.photos(html)
            let fresh = found.filter { seen.insert($0.id).inserted }
            if fresh.isEmpty { break }
            items += fresh
        }
        return items
    }

    public func upload(_ payloads: [UploadPayload], to destination: DestinationRef) async -> [Result<UploadResult, Error>] {
        let albumPath = "/album/web/\(destination.id)/"
        // Post every photo, then wait for Pix-Star to finish converting them.
        var jobs: [Int: Int] = [:]  // job id -> payload index
        var results = [Result<UploadResult, Error>?](repeating: nil, count: payloads.count)
        for (index, payload) in payloads.enumerated() {
            do {
                var form = Multipart()
                form.addFile("image", fileName: payload.fileName, mimeType: payload.mimeType, data: payload.data)
                let body = form.finish()
                let request = try post(albumPath + "create_upload_media_job", body: body, contentType: form.contentType, referer: albumPath)
                let response = try await http.json(request)
                guard let job = (response["jobIds"] as? [Any])?.first.flatMap({ $0 as? Int ?? Int("\($0)") }) else {
                    throw SyncError.unexpected("Pix-Star didn't accept \(payload.fileName).")
                }
                jobs[job] = index
            } catch SyncError.http(let status, _) where status == 403 {
                results[index] = .failure(SyncError.unexpected("Pix-Star refused the upload (403). If this album belongs to a multi-frame account, add that account and sync to it from there."))
            } catch {
                results[index] = .failure(error)
            }
        }

        var waiting = Set(jobs.keys)
        let deadline = Date().addingTimeInterval(180)
        while !waiting.isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            do {
                let body = formEncoded(waiting.sorted().map { ("ids[]", String($0)) })
                let request = try post("/ajax/media_job_status", body: body,
                                       contentType: "application/x-www-form-urlencoded; charset=UTF-8", referer: albumPath)
                let response = try await http.json(request)
                for job in response["jobs"] as? [[String: Any]] ?? [] {
                    guard let id = job["id"] as? Int ?? (job["id"] as? String).flatMap(Int.init), let index = jobs[id] else { continue }
                    switch job["status"] as? String {
                    case "done":
                        let url = job["url"] as? String ?? payloads[index].fileName
                        results[index] = .success(UploadResult(remoteId: String(id), remoteName: (url as NSString).lastPathComponent))
                        waiting.remove(id)
                    case "failed":
                        results[index] = .failure(SyncError.unexpected("Pix-Star couldn't convert \(payloads[index].fileName)."))
                        waiting.remove(id)
                    default:
                        break
                    }
                }
            } catch {
                if Task.isCancelled { break }
            }
        }
        for id in waiting {
            if let index = jobs[id] {
                // Uploaded but still converting: count it as done; it shows up on the next listing.
                results[index] = .success(UploadResult(remoteId: String(id), remoteName: payloads[index].fileName))
            }
        }
        return results.map { $0 ?? .failure(SyncError.unexpected("No result from Pix-Star.")) }
    }

    public func download(_ item: RemoteItem) async throws -> (Data, String) {
        guard let csrfToken else { throw SyncError.notSignedIn("Pix-Star") }
        let body = formEncoded([("file_number", item.id), ("csrfmiddlewaretoken", csrfToken)])
        let request = try post("/download/single/picture/", body: body, contentType: "application/x-www-form-urlencoded", referer: "/albums/list/")
        let (data, response) = try await http.send(request)
        let disposition = response.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        let name = PixStarParsing.fileName(fromContentDisposition: disposition) ?? item.name
        return (data, name)
    }
}

/// Reads the pix-star.com pages the app uses. Kept separate so it can be tested.
public enum PixStarParsing {
    /// The signed-in frame's address, shown in the page header ("someone@mypixstar.com").
    public static func signedInEmail(_ html: String) -> String? {
        guard html.contains("/accounts/logout/"),
              let range = html.range(of: "[A-Za-z0-9._%+-]+@mypixstar\\.com", options: .regularExpression) else { return nil }
        return String(html[range])
    }

    public static func albumId(inPath path: String) -> String? {
        guard let range = path.range(of: "/album/web/[0-9]+", options: .regularExpression) else { return nil }
        return String(path[range].split(separator: "/").last!)
    }

    /// The albums on /albums/list/.
    public static func albums(_ html: String) -> [RemoteAlbum] {
        var albums: [RemoteAlbum] = []
        var seen = Set<String>()
        for chunk in html.components(separatedBy: "<li class=\"album-image\">").dropFirst() {
            guard let id = albumId(inPath: chunk), seen.insert(id).inserted else { continue }
            let count = firstMatch("total_photos=\"([0-9]+)\"", in: chunk).flatMap(Int.init)
            var name = "Album \(id)"
            if let start = chunk.range(of: "id=\"album_id_\(id)\"") {
                let rest = chunk[start.upperBound...]
                if let open = rest.range(of: ">"), let close = rest.range(of: "</div>") {
                    let inner = String(rest[open.upperBound..<close.lowerBound])
                    let text = stripTags(inner).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { name = decodeEntities(text) }
                }
            }
            let managed = chunk.contains("multiframe-image-icon-album")
            albums.append(RemoteAlbum(ref: DestinationRef(id: id, name: name), count: count,
                                      note: managed ? "Managed by the multi-frame account: upload to it from that account" : nil))
        }
        return albums
    }

    /// The photos in one page of an album listing.
    public static func photos(_ html: String) -> [RemoteItem] {
        html.components(separatedBy: "<li class=\"album-image\"").dropFirst().compactMap { chunk in
            guard let id = firstMatch("value=\"([0-9]+)\"\\s+name=\"images_list\"", in: chunk)
                    ?? firstMatch("class=\"fancybox\"\\s+id=\"([0-9]+)\"", in: chunk) else { return nil }
            let title = firstMatch("class=\"photo_title\"[^>]*?title=\"([^\"]*)\"", in: chunk)
                ?? firstMatch("data-original-title=\"([^\"]+\\.[A-Za-z]{3,4})\"", in: chunk)
                ?? firstMatch("src=\"[^\"]*/([^/\"]+)\"", in: chunk)
                ?? id
            let name = decodeEntities(title)
            return RemoteItem(id: id, name: name, nameKey: NameMatching.pixStarKey(name))
        }
    }

    public static func fileName(fromContentDisposition header: String) -> String? {
        firstMatch("filename=\"([^\"]+)\"", in: header)
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}
