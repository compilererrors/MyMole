import Foundation
import Synchronization

/// Picture fingerprints worked out before, so a search again reads only
/// pictures that are new or changed. An entry counts only for the same
/// file as it was: volume, file number, length and last change to the
/// nanosecond, and the same way of working out the fingerprint. At most
/// `limit` entries are kept, the most recently used. A move to the Trash
/// still checks the file itself, whatever the cache says.
public struct FingerprintCache: Sendable {
    /// Raise when the fingerprint is worked out differently.
    public static let algorithm = 1
    public static let limit = 50_000

    struct Key: Hashable, Codable, Sendable {
        let device: Int32
        let inode: UInt64
        let length: Int64
        let modified: Double
    }

    struct Entry: Codable, Sendable {
        let print: UInt64
        let width: Int
        let height: Int
        var used: Double
    }

    private struct File: Codable {
        let algorithm: Int
        let entries: [Key: Entry]
    }

    private(set) var entries: [Key: Entry] = [:]

    public init() {}

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MyMole/Fingerprints/pictures.json")
    }

    /// The saved cache, or an empty one when there's none, it's damaged,
    /// or it was made another way.
    public static func load(from url: URL) -> FingerprintCache {
        guard let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: d), f.algorithm == algorithm else {
            return FingerprintCache()
        }
        var c = FingerprintCache()
        c.entries = f.entries
        return c
    }

    public func save(to url: URL) {
        var kept = entries
        if kept.count > Self.limit {
            let newest = kept.sorted { $0.value.used > $1.value.used }.prefix(Self.limit)
            kept = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(File(algorithm: Self.algorithm, entries: kept)) { try? d.write(to: url, options: .atomic) }
    }

    static func key(device: Int32, inode: UInt64, length: Int64, modified: Date) -> Key {
        Key(device: device, inode: inode, length: length, modified: modified.timeIntervalSince1970)
    }

    mutating func look(_ key: Key, now: Date = .now) -> (UInt64, Int, Int)? {
        guard var e = entries[key] else { return nil }
        e.used = now.timeIntervalSince1970
        entries[key] = e
        return (e.print, e.width, e.height)
    }

    mutating func store(_ key: Key, print: UInt64, width: Int, height: Int, now: Date = .now) {
        entries[key] = Entry(print: print, width: width, height: height, used: now.timeIntervalSince1970)
    }

    public var count: Int { entries.count }
}

/// A cache several readers share during one search.
public final class SharedFingerprints: Sendable {
    let cache: Mutex<FingerprintCache>
    public init(_ cache: FingerprintCache) { self.cache = Mutex(cache) }
    public var current: FingerprintCache { cache.withLock { $0 } }
}
