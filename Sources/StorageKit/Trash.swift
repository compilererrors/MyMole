import Darwin
import Foundation

/// Where an item went, so it can be put back.
public struct TrashRecord: Sendable, Hashable, Codable {
    public let original: URL
    public let trashed: URL

    public init(original: URL, trashed: URL) {
        self.original = original
        self.trashed = trashed
    }
}

/// The checks every move to the Trash passes, whichever flow asks. Beyond
/// the protected places every move refuses, a flow brings its own rule, run
/// again right before the move, and the user's protections (keep lists,
/// project rules), read at that moment; a list that can't be read stops
/// the whole move.
public struct TrashGate: Sendable {
    /// Whether `path` still meets the flow's rule.
    public var still: @Sendable (String) -> Bool
    /// Reads the user's protections and returns what they keep. Kept items
    /// cover what's inside them and the folders holding them.
    public var protections: @Sendable () throws -> @Sendable (String) -> Bool

    /// The protections are always given, so a flow that moves things can't
    /// leave out the user's keep lists by omission; one that has none to
    /// apply says so with `keepsNothing`.
    public init(
        still: @escaping @Sendable (String) -> Bool,
        protections: @escaping @Sendable () throws -> @Sendable (String) -> Bool
    ) {
        self.still = still
        self.protections = protections
    }

    /// For a flow the user's keep lists don't apply to, such as one only
    /// tests use.
    public static let keepsNothing: @Sendable () throws -> @Sendable (String) -> Bool = { { _ in false } }
}

/// Where moved items go: the system Trash in the app, and a folder of their
/// own in tests, so a test never touches the user's Trash. Putting items back
/// works the same for both (`Trasher.restore`).
public struct TrashBackend: Sendable {
    /// Moves one item; returns where it went, or why it didn't.
    public var moveOne: @Sendable (String) -> (trashed: URL?, error: String?)

    public init(moveOne: @escaping @Sendable (String) -> (trashed: URL?, error: String?)) {
        self.moveOne = moveOne
    }

    public static let system = TrashBackend { path in
        #if SMOKE
        return (nil, "System Trash is disabled in synthetic test builds.")
        #else
        var result: NSURL?
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &result)
            return (result as URL?, result == nil ? "The Trash didn't say where it went." : nil)
        } catch {
            return (nil, error.localizedDescription)
        }
        #endif
    }

    /// The coordinator supplies a checked URL, retaining any Powerbox grant.
    /// This backend uses ordinary permissions and never deletes permanently.
    public static func systemOutcome(for source: URL, area: ErrorCode.Area) -> TrashOutcome {
        #if SMOKE
        return TrashOutcome(moved: [], failed: [(source.path, "System Trash is disabled in synthetic test builds.")])
        #else
        var result: NSURL?
        do {
            try FileManager.default.trashItem(at: source, resultingItemURL: &result)
            guard let result else {
                return TrashOutcome(moved: [], failed: [(source.path, "The Trash didn't say where it went.")])
            }
            return TrashOutcome(moved: [TrashRecord(original: source, trashed: result as URL)], failed: [])
        } catch {
            return TrashOutcome(moved: [], failed: [(source.path, error.localizedDescription)],
                                failureInfo: [source.path: .init(error, area: area)])
        }
        #endif
    }

    /// Moves items into `dir`, which must be on the same volume, each under
    /// a name of its own.
    /// Where the app's moves go: the Trash. The UI smoke test's own build
    /// can point it at a folder of the run, since the real Trash is closed
    /// to that copy.
    public static var live: TrashBackend {
        #if SMOKE
        guard let scope = try? SyntheticRun.current() else { return TrashBackend { _ in (nil, "Synthetic run ownership is missing or invalid.") } }
        return .synthetic(scope)
        #else
        return .system
        #endif
    }

    #if DEBUG || SMOKE
    public static func synthetic(_ scope: SyntheticRun) -> TrashBackend {
        TrashBackend { path in
            do {
                return try scope.moving(path) { source, name, destination, target in
                    guard renameatx_np(source, name, destination, target, UInt32(RENAME_EXCL)) == 0 else {
                        return (nil, String(cString: strerror(errno)))
                    }
                    return (URL(fileURLWithPath: scope.trash + "/" + target), nil)
                }
            } catch { return (nil, "Outside the verified synthetic scope, or the scope changed.") }
        }
    }
    #endif

    public static func folder(_ dir: String) -> TrashBackend {
        TrashBackend { path in
            let to = dir + "/" + UUID().uuidString + "-" + (path as NSString).lastPathComponent
            guard renamex_np(path, to, UInt32(RENAME_EXCL)) == 0 else { return (nil, String(cString: strerror(errno))) }
            return (URL(fileURLWithPath: to), nil)
        }
    }
}

