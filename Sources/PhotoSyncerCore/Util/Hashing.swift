import CryptoKit
import Foundation

public enum Hashing {
    public static func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// MD5 of a file, read in chunks so big files don't sit in memory.
    public static func md5(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.MD5()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Remembers the MD5s of source files by path, size and modification date, so a folder of
/// thousands of photos is only hashed once.
public final class MD5Cache: @unchecked Sendable {
    private struct Entry: Codable {
        var size: Int64
        var modified: TimeInterval
        var md5: String
    }

    private let url: URL
    private var entries: [String: Entry]
    private var dirty = false
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    public func md5(of file: URL) throws -> String {
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = Int64(values.fileSize ?? -1)
        let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        lock.lock()
        if let hit = entries[file.path], hit.size == size, hit.modified == modified {
            lock.unlock()
            return hit.md5
        }
        lock.unlock()
        let md5 = try Hashing.md5(of: file)
        lock.lock()
        entries[file.path] = Entry(size: size, modified: modified, md5: md5)
        dirty = true
        lock.unlock()
        return md5
    }

    public func save() {
        lock.lock()
        defer { lock.unlock() }
        guard dirty, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
        dirty = false
    }
}
