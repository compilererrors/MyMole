import Darwin
import Foundation
import StorageKit
import SystemConfiguration

/// One administrator-approved app move. No arbitrary destination, recursive
/// deletion, changes to existing ownership or permission repair is part of it.
public enum ApplicationTrash {
    public struct Request: Codable, Sendable, Equatable {
        public let path: String
        public let bundleID: String
        public let identity: Trasher.Identity
        public let parentIdentity: Trasher.Identity
        public let uid: uid_t
        public let trashName: String

        public init(path: String, bundleID: String, identity: Trasher.Identity,
                    parentIdentity: Trasher.Identity, uid: uid_t, trashName: String) {
            self.path = path; self.bundleID = bundleID; self.identity = identity
            self.parentIdentity = parentIdentity; self.uid = uid; self.trashName = trashName
        }

        /// Only root-owned third-party apps directly in Applications qualify.
        /// The original pre-move proof prevents a replacement being authorized.
        public static func isEligible(_ app: AppBundle, source: RemovedApp.Source) -> Bool {
            var st = stat()
            guard (app.path as NSString).deletingLastPathComponent == "/Applications",
                  source.isAtOriginalPath, !app.isProtected, let id = app.bundleID,
                  !id.lowercased().hasPrefix("com.apple."), AppLeftovers.isWellFormed(id),
                  lstat(app.path, &st) == 0, st.st_uid == 0, st.st_mode & S_IFMT == S_IFDIR else { return false }
            return true
        }

        public static func capture(_ app: AppBundle, source: RemovedApp.Source) -> Request? {
            guard isEligible(app, source: source), let id = app.bundleID else { return nil }
            let name = (app.path as NSString).lastPathComponent
            let trash = Home.path + "/.Trash/"
            guard let destination = availableTrashName(for: name, occupied: { candidate in
                var entry = stat()
                if lstat(trash + candidate, &entry) == 0 { return true }
                return errno == ENOENT ? false : nil
            }) else { return nil }
            return Request(path: app.path, bundleID: id, identity: source.originalIdentity,
                           parentIdentity: source.originalParentIdentity, uid: getuid(),
                           trashName: destination)
        }

        /// Names are reserved by the final exclusive rename, never overwritten.
        /// The inexpensive preflight only proposes a readable destination.
        static func availableTrashName(for name: String, occupied: (String) -> Bool?) -> String? {
            for number in 1...9_999 {
                let candidate = trashName(for: name, number: number)
                guard let exists = occupied(candidate) else { return nil }
                if !exists { return candidate }
            }
            return nil
        }

        static func trashName(for name: String, number: Int) -> String {
            number == 1 ? name : (name as NSString).deletingPathExtension + " \(number)." + (name as NSString).pathExtension
        }

        static func acceptsTrashName(_ value: String, original name: String, restoring: Bool) -> Bool {
            if value == name { return true }
            let stem = (name as NSString).deletingPathExtension
            let ext = "." + (name as NSString).pathExtension
            if value.hasPrefix(stem + " "), value.hasSuffix(ext) {
                let digits = String(value.dropFirst(stem.count + 1).dropLast(ext.count))
                if let number = Int(digits), (2...9_999).contains(number), trashName(for: name, number: number) == value { return true }
            }
            // Receipts produced by an earlier build can still be restored.
            return restoring && value.count > 37 && UUID(uuidString: String(value.prefix(36))) != nil
                && value == String(value.prefix(36)) + "-" + name
        }
    }

    public struct Receipt: Codable, Sendable, Equatable {
        public let request: Request
        public let record: TrashRecord
        public init(request: Request, record: TrashRecord) { self.request = request; self.record = record }

        public func isInTrash(home: String) -> Bool {
            record.original.path == request.path && record.trashed.path == home + "/.Trash/" + request.trashName
                && Trasher.identity(of: record.trashed.path) == request.identity
                && RemovedApp.read(path: record.trashed.path, home: home)?.app.bundleID == request.bundleID
        }
    }

