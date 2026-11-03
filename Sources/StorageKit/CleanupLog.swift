import Darwin
import Foundation

/// One cleanup MyMole ran: where from, what went to the Trash, what was
/// deleted for good, and what was put back since.
public struct CleanupRecord: Sendable, Codable, Identifiable, Equatable {
    public let id: UUID
    public let date: Date
    /// The pane it came from ("Deep Clean", "Installers", …).
    public let source: String
    /// Items moved to the Trash (or, for Optimize, tasks done).
    public let items: Int
    /// Bytes moved to the Trash or deleted.
    public let bytes: Int64
    public let failed: Int
    /// Items deleted for good, which no Undo brings back.
    public let deleted: Int
    public var restored: Int
    public var restoredBytes: Int64
    /// Items an Undo tried and couldn't put back.
    public var restoreFailed: Int

    public init(
        id: UUID = UUID(), date: Date = Date(), source: String, items: Int, bytes: Int64, failed: Int, deleted: Int = 0,
        restored: Int = 0, restoredBytes: Int64 = 0, restoreFailed: Int = 0
    ) {
        self.id = id
        self.date = date
        self.source = source
        self.items = items
        self.bytes = bytes
        self.failed = failed
        self.deleted = deleted
        self.restored = restored
        self.restoredBytes = restoredBytes
        self.restoreFailed = restoreFailed
    }

    /// Everything moved came back and nothing was deleted for good.
    public var undone: Bool { restored > 0 && restored >= items && restoreFailed == 0 && deleted == 0 }
    /// Some came back, not all.
    public var partlyUndone: Bool { restored > 0 && !undone }
    public var freedBytes: Int64 { max(0, bytes - restoredBytes) }
    /// Still freed something: not everything was put back, or some was deleted.
    public var freedSomething: Bool { (items > restored || deleted > 0) && (items + deleted) > 0 }

    enum CodingKeys: String, CodingKey {
        case id, date, source, items, bytes, failed, deleted, restored, restoredBytes, restoreFailed, undone
    }

    /// Records written before the counts were kept say only "undone".
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        source = try c.decode(String.self, forKey: .source)
        items = try c.decode(Int.self, forKey: .items)
        bytes = try c.decode(Int64.self, forKey: .bytes)
        failed = try c.decode(Int.self, forKey: .failed)
        deleted = try c.decodeIfPresent(Int.self, forKey: .deleted) ?? 0
        restoreFailed = try c.decodeIfPresent(Int.self, forKey: .restoreFailed) ?? 0
        if let r = try c.decodeIfPresent(Int.self, forKey: .restored) {
            restored = r
            restoredBytes = try c.decodeIfPresent(Int64.self, forKey: .restoredBytes) ?? 0
        } else {
            let wasUndone = try c.decodeIfPresent(Bool.self, forKey: .undone) ?? false
            restored = wasUndone ? items : 0
            restoredBytes = wasUndone ? bytes : 0
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(date, forKey: .date)
        try c.encode(source, forKey: .source)
        try c.encode(items, forKey: .items)
        try c.encode(bytes, forKey: .bytes)
        try c.encode(failed, forKey: .failed)
        try c.encode(deleted, forKey: .deleted)
        try c.encode(restored, forKey: .restored)
        try c.encode(restoredBytes, forKey: .restoredBytes)
        try c.encode(restoreFailed, forKey: .restoreFailed)
    }
}

/// MyMole's own cleanup history, newest first. Only counts and sizes are
/// kept, never paths, so the log holds nothing personal.
///
/// Writes go through one serial queue, in the order they're submitted, so
/// an Undo is never recorded before the run it undoes; and each write holds
/// a file lock, so a second copy of the app can't interleave with it.
public enum CleanupLog {
    public static let keep = 500
    private static let queue = DispatchQueue(label: "mymole.cleanup-log", qos: .utility)

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MyMole/history.json")
    }

    /// Reads after every write submitted so far has landed.
    public static func load(from url: URL = defaultURL) -> [CleanupRecord] {
        queue.sync { locked(url) { read(url) } }
    }

    /// Queues `record`; returns at once.
    public static func submit(_ record: CleanupRecord, to url: URL = defaultURL) {
        guard record.items > 0 || record.failed > 0 || record.deleted > 0 else { return }
        queue.async { locked(url) { write(Array(([record] + read(url)).prefix(keep)), to: url) } }
    }

    /// Queues what an Undo of run `id` put back and couldn't.
    public static func submitRestore(_ id: UUID, restored: Int, bytes: Int64, failed: Int, in url: URL = defaultURL) {
        queue.async {
            locked(url) {
                var all = read(url)
                guard let i = all.firstIndex(where: { $0.id == id }) else { return }
                all[i].restored += restored
                all[i].restoredBytes += bytes
                all[i].restoreFailed = failed
                write(all, to: url)
            }
        }
    }

    /// Blocks until every submitted write has landed.
    public static func flush() { queue.sync {} }

    /// Runs `body` holding an exclusive lock on a file beside the log.
    private static func locked<T>(_ url: URL, _ body: () -> T) -> T {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer {
            if fd >= 0 {
                flock(fd, LOCK_UN)
                close(fd)
            }
        }
        return body()
    }

    private static func read(_ url: URL) -> [CleanupRecord] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([CleanupRecord].self, from: d)) ?? []
    }

    private static func write(_ records: [CleanupRecord], to url: URL) {
        if let d = try? JSONEncoder().encode(records) { try? d.write(to: url, options: .atomic) }
    }
}