public struct TrashOutcome: Sendable {
    public struct FailureInfo: Sendable, Equatable {
        public let code: ErrorCode
        public let permissionDenied: Bool

        public init(_ error: any Error, area: ErrorCode.Area) {
            code = ErrorCode(area, error)
            var current: NSError? = error as NSError
            var denied = false
            for _ in 0..<8 {
                guard let error = current else { break }
                if error.domain == NSCocoaErrorDomain {
                    denied = denied || error.code == NSFileWriteNoPermissionError || error.code == NSFileReadNoPermissionError
                } else if error.domain == NSPOSIXErrorDomain {
                    denied = denied || error.code == Int(EACCES) || error.code == Int(EPERM)
                } else if error.domain == NSOSStatusErrorDomain {
                    // permErr and afpAccessDenied can be returned by native
                    // recycling without a wrapping Cocoa/POSIX error.
                    denied = denied || error.code == -54 || error.code == -5000
                }
                current = error.userInfo[NSUnderlyingErrorKey] as? NSError
            }
            permissionDenied = denied
        }
    }

    public let moved: [TrashRecord]
    public let failed: [(path: String, reason: String)]
    /// Optional platform diagnostics, restricted to entries that actually failed.
    public let failureInfo: [String: FailureInfo]

    public init(moved: [TrashRecord], failed: [(path: String, reason: String)], failureInfo: [String: FailureInfo] = [:]) {
        self.moved = moved
        self.failed = failed
        guard !failureInfo.isEmpty else {
            self.failureInfo = [:]
            return
        }
        let failedPaths = Set(failed.map(\.path))
        let movedPaths = Set(moved.map(\.original.path))
        self.failureInfo = failureInfo.filter { failedPaths.contains($0.key) && !movedPaths.contains($0.key) }
    }
}

