import Foundation

public enum SyncError: Error, LocalizedError, Sendable {
    case notSignedIn(String)
    case http(Int, String)
    case unexpected(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notSignedIn(let service): return "Not signed in to \(service). Sign in again from Accounts."
        case .http(let status, let body): return "The server answered \(status): \(body.prefix(300))"
        case .unexpected(let message): return message
        case .cancelled: return "Cancelled."
        }
    }
}

/// A URLSession with its own cookie jar, seeded from a web sign-in, plus retries.
public final class HTTPClient: @unchecked Sendable {
    public static let safariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    public let session: URLSession
    public let cookies: HTTPCookieStorage

    public init(cookies seed: [HTTPCookie] = [], timeout: TimeInterval = 120) {
        let configuration = URLSessionConfiguration.ephemeral
        // An ephemeral configuration comes with its own in-memory cookie jar.
        let storage = configuration.httpCookieStorage ?? HTTPCookieStorage.shared
        storage.cookieAcceptPolicy = .always
        for cookie in seed { storage.setCookie(cookie) }
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = 60 * 30
        configuration.httpAdditionalHeaders = ["User-Agent": HTTPClient.safariUserAgent]
        session = URLSession(configuration: configuration)
        cookies = storage
    }

    public func cookie(named name: String, domain: String) -> String? {
        cookies.cookies?.first { $0.name == name && $0.domain.hasSuffix(domain) }?.value
    }

    public var allCookies: [HTTPCookie] { cookies.cookies ?? [] }

    /// Sends a request, retrying rate limits, server errors and dropped connections.
    @discardableResult
    public func send(_ request: URLRequest, accept: Set<Int> = Set(200..<300), attempts: Int = 4) async throws -> (Data, HTTPURLResponse) {
        var delay: UInt64 = 2_000_000_000
        var lastError: Error = SyncError.unexpected("No response")
        for attempt in 1...attempts {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw SyncError.unexpected("Not an HTTP response") }
                if accept.contains(http.statusCode) { return (data, http) }
                let body = String(data: data.prefix(600), encoding: .utf8) ?? ""
                lastError = SyncError.http(http.statusCode, body)
                let retryable = http.statusCode == 429 || http.statusCode >= 500
                if !retryable || attempt == attempts { throw lastError }
            } catch let error as URLError where error.code != .cancelled && attempt < attempts {
                lastError = error
            } catch is CancellationError {
                throw SyncError.cancelled
            }
            try await Task.sleep(nanoseconds: delay)
            delay *= 2
        }
        throw lastError
    }

    public func json(_ request: URLRequest, accept: Set<Int> = Set(200..<300)) async throws -> [String: Any] {
        let (data, _) = try await send(request, accept: accept)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SyncError.unexpected("Expected a JSON object from \(request.url?.host ?? "server")")
        }
        return object
    }
}

extension URL {
    func adding(_ query: [String: String]) -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // URLComponents leaves "+" alone, which servers read as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }
}

/// A multipart/form-data body.
struct Multipart {
    let boundary = "PhotoSyncer-\(UUID().uuidString)"
    private(set) var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(_ name: String, _ value: String) {
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
    }

    mutating func addFile(_ name: String, fileName: String, mimeType: String, data: Data) {
        let safeName = fileName.replacingOccurrences(of: "\"", with: "'")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(safeName)\"\r\nContent-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
    }

    mutating func finish() -> Data {
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }
}

func formEncoded(_ pairs: [(String, String)]) -> Data {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return pairs.map { key, value in
        "\(key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\(value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
    }.joined(separator: "&").data(using: .utf8)!
}
