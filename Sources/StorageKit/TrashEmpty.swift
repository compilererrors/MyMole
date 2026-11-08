import Darwin
import Foundation

/// Emptying the Trash: the one place MyMole deletes a user's files for
/// good, and only what already lies in the Trash.
///
/// The Trash is listed first, for the confirmation, and exactly the listed
/// items are removed: one that was replaced since is left, and so is one
/// that arrived since. The folder is opened once, without following a
/// link, and everything goes relative to that open folder, so a folder
/// renamed or a link put in its place mid-way sends nothing elsewhere.
/// Removal never leaves the volume the Trash is on, and never follows a
/// link out of it: a link is removed, not what it points to.
public enum TrashEmptier {
    /// Deeper than anything a tool writes: a tree past this is left.
    static let maxDepth = 256
    /// Finder's own record of where the items came from, which stays.
    static let kept: Set<String> = [".DS_Store"]

    /// One item at the top of the Trash, as it was when listed.
    public struct Entry: Sendable, Hashable {
        public let name: String
        public let bytes: Int64
        let inode: UInt64
        let device: Int32
        /// Part of it couldn't be opened to measure: `bytes` is a lower bound.
        public var partial = false
    }

    public struct Listing: Sendable, Equatable {
        public let folder: String
        public let entries: [Entry]