    public struct Failure: LocalizedError, CustomNSError, Codable, Sendable, Equatable {
        public enum Reason: Int, Codable, Sendable {
            case validation = 2100, trashChanged, appChanged, protections, processUnknown, appOpen
            case backgroundUnverified, backgroundStopFailed, backgroundStillRunning
        }
        public let reason: Reason
        public let detail: String
        public init(_ reason: Reason, _ detail: String) { self.reason = reason; self.detail = detail }
        static func refused(_ detail: String) -> Self { Self(.validation, detail) }
        public var errorDescription: String? { detail }
        public static var errorDomain: String { "PrivilegedKit.ApplicationTrashFailure" }
        public var errorCode: Int { reason.rawValue }
        public var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: detail] }
    }

    /// Tests supply only their own directories and account. The helper never
    /// accepts these fields from its command-line request.
    struct Context {
        let applications: String
        let home: String
        let uid: uid_t
        let gid: gid_t
        let appOwner: uid_t
        let staging: String
        var running: (String) -> Bool? = ApplicationTrash.running
        var stopBackgroundAgents: ((Request) throws -> Void)? = nil
        var beforeStage: () -> Void = {}
        var beforeCommit: () -> Void = {}
        var rename: (Int32, String, Int32, String) -> Int32 = {
            renameatx_np($0, $1, $2, $3, UInt32(RENAME_EXCL))
        }
    }

    private struct Recovery: Codable {
        let request: Request
        let restoring: Bool
        let source: String
        let destination: String
    }

    public static func move(_ request: Request, restoring: Bool = false) throws -> Receipt {
        guard geteuid() == 0 else { throw Failure.refused("Administrator approval is required.") }
        var uid: uid_t = 0, gid: gid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid), name as String != "loginwindow",
              uid >= 501, uid == request.uid, let account = getpwuid(uid), let home = account.pointee.pw_dir else {
            throw Failure.refused("The signed-in user changed. Return to MyMole and try again.")
        }
        // Persistent across a reboot: an interrupted move must not leave an
        // app in /var/run or another directory the system clears automatically.
        let database = try directory("/private/var/db")
        defer { close(database) }
        let stageRoot = "mymole-app-moves"
        guard mkdirat(database, stageRoot, 0o700) == 0 || errno == EEXIST,
              let privateRoot = openDirectory(database, stageRoot) else {
            throw Failure.refused("No private administrator staging folder is available.")
        }
        var rootStat = stat()
        let safeRoot = fstat(privateRoot, &rootStat) == 0 && rootStat.st_uid == 0 && rootStat.st_mode & 0o077 == 0
        close(privateRoot)
        guard safeRoot else { throw Failure.refused("The administrator staging folder is not private.") }
        defer { _ = unlinkat(database, stageRoot, AT_REMOVEDIR) }
        var context = Context(applications: "/Applications", home: String(cString: home), uid: uid,
                              gid: account.pointee.pw_gid, appOwner: 0, staging: "/private/var/db/" + stageRoot)
        context.stopBackgroundAgents = { try BundledAppAgents.stop($0, owner: 0) }
        return try move(request, restoring: restoring, context: context)
    }

    static func move(_ request: Request, restoring: Bool = false, context: Context) throws -> Receipt {
        let name = (request.path as NSString).lastPathComponent
        guard request.uid == context.uid, request.uid >= 501,
              Trasher.isPlainPath(request.path), (request.path as NSString).deletingLastPathComponent == context.applications,
              name.lowercased().hasSuffix(".app"), name.utf8.count <= 200,
              AppLeftovers.isWellFormed(request.bundleID), !request.bundleID.lowercased().hasPrefix("com.apple."),
              Request.acceptsTrashName(request.trashName, original: name, restoring: restoring) else {
            throw Failure.refused("This request does not name an eligible application.")
        }
        let apps = try directory(context.applications)
        defer { close(apps) }
        guard identity(apps) == request.parentIdentity else { throw Failure.refused("The Applications folder changed.") }
        let home = try directory(context.home)
        defer { close(home) }
        var homeStat = stat()
        guard fstat(home, &homeStat) == 0, homeStat.st_uid == context.uid, homeStat.st_mode & 0o022 == 0 else {
            throw Failure.refused("No safe home folder was found for the signed-in user.")
        }
        try prepareTrash(in: home, context: context)
        let trash = openat(home, ".Trash", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard trash >= 0 else { throw Failure.refused("The user's Trash must be a real directory.") }
        defer { close(trash) }
        var trashStat = stat()
        guard fstat(trash, &trashStat) == 0, trashStat.st_uid == context.uid, trashStat.st_mode & 0o077 == 0 else {
            throw Failure.refused("The user's Trash is not private to that user.")
        }
        let trashIdentity = identity(trash)
        func trashIsCurrent() -> Bool { identity(home, ".Trash") == trashIdentity }
        let (from, fromName, to, toName) = restoring ? (trash, request.trashName, apps, name) : (apps, name, trash, request.trashName)
        func eligible(_ parent: Int32, _ leaf: String) -> Bool {
            guard identity(parent, leaf) == request.identity,
                  let fd = openDirectory(parent, leaf) else { return false }
            defer { close(fd) }
            var st = stat()
            guard fstat(fd, &st) == 0, st.st_uid == context.appOwner,
                  st.st_mode & 0o022 == 0, st.st_flags & (UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND | SF_NOUNLINK)) == 0,
                  let contents = openDirectory(fd, "Contents") else { return false }
            defer { close(contents) }
            guard let data = try? read(contents, "Info.plist", owner: context.appOwner),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  info["CFBundleIdentifier"] as? String == request.bundleID, info["CFBundlePackageType"] as? String == "APPL",
                  let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty,
                  executable != ".", executable != "..", !executable.contains("/"), !executable.utf8.contains(0),
                  let binaries = openDirectory(contents, "MacOS") else { return false }
            defer { close(binaries) }
            var binary = stat()
            return fstatat(binaries, executable, &binary, AT_SYMLINK_NOFOLLOW) == 0
                && binary.st_mode & S_IFMT == S_IFREG && binary.st_mode & 0o111 != 0
        }
        func allowedNow() -> Bool {
            trashIsCurrent() && context.running(request.path) == false
                && (restoring || mayRemove(request.path, context: context))
        }
        context.beforeStage()
        guard trashIsCurrent() else { throw Failure(.trashChanged, "The Trash changed. Nothing was moved.") }
        guard eligible(from, fromName) else { throw Failure(.appChanged, "The app changed or its metadata couldn't be verified. Nothing was moved.") }
        guard restoring || mayRemove(request.path, context: context) else {
            throw Failure(.protections, "The app is kept, or its protection rules couldn't be read. Nothing was moved.")
        }
        guard let open = context.running(request.path) else {
            throw Failure(.processUnknown, "Running processes couldn't be checked. Nothing was moved.")
        }
        if open, !restoring, let stop = context.stopBackgroundAgents {
            try stop(request)
        } else if open {
            throw Failure(.appOpen, "The app or one of its background processes is still running. Nothing was moved.")
        }
        guard allowedNow(), eligible(from, fromName) else {
            throw Failure(.backgroundStillRunning, "The app restarted or its protections changed. Nothing was moved. If its background agents were stopped, reopening the app restores them.")
        }
        var destination = stat()
        guard fstatat(to, toName, &destination, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
            throw Failure.refused("The destination is occupied. Nothing was overwritten.")
        }

        let stageParent = try directory(context.staging)
        defer { close(stageParent) }
        var stageStat = stat()
        guard fstat(stageParent, &stageStat) == 0, stageStat.st_uid == geteuid(), stageStat.st_mode & 0o022 == 0 else {
            throw Failure.refused("No private administrator staging folder is available.")
        }
        let stageName = ".mymole-app-move-" + UUID().uuidString
        guard mkdirat(stageParent, stageName, 0o700) == 0, let stage = openDirectory(stageParent, stageName) else {
            throw Failure.refused("The app move could not be prepared.")
        }
        defer { close(stage); _ = unlinkat(stageParent, stageName, AT_REMOVEDIR) }
        var staged = false
        defer { if !staged { _ = unlinkat(stage, "request.json", 0) } }
        let note = openat(stage, "request.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard note >= 0 else { throw Failure.refused("The app move could not be recorded.") }
        let trashPath = context.home + "/.Trash/" + request.trashName
        let data = try JSONEncoder().encode(Recovery(request: request, restoring: restoring,
            source: restoring ? trashPath : request.path, destination: restoring ? request.path : trashPath))
        let written = data.withUnsafeBytes { Darwin.write(note, $0.baseAddress, $0.count) }
        let synced = fsync(note) == 0
        close(note)
        guard written == data.count, synced else { throw Failure.refused("The app move could not be recorded.") }
        guard context.rename(from, fromName, stage, "bundle.app") == 0 else {
            let code = errno
            throw Failure.refused("macOS blocked the administrator move (POSIX \(code)). The app stayed in place.")
        }
        staged = true
        func rollBack() -> String {
            if context.rename(stage, "bundle.app", from, fromName) == 0 {
                staged = false
                return "The app was returned to its original location."
            }
            return "The app is kept at \(context.staging)/\(stageName)/bundle.app; its request.json records the original location."
        }
        context.beforeCommit()
        guard allowedNow(), context.running(context.staging + "/" + stageName + "/bundle.app") == false,
              eligible(stage, "bundle.app") else {
            throw Failure.refused("The app or its protections changed. " + rollBack())
        }
        guard context.rename(stage, "bundle.app", to, toName) == 0 else {
            let code = errno
            throw Failure.refused("The destination could not accept the app (POSIX \(code)). " + rollBack())
        }
        staged = false
        // Directory inference depends on whether the move already happened.
        // Keep the serialized receipt identical for the move and its restore.
        let original = URL(fileURLWithPath: request.path, isDirectory: true)
        let trashed = URL(fileURLWithPath: context.home + "/.Trash/" + request.trashName, isDirectory: true)
        return Receipt(request: request, record: TrashRecord(original: original, trashed: trashed))
    }

    static func directory(_ path: String) throws -> Int32 {
        guard Trasher.isPlainPath(path) else { throw Failure.refused("A linked or malformed folder was refused.") }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.refused("A folder could not be opened.") }
        for name in path.split(separator: "/") {
            let next = openDirectory(fd, String(name)); close(fd)
            guard let next else { throw Failure.refused("A linked or inaccessible folder was refused.") }
            fd = next
        }
        return fd
    }

    static func openDirectory(_ parent: Int32, _ name: String) -> Int32? {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        return fd >= 0 ? fd : nil
    }

    private static func prepareTrash(in home: Int32, context: Context) throws {
        var st = stat()
        if fstatat(home, ".Trash", &st, AT_SYMLINK_NOFOLLOW) == 0 { return }
        guard errno == ENOENT else { throw Failure.refused("The user's Trash is not available.") }
        // Prepare a NEW folder under a private administrator directory before
        // publishing it. Never chown an entry in a user-writable parent: the
        // entry could have been swapped for an unrelated root-owned directory.
        let parent = try directory(context.staging)
        defer { close(parent) }
        guard fstat(parent, &st) == 0, st.st_uid == geteuid(), st.st_mode & 0o022 == 0 else {
            throw Failure.refused("No private administrator staging folder is available.")
        }
        let name = ".trash-" + UUID().uuidString
        guard mkdirat(parent, name, 0o700) == 0, let fd = openDirectory(parent, name) else {
            throw Failure.refused("The user's Trash could not be prepared.")
        }
        defer { close(fd); _ = unlinkat(parent, name, AT_REMOVEDIR) }
        guard fchown(fd, context.uid, context.gid) == 0 else { throw Failure.refused("The new Trash could not be assigned to its user.") }
        guard renameatx_np(parent, name, home, ".Trash", UInt32(RENAME_EXCL)) == 0 || errno == EEXIST else {
            throw Failure.refused("The user's Trash could not be created on the same volume.")
        }
    }
    private static func identity(_ fd: Int32) -> Trasher.Identity? {
        var st = stat(); guard fstat(fd, &st) == 0 else { return nil }
        return Trasher.Identity(type: st.st_mode & S_IFMT, device: st.st_dev, inode: st.st_ino)
    }
    private static func identity(_ parent: Int32, _ name: String) -> Trasher.Identity? {
        var st = stat(); guard fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return Trasher.Identity(type: st.st_mode & S_IFMT, device: st.st_dev, inode: st.st_ino)
    }

    /// Regular, single-link bounded files only; never block on a FIFO or
    /// follow a user-controlled link while the helper has administrator rights.
    static func read(_ parent: Int32, _ name: String, owner: uid_t) throws -> Data {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.refused("App metadata or protections could not be read.") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1,
              st.st_uid == owner, st.st_mode & 0o022 == 0, st.st_size >= 0, st.st_size <= 1_048_576 else {
            throw Failure.refused("App metadata or protections are not a bounded regular file.")
        }
        var buffer = [UInt8](repeating: 0, count: Int(st.st_size) + 1)
        let count = Darwin.read(fd, &buffer, buffer.count)
        guard count == Int(st.st_size) else { throw Failure.refused("App metadata or protections changed while being read.") }
        return Data(buffer.prefix(count))
    }

    private static func mayRemove(_ path: String, context: Context) -> Bool {
        let previous = geteuid()
        guard previous == context.uid || (previous == 0 && seteuid(context.uid) == 0) else { return false }
        var allowed = false
        do {
            func ownFile(_ relative: String) throws -> Data? {
                let path = context.home + "/Library/Application Support/MyMole/" + relative
                var st = stat()
                if lstat(path, &st) != 0, errno == ENOENT { return nil }
                let parent = try directory((path as NSString).deletingLastPathComponent)
                defer { close(parent) }
                return try read(parent, (path as NSString).lastPathComponent, owner: context.uid)
            }
            let keep = try ownFile("DeepClean/keep.json").map { try JSONDecoder().decode(CleanKeepList.self, from: $0) } ?? .init()
            let rules = try ownFile("Projects/rules.json").map { try JSONDecoder().decode(ProjectRules.self, from: $0) } ?? .init()
            allowed = !CleanKeepList(paths: keep.paths.union(rules.keepPaths)).protects(path)
        } catch { allowed = false }
        if previous != context.uid, seteuid(previous) != 0 { return false }
        return allowed
    }

    private static func running(_ app: String) -> Bool? {
        BundledAppAgents.processes(in: app).map { !$0.isEmpty }
    }
}
