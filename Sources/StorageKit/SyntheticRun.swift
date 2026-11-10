#if DEBUG || SMOKE
import Darwin
import Foundation

/// A test build cannot acquire a writable filesystem scope from a path alone.
/// The launcher creates a private directory and a matching ownership token.
public struct SyntheticRun: Sendable {
    public enum Refusal: Error { case invalidScope, invalidPath, linkedScope, directoryOwnership, ownershipToken }
    public let root: String
    public let home: String
    public let trash: String
    private let token: String
    private let rootID: Identity
    private let homeID: Identity
    private let trashID: Identity
    private struct Identity: Equatable, Sendable {
        let device: Int32
        let inode: UInt64
    }
    public static let marker = ".mymole-synthetic-run.json"

    public init(root: String, token: String) throws {
        let url = URL(fileURLWithPath: root)
        guard UUID(uuidString: token) != nil,
              url.lastPathComponent.hasPrefix("mymole-ui-smoke-"),
              root.hasPrefix("/private/tmp/") || root.hasPrefix("/tmp/") || root.hasPrefix("/private/var/folders/") || root.hasPrefix("/var/folders/"),
              Self.plain(root) else { throw Refusal.invalidPath }
        let systemAlias = root.hasPrefix("/var/") || root.hasPrefix("/tmp/")
        guard Self.canonical(root) == (systemAlias ? "/private" + root : root) else { throw Refusal.linkedScope }
        guard Self.owns(root, token: token) else { throw Refusal.ownershipToken }
        guard let rootID = Self.directory(root),
              let homeID = Self.directory(root + "/home"),
              let trashID = Self.directory(root + "/trash"),
              rootID.device == homeID.device, rootID.device == trashID.device else { throw Refusal.directoryOwnership }
        self.root = root
        self.token = token
        self.home = root + "/home"
        self.trash = root + "/trash"
        self.rootID = rootID
        self.homeID = homeID
        self.trashID = trashID
    }

    public static func environment(_ values: [String: String]) throws -> SyntheticRun {
        guard let root = values["MYMOLE_SMOKE_ROOT"], let token = values["MYMOLE_SMOKE_TOKEN"] else { throw Refusal.invalidScope }
        let run = try SyntheticRun(root: root, token: token)
        guard values["HOME"] == run.home, values["CFFIXED_USER_HOME"] == run.home,
              values["MYMOLE_SMOKE_HOME"] == run.home, values["MYMOLE_SMOKE_TRASH"] == run.trash,
              values["TMPDIR"] == root + "/tmp/" else { throw Refusal.invalidScope }
        return run
    }

    public static func current() throws -> SyntheticRun { try environment(ProcessInfo.processInfo.environment) }

    private static func plain(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.utf8.contains(0) && path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func systemPath(_ path: String) -> String {
        path.hasPrefix("/tmp/") || path.hasPrefix("/var/") ? "/private" + path : path
    }

    private static func canonical(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func directory(_ path: String) -> Identity? {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR,
              st.st_uid == geteuid(), st.st_mode & 0o077 == 0 else { return nil }
        return Identity(device: st.st_dev, inode: st.st_ino)
    }

    private static func owns(_ root: String, token: String) -> Bool {
        let path = root + "/" + marker
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG,
              st.st_uid == geteuid(), st.st_mode & 0o077 == 0, st.st_size < 4096,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return false }
        return value == ["purpose": "mymole-synthetic-run", "token": token]
    }

    private func openRoot() throws -> Int32 {
        guard Self.directory(root) == rootID, Self.owns(root, token: token) else { throw Refusal.invalidScope }
        let fd = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var st = stat()
        guard fd >= 0 else { throw Refusal.invalidScope }
        guard fstat(fd, &st) == 0, Identity(device: st.st_dev, inode: st.st_ino) == rootID else {
            close(fd); throw Refusal.invalidScope
        }
        return fd
    }

    /// Anchored descriptors prevent a parent symlink from redirecting a move.
    /// Only regular files and directories below this run's home are accepted.
    func moving<T>(_ source: String, _ body: (Int32, String, Int32, String) throws -> T) throws -> T {
        let path = Self.systemPath(source), base = Self.systemPath(home)
        guard Self.plain(source), path.hasPrefix(base + "/") else { throw Refusal.invalidScope }
        let pieces = path.dropFirst(base.count + 1).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let name = pieces.last, pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw Refusal.invalidScope }
        let rootFD = try openRoot()
        defer { close(rootFD) }
        func owned(_ name: String, _ id: Identity) throws -> Int32 {
            let fd = openat(rootFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            var st = stat()
            guard fd >= 0 else { throw Refusal.invalidScope }
            guard fstat(fd, &st) == 0, Identity(device: st.st_dev, inode: st.st_ino) == id else { close(fd); throw Refusal.invalidScope }
            return fd
        }
        var parent = try owned("home", homeID)
        defer { close(parent) }
        for part in pieces.dropLast() {
            let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw Refusal.invalidScope }
            close(parent)
            parent = next
        }
        var st = stat()
        guard fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) == 0,
              st.st_dev == rootID.device, [S_IFREG, S_IFDIR].contains(st.st_mode & S_IFMT) else { throw Refusal.invalidScope }
        let destination = try owned("trash", trashID)
        defer { close(destination) }
        return try body(parent, name, destination, UUID().uuidString + "-" + name)
    }
}
#endif
