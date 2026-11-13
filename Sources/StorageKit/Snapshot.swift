import CryptoKit
import Foundation

/// Sizes from one scan, kept so any two scans of the same place can be
/// compared later. Folders are stored a few levels deep once they matter
/// (≥ 10 MB); big files (≥ 50 MB) are stored at any depth, so a new 4 GB
/// video shows up as that video, not just as "Movies grew". A whole home
/// folder snapshot stays at a few hundred kilobytes.
public struct Snapshot: Codable, Sendable {
    public let rootPath: String
    public let date: Date
    /// Folder path relative to the root → bytes ("" is the root itself).
    public let sizes: [String: Int64]
    /// Big file path relative to the root → bytes.
    public let files: [String: Int64]
    /// How deep folders were recorded, and whether big files were. Two
    /// snapshots are only compared within what both of them measured.
    public let folderDepth: Int
    public let tracksFiles: Bool
    /// Part of the place couldn't be read, so its sizes are a lower bound.
    public let incomplete: Bool
    /// Folders the user had MyMole skip, relative to the root: not
    /// measured, so never compared.
    public var excluded: [String] = []

    public static let depth = 6
    public static let minimumSize: Int64 = 10 * 1_048_576
    public static let minimumFileSize: Int64 = 50 * 1_048_576

    public init(
        rootPath: String, date: Date, sizes: [String: Int64], files: [String: Int64] = [:],
        folderDepth: Int = Snapshot.depth, tracksFiles: Bool = true, incomplete: Bool = false
    ) {
        self.rootPath = rootPath
        self.date = date
        self.sizes = sizes
        self.files = files
        self.folderDepth = folderDepth
        self.tracksFiles = tracksFiles
        self.incomplete = incomplete
    }

    public init(of root: Folder, date: Date = .now, incomplete: Bool = false, excluded: [String] = [], stop: () -> Bool = { false }) {
        var sizes: [String: Int64] = ["": root.size]
        var files: [String: Int64] = [:]
        var cancelled = false
        func addFiles(_ f: Folder, _ rel: String) {
            for item in f.listedFiles where item.size >= Self.minimumFileSize {
                if stop() { cancelled = true; return }
                files[rel.isEmpty ? item.name : rel + "/" + item.name] = item.size
            }
        }
        addFiles(root, "")
        var stack: [(Folder, String, Int)] = root.subfolders.map { ($0, $0.name, 1) }
        while let (f, rel, depth) = stack.popLast() {
            if stop() { cancelled = true; break }
            // Big files can sit anywhere, so walk every folder that could
            // hold one; folder sizes are kept only near the top.
            guard f.size >= Self.minimumFileSize || (depth <= Self.depth && f.size >= Self.minimumSize) else { continue }
            if depth <= Self.depth && f.size >= Self.minimumSize { sizes[rel] = f.size }
            addFiles(f, rel)
            stack.append(contentsOf: f.subfolders.map { ($0, rel + "/" + $0.name, depth + 1) })
        }
        self.init(
            rootPath: root.path, date: date, sizes: sizes, files: files, folderDepth: Self.depth, tracksFiles: true,
            incomplete: incomplete || cancelled || stop())
        self.excluded = excluded.sorted()
    }

    // The first snapshot format had folders 4 levels deep and no files.
    enum CodingKeys: String, CodingKey { case rootPath, date, sizes, files, folderDepth, tracksFiles, incomplete, excluded }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rootPath = try c.decode(String.self, forKey: .rootPath)
        date = try c.decode(Date.self, forKey: .date)
        sizes = try c.decode([String: Int64].self, forKey: .sizes)
        files = try c.decodeIfPresent([String: Int64].self, forKey: .files) ?? [:]
        folderDepth = try c.decodeIfPresent(Int.self, forKey: .folderDepth) ?? 4
        tracksFiles = try c.decodeIfPresent(Bool.self, forKey: .tracksFiles) ?? false
        incomplete = try c.decodeIfPresent(Bool.self, forKey: .incomplete) ?? false
        excluded = try c.decodeIfPresent([String].self, forKey: .excluded) ?? []
    }

    public var totalSize: Int64 { sizes[""] ?? 0 }
}

public struct Change: Sendable, Identifiable, Hashable {
    public enum Kind: Sendable, CaseIterable { case grew, appeared, shrank, vanished }
    public let path: String  // relative to the scan root
    public let isFile: Bool
    public let before: Int64
    public let after: Int64
    public var id: String { (isFile ? "f:" : "d:") + path }
    public var delta: Int64 { after - before }
    public var kind: Kind {
        before == 0 ? .appeared : after == 0 ? .vanished : after > before ? .grew : .shrank
    }
}

