import Darwin
import Foundation

/// Exact app identities in macOS's per-user runtime roots. Temporary data
/// can include unsaved work, so every result is manual-review data.
public enum RuntimeLeftovers {
    public struct Root: Sendable, Hashable {
        public enum Kind: Sendable, Hashable { case caches, temporary }
        public let path: String
        public let kind: Kind
        public init(path: String, kind: Kind) { self.path = Trasher.lexical(path); self.kind = kind }
        public var place: String { kind == .caches ? "Per-user runtime caches" : "Per-user temporary data" }
    }

    /// Resolve paths only. Tests pass their own roots; ordinary model
    /// initializers never open the caller's real temporary/cache folders.
    public static func systemRoots() -> [Root] {
        func path(_ name: Int32) -> String? {
            let length = confstr(name, nil, 0)
            guard length > 1, length <= Int(PATH_MAX) else { return nil }
            var bytes = [CChar](repeating: 0, count: length)
            guard confstr(name, &bytes, length) == length else { return nil }
            return URL(fileURLWithPath: String(cString: bytes)).resolvingSymlinksInPath().path
        }
        return [(Int32(_CS_DARWIN_USER_CACHE_DIR), Root.Kind.caches), (Int32(_CS_DARWIN_USER_TEMP_DIR), .temporary)]
            .compactMap { key, kind in path(key).map { Root(path: $0, kind: kind) } }
    }

    public static func find(for app: AppBundle, installed: [AppBundle], identity: AppIdentity, roots: [Root], progress: ScanProgress) -> [Leftover] {
        find(for: app, installed: installed, identity: identity, roots: roots, scan: LeftoverScan(progress: progress))
    }

    static func find(for app: AppBundle, installed: [AppBundle], identity: AppIdentity, roots: [Root], scan: LeftoverScan) -> [Leftover] {
        guard let ids = ownedIDs(app, installed: installed, identity: identity) else { return [] }
        var result: [Leftover] = []
        var seen = Set<String>()
        for root in roots where !scan.shouldStop {
            for id in ids where !scan.shouldStop {
                let path = root.path + "/" + id
                var entry = stat()
                if lstat(path, &entry) != 0 {
                    if errno != ENOENT && errno != ENOTDIR { scan.noteUnreadable(path) }
                    continue
                }
                guard seen.insert(path).inserted else { continue }
                guard isStill(path, of: app, installed: installed, identity: identity, roots: [root]) else {
                    scan.noteUnreadable(path)
                    continue
                }
                guard let bytes = scan.measure(path) else { continue }
                var item = Leftover(path: path, bytes: bytes, place: root.place)
                item.evidence = .runtimeID
                result.append(item)
            }
        }
        return result
    }

    public static func isStill(_ path: String, of app: AppBundle, installed: [AppBundle], identity: AppIdentity, roots: [Root]) -> Bool {
        guard !roots.isEmpty, let root = roots.first(where: { $0.path == (path as NSString).deletingLastPathComponent }),
              Trasher.isPlainPath(path), let ids = ownedIDs(app, installed: installed, identity: identity),
              ids.contains(where: { $0 == (path as NSString).lastPathComponent }),
              root.path != "/", URL(fileURLWithPath: root.path).resolvingSymlinksInPath().path == root.path,
              Trasher.noLinksBetween(root.path, and: path) else { return false }
        var base = stat(), entry = stat()
        guard lstat(root.path, &base) == 0, base.st_mode & S_IFMT == S_IFDIR, base.st_uid == geteuid(),
              lstat(path, &entry) == 0, entry.st_uid == geteuid(), entry.st_dev == base.st_dev else { return false }
        return entry.st_mode & S_IFMT == S_IFDIR || entry.st_mode & S_IFMT == S_IFREG
    }

    private static func ownedIDs(_ app: AppBundle, installed: [AppBundle], identity: AppIdentity) -> [String]? {
        guard !app.isProtected, let id = app.bundleID, AppLeftovers.isWellFormed(id),
              !installed.contains(where: { $0.path != app.path && $0.bundleID?.caseInsensitiveCompare(id) == .orderedSame }),
              !identity.otherOwnerIDs.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) else { return nil }
        return ([id] + identity.helperIDs).filter { candidate in
            AppLeftovers.isWellFormed(candidate) && !identity.otherOwnerIDs.contains { other in
                candidate.caseInsensitiveCompare(other) == .orderedSame || candidate.lowercased().hasPrefix(other.lowercased() + ".")
            }
        }
    }
}