        public var count: Int { entries.count }
        public var bytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }
        /// Some of it couldn't be measured in full: the size is at least `bytes`.
        public var partial: Bool { entries.contains(where: \.partial) }
    }

    public struct Outcome: Sendable, Equatable {
        /// Items gone in full, and what they took.
        public var removed = 0
        public var bytes: Int64 = 0
        /// Items of which something stayed: locked, or not the user's to remove.
        public var failed = 0
        /// Items left alone: replaced since they were listed, or not reached before a stop.
        public var skipped = 0
        /// Items a stop came inside of: part of each went, the rest is still in the Trash.
        public var partly = 0

        public init(removed: Int = 0, bytes: Int64 = 0, failed: Int = 0, skipped: Int = 0) {
            self.removed = removed
            self.bytes = bytes
            self.failed = failed
            self.skipped = skipped
        }
    }

    /// What lies in the Trash at `folder`, measured. nil when it can't be
    /// read, isn't a folder of the user's own, or is a link.
    public static func list(_ folder: String) -> Listing? {
        guard let fd = openTrash(folder) else { return nil }
        defer { close(fd.fd) }
        var entries: [Entry] = []
        for name in names(fd.fd) where !kept.contains(name) {
            var st = stat()
            guard fstatat(fd.fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            var whole = true
            let bytes = measure(name, in: fd.fd, st, device: fd.device, depth: 0, whole: &whole)
            entries.append(Entry(name: name, bytes: bytes, inode: UInt64(st.st_ino), device: st.st_dev, partial: !whole))
        }
        return Listing(folder: folder, entries: entries.sorted { $0.name < $1.name })
    }

    /// Removes the listed items for good. `stop` is asked before each item;
    /// the ones not reached stay.
    public static func empty(_ listing: Listing, stop: () -> Bool = { false }) -> Outcome {
        var out = Outcome()
        guard let fd = openTrash(listing.folder) else {
            out.failed = listing.count
            return out
        }
        defer { close(fd.fd) }
        for (i, entry) in listing.entries.enumerated() {
            if stop() {
                out.skipped += listing.count - i
                break
            }
            var st = stat()
            // Gone already, or something else by that name now: not what was confirmed.
            guard !kept.contains(entry.name), fstatat(fd.fd, entry.name, &st, AT_SYMLINK_NOFOLLOW) == 0,
                UInt64(st.st_ino) == entry.inode, st.st_dev == entry.device
            else {
                out.skipped += 1
                continue
            }
            if remove(entry.name, in: fd.fd, device: fd.device, depth: 0, stop: stop) {
                out.removed += 1
                out.bytes += entry.bytes
            } else if stop() {
                // Stopped inside it: nothing more is started, and what's left stays.
                out.partly += 1
                out.skipped += listing.count - i - 1
                break
            } else {
                out.failed += 1
            }
        }
        return out
    }

    /// The Trash folder, opened without following a link: a real folder that
    /// belongs to the user.
    private static func openTrash(_ folder: String) -> (fd: Int32, device: dev_t)? {
        guard Trasher.isPlainPath(folder) else { return nil }
        let fd = open(folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid() else {
            close(fd)
            return nil
        }
        return (fd, st.st_dev)
    }

    /// What `name` takes; `whole` turns false when part of it couldn't be
    /// opened or read, so the size is a lower bound.
    private static func measure(_ name: String, in dir: Int32, _ st: stat, device: dev_t, depth: Int, whole: inout Bool) -> Int64 {
        let own = Int64(st.st_blocks) * 512
        guard st.st_mode & S_IFMT == S_IFDIR, st.st_dev == device else { return own }
        guard depth < maxDepth else {
            whole = false
            return own
        }
        let fd = openat(dir, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            whole = false
            return own
        }
        defer { close(fd) }
        var total = own
        guard let children = readNames(fd) else {
            whole = false
            return own
        }
        for child in children {
            var c = stat()
            if fstatat(fd, child, &c, AT_SYMLINK_NOFOLLOW) == 0 {
                total += measure(child, in: fd, c, device: device, depth: depth + 1, whole: &whole)
            } else if errno != ENOENT {
                whole = false
            }
        }
        return total
    }

    /// Removes `name` from the open folder `dir`, with everything in it.
    /// False when anything stayed; what could go is gone either way.
    private static func remove(_ name: String, in dir: Int32, device: dev_t, depth: Int, stop: () -> Bool = { false }) -> Bool {
        var st = stat()
        guard fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return errno == ENOENT }
        guard st.st_mode & S_IFMT == S_IFDIR else { return unlinkat(dir, name, 0) == 0 || errno == ENOENT }
        guard st.st_dev == device, depth < maxDepth else { return false }
        // A folder a tool left read-only (a module cache) is opened up
        // first: it's in the Trash and the user's own.
        if st.st_uid == getuid(), st.st_mode & S_IRWXU != S_IRWXU {
            _ = fchmodat(dir, name, (st.st_mode & 0o7777) | S_IRWXU, AT_SYMLINK_NOFOLLOW)
        }
        let fd = openat(dir, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        // The folder opened must be the one looked at, not one put there since.
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_ino == st.st_ino, opened.st_dev == st.st_dev else {
            close(fd)
            return false
        }
        var ok = true
        for child in names(fd) {
            // A stop is honoured inside a big folder too, before the next item in it.
            if stop() {
                ok = false
                break
            }
            ok = remove(child, in: fd, device: device, depth: depth + 1, stop: stop) && ok
        }
        close(fd)
        return ok && (unlinkat(dir, name, AT_REMOVEDIR) == 0 || errno == ENOENT)
    }

    /// The names in an open folder, read before anything in it is touched.
    private static func names(_ fd: Int32) -> [String] { readNames(fd) ?? [] }

    /// The names in an open folder; nil when it can't be listed.
    private static func readNames(_ fd: Int32) -> [String]? {
        let own = dup(fd)
        guard own >= 0, let dir = fdopendir(own) else {
            if own >= 0 { close(own) }
            return nil
        }
        defer { closedir(dir) }
        var out: [String] = []
        while let e = readdir(dir) {
            let name = withUnsafePointer(to: &e.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if name != "." && name != ".." { out.append(name) }
        }
        return out
    }
}

extension TrashEmptier {
    /// The user's Trash on another disk: `<disk>/.Trashes/<user ID>`.
    public struct VolumeTrash: Sendable, Equatable {
        public let volume: String
        public let name: String
        public let count: Int
        public let bytes: Int64
        public let partial: Bool
    }

    /// What's in the user's Trash on each of `volumes` (other than the
    /// startup disk), measured only. Emptying them is left to Finder: each
    /// disk has its own owners and mounts, which MyMole doesn't decide on.
    public static func otherTrashes(on volumes: [(path: String, name: String)], uid: uid_t = getuid()) -> [VolumeTrash] {
        volumes.compactMap { v in
            guard v.path != "/", let l = list(v.path + "/.Trashes/\(uid)"), l.count > 0 else { return nil }
            return VolumeTrash(volume: v.path, name: v.name, count: l.count, bytes: l.bytes, partial: l.partial)
        }
    }
}