extension Snapshot {
    /// Folders and big files whose size moved by at least `threshold`,
    /// biggest move first, judged only within what both snapshots measured
    /// (so a deeper or newer format never reports unmeasured paths as new).
    /// A folder whose change is almost entirely (≥ 90%) explained by
    /// something inside it — at any depth — is left out in favor of that,
    /// so "Library grew 8 GB" doesn't crowd out the file that did it.
    /// What a scan that couldn't read everything missed isn't a change:
    /// nothing shrinks to an incomplete newer scan, and nothing grows from
    /// an incomplete older one.
    public func changes(to newer: Snapshot, threshold: Int64 = 50 * 1_048_576) -> [Change] {
        let depth = min(folderDepth, newer.folderDepth)
        var all: [Change] = []
        // What either scan skipped wasn't measured by it: neither gone nor
        // new. A folder holding a place only one of them skipped changed by
        // that alone, so it isn't compared either.
        let skipped = Set(excluded).union(newer.excluded)
        let newlySkipped = Set(excluded).symmetricDifference(newer.excluded)
        func isSkipped(_ p: String) -> Bool {
            skipped.contains { p == $0 || p.hasPrefix($0 + "/") } || newlySkipped.contains { $0.hasPrefix(p + "/") }
        }
        func counts(_ c: Change) -> Bool {
            guard abs(c.delta) >= threshold else { return false }
            if !skipped.isEmpty, isSkipped(c.path) { return false }
            if newer.incomplete && c.delta < 0 { return false }
            if incomplete && c.delta > 0 { return false }
            return true
        }
        for p in Set(sizes.keys).union(newer.sizes.keys).subtracting([""])
        where p.split(separator: "/").count <= depth {
            let c = Change(path: p, isFile: false, before: sizes[p] ?? 0, after: newer.sizes[p] ?? 0)
            if counts(c) { all.append(c) }
        }
        if tracksFiles && newer.tracksFiles {
            for p in Set(files.keys).union(newer.files.keys) {
                let c = Change(path: p, isFile: true, before: files[p] ?? 0, after: newer.files[p] ?? 0)
                if counts(c) { all.append(c) }
            }
        }
        let folders = Dictionary(all.filter { !$0.isFile }.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var explained = Set<String>()
        for c in all {
            var parent = (c.path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                if let pc = folders[parent], pc.delta.signum() == c.delta.signum(),
                    abs(c.delta) * 10 >= abs(pc.delta) * 9
                {
                    explained.insert(parent)
                }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        return all.filter { $0.isFile || !explained.contains($0.path) }.sorted { abs($0.delta) > abs($1.delta) }
    }
}

/// A saved scan, without loading it.
public struct SnapshotRef: Sendable, Hashable, Identifiable {
    public let date: Date
    public let url: URL
    public var id: URL { url }
}

/// Scan history per folder: one directory per scanned path, one file per
/// scan, newest `keep` kept.
public enum SnapshotStore {
    /// Set in Settings; 30 unless changed.
    public static var keep: Int { LoadingSettings.history() }

    public static var defaultBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MyMole/Snapshots")
    }

    /// A stable, filesystem-safe name derived from the path: readable, plus
    /// a hash so paths that differ only in punctuation (`a-b`, `a_b`) never
    /// share a history.
    static func key(_ rootPath: String) -> String {
        let normalized = (rootPath as NSString).standardizingPath
        let digest = SHA256.hash(data: Data(normalized.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return String(legacyKey(normalized).prefix(80)) + "-" + digest
    }

    /// The pre-hash key, which could collide; only read when migrating.
    static func legacyKey(_ rootPath: String) -> String {
        let safe = rootPath.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
        return String(String(safe).prefix(120))
    }

    static func folder(for rootPath: String, base: URL) -> URL { base.appending(path: key(rootPath)) }

    /// A fresh formatter per use: DateFormatter isn't Sendable, and history
    /// listings are a few dozen names at most.
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f
    }

    /// File names are `<stamp>_<id>.json`: milliseconds keep the order, the
    /// id keeps two scans in the same instant from overwriting each other.
    private static var stamp: DateFormatter { formatter("yyyyMMdd-HHmmss.SSS") }
    /// Names before the id was added: `<yyyyMMdd-HHmmss>.json`.
    private static var legacyStamp: DateFormatter { formatter("yyyyMMdd-HHmmss") }

    static func date(fromName name: String) -> Date? {
        guard name.hasSuffix(".json") else { return nil }
        let base = String(name.dropLast(5))
        if let sep = base.firstIndex(of: "_") { return stamp.date(from: String(base[..<sep])) }
        return legacyStamp.date(from: base)
    }

    /// Saved scans of `rootPath`, newest first.
    public static func history(for rootPath: String, base: URL = defaultBase) -> [SnapshotRef] {
        migrateLegacy(rootPath, base: base)
        let dir = folder(for: rootPath, base: base)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { name -> (String, SnapshotRef)? in
            guard let d = date(fromName: name) else { return nil }
            return (name, SnapshotRef(date: d, url: dir.appending(path: name)))
        }
        .sorted { $0.1.date != $1.1.date ? $0.1.date > $1.1.date : $0.0 > $1.0 }
        .map(\.1)
    }

    /// How often a scan nobody asked for may add to the history, below Hyperspeed.
    public static let unattendedInterval: TimeInterval = 6 * 3_600

    /// Whether the newest saved scan of `rootPath` is old enough for an
    /// unattended scan to be saved too; at Hyperspeed every scan is.
    public static func isDue(for rootPath: String, now: Date = Date(), base: URL = defaultBase,
                             interval: TimeInterval = ResultSize.current().historyInterval) -> Bool {
        guard interval > 0, let newest = history(for: rootPath, base: base).first else { return true }
        return now.timeIntervalSince(newest.date) >= interval
    }

    public static func load(_ ref: SnapshotRef) -> Snapshot? {
        guard let data = try? Data(contentsOf: ref.url) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(Snapshot.self, from: data)
    }

    @discardableResult
    /// Saves `s` under `key`: its path, or the path with its volume for a
    /// disk other than the startup disk (`Volumes.historyKey`).
    public static func save(_ s: Snapshot, key: String? = nil, base: URL = defaultBase) -> SnapshotRef? {
        let key = key ?? s.rootPath
        let dir = folder(for: key, base: base)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        let name = stamp.string(from: s.date) + "_" + UUID().uuidString.prefix(8).lowercased() + ".json"
        let url = dir.appending(path: name)
        guard (try? e.encode(s).write(to: url, options: .atomic)) != nil else { return nil }
        for old in history(for: key, base: base).dropFirst(keep) {
            try? FileManager.default.removeItem(at: old.url)
        }
        if let limit = ResultSize.current().savedScanLimit { keepWithin(limit, base: base) }
        return SnapshotRef(date: date(fromName: name) ?? s.date, url: url)
    }

    /// All saved scans together take at most this much, whatever the number
    /// of folders mapped, at every result size below Hyperspeed.
    public static let totalLimit: Int64 = 200 * 1_048_576

    /// Removes the oldest saved scans, of any folder, until all of them fit
    /// in `limit`; the newest scan of each folder always stays.
    static func keepWithin(_ limit: Int64, base: URL) {
        let fm = FileManager.default
        var all: [(url: URL, date: Date, bytes: Int64, newest: Bool)] = []
        for dir in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] {
            let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).compactMap { n in date(fromName: n).map { (n, $0) } }
            let newest = names.max { $0.1 < $1.1 }?.0
            for (name, d) in names {
                let u = dir.appending(path: name)
                let bytes = Int64((try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
                all.append((u, d, bytes, name == newest))
            }
        }
        var total = all.reduce(0) { $0 + $1.bytes }
        for f in all.filter({ !$0.newest }).sorted(by: { $0.date < $1.date }) where total > limit {
            if (try? fm.removeItem(at: f.url)) != nil { total -= f.bytes }
        }
    }

    /// Moves scans saved under the old, collision-prone key into this
    /// path's folder. The old folder may hold another path's scans too, so
    /// each file's own `rootPath` decides where it belongs. Even older
    /// versions kept a single `<key>.json` per path; that is folded in too.
    private static func migrateLegacy(_ rootPath: String, base: URL) {
        let fm = FileManager.default
        let normalized = (rootPath as NSString).standardizingPath
        let oldKey = legacyKey(rootPath)
        var candidates: [URL] = []
        let legacyFile = base.appending(path: oldKey + ".json")
        if fm.fileExists(atPath: legacyFile.path) { candidates.append(legacyFile) }
        let oldDir = base.appending(path: oldKey)
        if oldDir != folder(for: rootPath, base: base),
            let names = try? fm.contentsOfDirectory(atPath: oldDir.path)
        {
            candidates += names.filter { $0.hasSuffix(".json") }.map { oldDir.appending(path: $0) }
        }
        guard !candidates.isEmpty else { return }
        let dir = folder(for: rootPath, base: base)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for url in candidates {
            guard let s = load(SnapshotRef(date: .distantPast, url: url)),
                (s.rootPath as NSString).standardizingPath == normalized
            else { continue }
            let name = stamp.string(from: s.date) + "_" + UUID().uuidString.prefix(8).lowercased() + ".json"
            try? fm.moveItem(at: url, to: dir.appending(path: name))
        }
        if (try? fm.contentsOfDirectory(atPath: oldDir.path))?.isEmpty == true { try? fm.removeItem(at: oldDir) }
    }
}

/// The results MyMole saves so a pane shows something at once after a
/// launch: each pane's last scan and the disk map's history. Only these
/// files: keep lists, project rules and the cleanup history stay.
public enum SavedResults {
    public static func files(
        deepClean: URL = CleanStore.defaultBase, installers: URL = InstallerStore.defaultBase,
        apps: URL = AppStore.defaultBase, projects: URL = ProjectStore.defaultBase
    ) -> [URL] {
        [deepClean, installers, apps, projects].map { $0.appending(path: "last.json") }
            + [projects.appending(path: "history.json")]
    }

    /// Bytes the saved results take on disk.
    public static func bytes(files: [URL] = files(), snapshots: URL = SnapshotStore.defaultBase) -> Int64 {
        var total: Int64 = 0
        for var f in files {
            // A URL keeps values it read once; this one reads the disk now.
            f.removeAllCachedResourceValues()
            total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        if let walk = FileManager.default.enumerator(at: snapshots, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
            for case let u as URL in walk {
                total += Int64((try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
            }
        }
        return total
    }

    /// Removes the saved results; the next launch scans afresh. Pending
    /// writes go first, so none lands after.
    public static func clear(files: [URL] = files(), snapshots: URL = SnapshotStore.defaultBase) {
        StoreWrites.flush()
        for f in files { try? FileManager.default.removeItem(at: f) }
        try? FileManager.default.removeItem(at: snapshots)
    }
}

extension SavedResults {
    /// One kind of saved result, for Settings to show and clear on its own.
    public struct Part: Sendable, Identifiable {
        public let id: String
        public let title: String
        public let urls: [URL]
        public let bytes: Int64
        public let modified: Date?
    }

    public static func parts(
        deepClean: URL = CleanStore.defaultBase, installers: URL = InstallerStore.defaultBase,
        apps: URL = AppStore.defaultBase, projects: URL = ProjectStore.defaultBase,
        snapshots: URL = SnapshotStore.defaultBase, fingerprints: URL = FingerprintCache.defaultURL
    ) -> [Part] {
        let list: [(String, String, [URL])] = [
            ("deepClean", "Deep Clean's last scan", [deepClean.appending(path: "last.json")]),
            ("installers", "Installers' last scan", [installers.appending(path: "last.json")]),
            ("apps", "The app list", [apps.appending(path: "last.json")]),
            ("projects", "Projects' last scan and growth", [projects.appending(path: "last.json"), projects.appending(path: "history.json")]),
            ("snapshots", "Disk Map's saved scans", [snapshots]),
            ("fingerprints", "Similar Photos' fingerprints", [fingerprints]),
        ]
        return list.map { id, title, urls in
            var bytes: Int64 = 0
            var latest: Date?
            for u in urls {
                let (b, d) = measure(u)
                bytes += b
                if let d { latest = max(latest ?? d, d) }
            }
            return Part(id: id, title: title, urls: urls, bytes: bytes, modified: latest)
        }
    }

    private static func measure(_ url: URL) -> (Int64, Date?) {
        var u = url
        u.removeAllCachedResourceValues()
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .contentModificationDateKey, .isDirectoryKey]
        guard let v = try? u.resourceValues(forKeys: keys) else { return (0, nil) }
        guard v.isDirectory == true else { return (Int64(v.totalFileAllocatedSize ?? 0), v.contentModificationDate) }
        var total: Int64 = 0
        var latest = v.contentModificationDate
        for case let f as URL in FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) ?? FileManager.DirectoryEnumerator() {
            let fv = try? f.resourceValues(forKeys: keys)
            total += Int64(fv?.totalFileAllocatedSize ?? 0)
            if let d = fv?.contentModificationDate { latest = max(latest ?? d, d) }
        }
        return (total, latest)
    }

    /// Removes one kind of saved result; what couldn't be removed, if anything.
    public static func clear(_ part: Part) -> [String] {
        StoreWrites.flush()
        var failed: [String] = []
        for u in part.urls where FileManager.default.fileExists(atPath: u.path) {
            do { try FileManager.default.removeItem(at: u) } catch { failed.append(u.lastPathComponent) }
        }
        return failed
    }
}
