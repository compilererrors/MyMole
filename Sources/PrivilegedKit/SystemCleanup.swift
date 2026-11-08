import Darwin
import Foundation
import StorageKit

// System-level caches and logs: the parts of /Library and /private/var that
// only root may remove. The helper scans and removes them; every path it is
// asked to remove is checked against these rules again in the helper
// itself, so the app can't widen what root touches. Removal is permanent:
// root-owned files can't go to a user's Trash and be put back. Each entry is
// first moved into a folder only the helper may enter and checked again
// there, so swapping the entry for a link after the check can't redirect
// what root removes.

public struct SystemCandidate: Codable, Sendable, Hashable, Identifiable {
    public let path: String
    public let bytes: Int64
    public let modified: Date
    public let safety: CleanSafety
    public let reason: String
    /// Part of it couldn't be read even as root (a protected system folder).
    public var incomplete: Bool? = nil

    public init(path: String, bytes: Int64, modified: Date, safety: CleanSafety, reason: String) {
        self.path = path
        self.bytes = bytes
        self.modified = modified
        self.safety = safety
        self.reason = reason
    }

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
}

public struct RemovalReport: Codable, Sendable, Equatable {
    public var removed: [String] = []
    public var refused: [String] = []
    public var failed: [String: String] = [:]
    public var bytes: Int64 = 0

    public init() {}
}

public enum SystemCleanRules {
    public struct Root: Sendable {
        public let path: String
        /// Rotated log archives only (`system.log.0.gz`), not live logs.
        public let rotatedLogsOnly: Bool
        public let reason: String

        public init(path: String, rotatedLogsOnly: Bool = false, reason: String) {
            self.path = path
            self.rotatedLogsOnly = rotatedLogsOnly
            self.reason = reason
        }
    }

    public static let roots: [Root] = [
        Root(path: "/Library/Caches", reason: "System-wide cache. Rebuilt by the service that made it."),
        Root(path: "/Library/Logs", reason: "System-wide logs and crash reports."),
        Root(path: "/private/var/log", rotatedLogsOnly: true, reason: "An old, rotated system log archive."),
    ]

    /// Never offered or removed: these tie into booting or the update
    /// machinery rather than being caches.
    static let never: Set<String> = [
        "com.apple.bootstamps", "com.apple.kext.caches", "com.apple.dyld", "com.apple.preboot", "com.apple.rootless",
        "com.apple.softwareupdate", "com.apple.SoftwareUpdate", ".DS_Store", Staging.containerName,
    ]

    static func isRotatedLog(_ name: String) -> Bool {
        name.wholeMatch(of: /.+\.(gz|bz2|xz|zip)/) != nil || name.wholeMatch(of: /.+\.\d+/) != nil
    }

    static func safety(of name: String) -> CleanSafety {
        name.hasPrefix("com.apple.") ? .review : .safe
    }

    /// Everything removable under `roots`, largest first.
    public static func scan(roots: [Root] = roots, progress: ScanProgress = ScanProgress()) -> [SystemCandidate] {
        list(roots: roots, progress: progress).candidates
    }

    /// What `scan` finds, and the roots that are there but couldn't be read.
    public static func list(roots: [Root] = roots, progress: ScanProgress = ScanProgress()) -> SystemCleanListing {
        var out: [SystemCandidate] = []
        var unreadable: [String] = []
        for root in roots where !progress.isCancelled {
            guard let names = DirectoryListing.names(root.path) else {
                unreadable.append(root.path)
                continue
            }
            for name in names.sorted() {
                let path = root.path + "/" + name
                guard allowed(path, roots: roots) else { continue }
                var st = stat()
                guard lstat(path, &st) == 0 else { continue }
                let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
                let bytes: Int64
                var modified = mtime
                var incomplete = false
                if st.st_mode & S_IFMT == S_IFDIR {
                    let r = StorageScanner.scan(path: path, progress: progress, workers: 2)
                    bytes = r.root.size
                    modified = max(mtime, r.root.latestChange)
                    incomplete = !r.deniedPaths.isEmpty || r.root.unreadable
                } else {
                    bytes = Int64(st.st_blocks) * 512
                }
                guard bytes > 0 else { continue }
                var c = SystemCandidate(path: path, bytes: bytes, modified: modified, safety: safety(of: name), reason: root.reason)
                c.incomplete = incomplete ? true : nil
                out.append(c)
            }
        }
        return SystemCleanListing(
            candidates: out.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }, unreadable: unreadable)
    }

    /// A direct entry of a root, not a link, not on the never list, and a
    /// rotated archive where the root allows only those.
    public static func allowed(_ path: String, roots: [Root] = roots) -> Bool {
        guard Trasher.isPlainPath(path) else { return false }
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard let root = roots.first(where: { $0.path == parent }), !name.isEmpty, !never.contains(name) else { return false }
        return allowedType(path, rotatedLogsOnly: root.rotatedLogsOnly, name: name)
    }

    /// Removes what passes `allowed` and `keep` doesn't protect,
    /// permanently. Anything else is refused. One removal runs at a time;
    /// each stages only its own entries.
    public static func remove(_ paths: [String], keep: CleanKeepList = CleanKeepList(), roots: [Root] = roots) -> RemovalReport {
        Staging.lock.lock()
        defer { Staging.lock.unlock() }
        var report = RemovalReport()
        var staging = Staging()
        defer { staging.finish() }
        for path in Set(paths).sorted() {
            guard allowed(path, roots: roots), !keep.protects(path) else {
                report.refused.append(path)
                continue
            }
            let parent = (path as NSString).deletingLastPathComponent
            let rotated = roots.first { $0.path == parent }?.rotatedLogsOnly ?? false
            let name = (path as NSString).lastPathComponent
            removeStaged(
                path, staging: &staging,
                recheck: { allowedType($0, rotatedLogsOnly: rotated, name: name) },
                size: sizeOf, report: &report)
        }
        return report
    }

    static func allowedType(_ path: String, rotatedLogsOnly: Bool, name: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        let type = st.st_mode & S_IFMT
        if rotatedLogsOnly { return type == S_IFREG && isRotatedLog(name) }
        return type == S_IFDIR || type == S_IFREG
    }

    static func sizeOf(_ path: String) -> Int64 {
        var st = stat()
        guard lstat(path, &st) == 0 else { return 0 }
        if st.st_mode & S_IFMT == S_IFDIR { return StorageScanner.scan(path: path, workers: 2).root.size }
        return Int64(st.st_blocks) * 512
    }
}

/// What a look through the system caches and logs found.
public struct SystemCleanListing: Sendable {
    public var candidates: [SystemCandidate]
    /// Places that are there but couldn't be read: what's in them isn't listed.
    public var unreadable: [String]

    public init(candidates: [SystemCandidate], unreadable: [String] = []) {
        self.candidates = candidates
        self.unreadable = unreadable
    }
}

extension SystemCleanRules {
    /// Staging folders an earlier removal left in `roots`: it stopped
    /// part-way (a lost connection, a restart), and what it moved aside is
    /// still there with notes of where each came from. Nothing deletes them
    /// on its own; a new removal only ever deletes what it staged itself.
    public static func leftStaging() -> [String] {
        leftStaging(at: roots.map(\.path) + SystemLeftovers.places.map(\.folder))
    }

    static func leftStaging(at roots: [String]) -> [String] {
        roots.compactMap { root in
            let container = root + "/" + Staging.containerName
            var st = stat()
            return lstat(container, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR ? container : nil
        }
        .sorted()
    }
}