/// Moves items to the Trash (never deletes outright) and can undo it.
public enum Trasher {
    /// A full path with no empty, "." or ".." parts, written exactly as
    /// it's checked. Unlike `standardizingPath`, which drops a leading
    /// "/private" and so changes paths under /private/var, nothing is
    /// rewritten: a path is plain or it's refused.
    public static func isPlainPath(_ path: String) -> Bool {
        // POSIX stops at NUL; the checked string must name the same item.
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return false }
        if path == "/" { return true }
        return path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// `path` with empty, "." and ".." parts worked out on the text alone:
    /// no link is followed and no "/private" dropped.
    public static func lexical(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": _ = parts.popLast()
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Paths that are never touched, however they were selected: the
    /// volume, system locations, the home folder and its top-level folders,
    /// anywhere inside keychains, SSH and GPG keys, the privacy database
    /// and Time Machine backups, and any folder holding one of those.
    public static func isProtected(_ path: String, home: String = Home.path) -> Bool {
        let p = lexical(path)
        let sealed = [
            home + "/Library/Keychains", home + "/.ssh", home + "/.gnupg",
            home + "/Library/Application Support/com.apple.TCC", "/Library/Keychains",
        ]
        // Sealed itself, inside, or holding one: moving a parent folder
        // would take the sealed one with it.
        if sealed.contains(where: { p == $0 || p.hasPrefix($0 + "/") || $0.hasPrefix(p + "/") }) { return true }
        if ["/Backups.backupdb", ".backupbundle", "/.MobileBackups"].contains(where: { p.contains($0 + "/") || p.hasSuffix($0) }) {
            return true
        }
        let fixed: Set<String> = [
            "/", "/System", "/Library", "/Applications", "/Users", "/private", "/usr", "/bin", "/sbin",
            "/opt", "/Volumes", home, home + "/Library", home + "/Desktop", home + "/Documents",
            home + "/Downloads", home + "/Pictures", home + "/Movies", home + "/Music",
            home + "/Library/Mobile Documents", home + "/Library/CloudStorage",
        ]
        if fixed.contains(p) { return true }
        // Nothing under the read-only system volume.
        return p.hasPrefix("/System/") || p.hasPrefix("/usr/") || p.hasPrefix("/bin/") || p.hasPrefix("/sbin/")
    }

    /// `path` with every folder above it resolved and the item itself left
    /// as it is, since a link is moved, not what it points to. Nil when a
    /// folder on the way doesn't resolve.
    public static func resolvingParent(_ path: String) -> String? {
        let p = lexical(path)
        let name = (p as NSString).lastPathComponent
        guard let parent = realPath((p as NSString).deletingLastPathComponent) else { return nil }
        return parent == "/" ? "/" + name : parent + "/" + name
    }

    /// Whether `path` is `base` or lies under it with no link on the way, so
    /// a folder swapped for a link can't lead a move somewhere else. For
    /// `base` itself, the folders holding it must be free of links too.
    public static func noLinksBetween(_ base: String, and path: String) -> Bool {
        if path == base {
            guard let dir = openFolder((base as NSString).deletingLastPathComponent, creating: false) else { return false }
            close(dir)
            return true
        }
        guard path.hasPrefix(base + "/"), let real = resolvingParent(path), let realBase = realPath(base) else { return false }
        return real == realBase + path.dropFirst(base.count)
    }

    static func realPath(_ path: String) -> String? {
        guard let r = realpath(path, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }

    /// Protected as written, or once the folders above it are resolved:
    /// a link can only take a path out of reach, never into it.
    static func isProtectedResolved(_ path: String, home: String = Home.path) -> Bool {
        if isProtected(path, home: home) { return true }
        guard let real = resolvingParent(path) else { return true }
        return isProtected(real, home: realPath(home) ?? home)
    }

    /// `paths` without any that sit inside another one in the list. Moving
    /// a child and then its parent would make undo recreate the parent's
    /// folder before the parent itself comes back, so that restore fails.
    public static func outermost(_ paths: some Collection<String>) -> [String] {
        let all = Set(paths)
        return all.filter { p in
            var cur = (p as NSString).deletingLastPathComponent
            while cur.count > 1 {
                if all.contains(cur) { return false }
                cur = (cur as NSString).deletingLastPathComponent
            }
            return true
        }
        .sorted()
    }

    /// The paths the gate lets through, and why each of the others stays.
    /// Protections that can't be read stop everything.
    public static func clear(_ paths: [String], through gate: TrashGate) -> (allowed: [String], refused: [(path: String, reason: String)]) {
        let keeps: @Sendable (String) -> Bool
        do {
            keeps = try gate.protections()
        } catch {
            return ([], paths.map { ($0, protectionsUnreadable) })
        }
        var allowed: [String] = []
        var refused: [(path: String, reason: String)] = []
        for path in paths {
            if !isPlainPath(path) {
                refused.append((path, "Not a plain full path"))
            } else if isProtectedResolved(path) {
                refused.append((path, "Protected location"))
            } else if keeps(path) {
                refused.append((path, "Kept"))
            } else if !gate.still(path) {
                refused.append((path, "Changed since it was checked"))
            } else {
                allowed.append(path)
            }
        }
        return (allowed, refused)
    }

    /// Moves what the gate lets through to the Trash. Every flow moves
    /// through here or through a `TrashJob`, which does the same as one step
    /// of a job, so none can skip a check. The whole batch is cleared first
    /// and planned (`Trasher.plan`), and each item is checked again right
    /// before it moves (`Trasher.run`).
    public static func moveToTrash(_ paths: [String], through gate: TrashGate, backend: TrashBackend = .system) -> TrashOutcome {
        var plan = plan(paths, through: gate)
        run(&plan, through: gate, backend: backend)
        return plan.outcome
    }

    /// How often a long batch reads the protections again.
    static let refreshProtections: TimeInterval = 0.5

    /// Why nothing moved when the user's protections didn't load.
    public static let protectionsUnreadable = "Your protections couldn't be read, so nothing was moved."

    /// The entry at `path` as the file system names it: kind, volume and
    /// file number. Nil when there's nothing there.
    public struct Identity: Equatable, Sendable, Codable {
        public let type: mode_t
        public let device: dev_t
        public let inode: ino_t

        public init(type: mode_t, device: dev_t, inode: ino_t) {
            self.type = type; self.device = device; self.inode = inode
        }
    }

    public static func identity(of path: String) -> Identity? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return Identity(type: st.st_mode & S_IFMT, device: st.st_dev, inode: st.st_ino)
    }

    static func move(_ paths: [String], backend: TrashBackend = .system) -> TrashOutcome {
        var moved: [TrashRecord] = []
        var failed: [(String, String)] = []
        for path in paths {
            if isProtectedResolved(path) {
                failed.append((path, "Protected location"))
                continue
            }
            let r = backend.moveOne(path)
            if let to = r.trashed {
                moved.append(TrashRecord(original: URL(fileURLWithPath: path), trashed: to))
            } else {
                failed.append((path, r.error ?? "Not moved"))
            }
        }
        return TrashOutcome(moved: moved, failed: failed)
    }

    /// Puts trashed items back where they were. Returns those that couldn't
    /// be restored, so they can be tried again: an emptied Trash, something
    /// new in the old spot (never overwritten), a protected place, or a
    /// folder on the way that's now a link, which would lead elsewhere.
    public static func restore(_ records: [TrashRecord]) -> [TrashRecord] {
        // Last moved, first back: the reverse of how they left.
        records.reversed().filter { !restore($0) }
    }

    static func restore(_ r: TrashRecord) -> Bool {
        let original = r.original.path
        guard isPlainPath(original), !isProtected(original) else { return false }
        let name = (original as NSString).lastPathComponent
        guard let dir = openFolder((original as NSString).deletingLastPathComponent, creating: true) else { return false }
        defer { close(dir) }
        return renameatx_np(AT_FDCWD, r.trashed.path, dir, name, UInt32(RENAME_EXCL)) == 0
    }

    /// The links macOS itself puts at the top: /var, /tmp and /etc lead
    /// into /private. Any other link on the way is refused.
    static let systemLinks = ["/var", "/tmp", "/etc"]

    /// Opens the folder at `path` one part at a time, never following a
    /// link, and creates missing parts when asked. Nil when a part is a link,
    /// isn't a folder or can't be opened.
    ///
    /// A path in the home folder is walked from the home folder itself,
    /// which must not be a link: the folders above it belong to root, and
    /// the App Sandbox lets the App Store edition open the home folder the
    /// user granted but not /Users.
    static func openFolder(_ path: String, creating: Bool, home: String = Home.path) -> Int32? {
        guard isPlainPath(path) else { return nil }
        let p = systemLinks.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) ? "/private" + path : path
        let anchor = home != "/" && isPlainPath(home) && (p == home || p.hasPrefix(home + "/")) ? home : "/"
        var fd = open(anchor, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        for part in p.dropFirst(anchor == "/" ? 0 : anchor.count).split(separator: "/") {
            let name = String(part)
            var next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT, creating {
                if mkdirat(fd, name, 0o755) != 0 && errno != EEXIST {
                    close(fd)
                    return nil
                }
                next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            close(fd)
            guard next >= 0 else { return nil }
            fd = next
        }
        return fd
    }
}
