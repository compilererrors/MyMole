import CryptoKit
import Darwin
import Foundation
import Synchronization

/// One copy of a file that has others.
public struct DuplicateFile: Sendable, Hashable, Identifiable {
    public let path: String
    /// When it last changed, to the nanosecond the disk keeps.
    public let modified: Date
    let inode: UInt64
    /// The volume it's on: an inode number names a file only within one.
    var device: Int32 = 0
    /// Its APFS clone family; nil where the volume can't say, which counts
    /// as a family of its own.
    public var cloneID: UInt64? = nil

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    public var folder: String { (path as NSString).deletingLastPathComponent }
}

/// Files with the same content, byte for byte.
public struct DuplicateGroup: Sendable, Hashable, Identifiable {
    /// The files' length, the same for all of them.
    public let length: Int64
    /// What one copy takes on disk.
    public let bytes: Int64
    public let digest: String
    /// Two or more, oldest first.
    public var files: [DuplicateFile]

    public var id: String { digest }
    /// What goes when all but one copy do. Clones of one another share
    /// their blocks, so each clone family takes the space of one copy.
    public var spare: Int64 { bytes * Int64(max(0, families.count - 1)) }

    private struct CloneFamily: Hashable {
        let device: Int32
        let id: UInt64
    }

    /// The copies by clone family; a copy the volume can't place is alone.
    var families: [[DuplicateFile]] {
        var byID: [CloneFamily: [DuplicateFile]] = [:]
        var alone: [[DuplicateFile]] = []
        for f in files {
            if let id = f.cloneID {
                byID[CloneFamily(device: f.device, id: id), default: []].append(f)
            } else { alone.append([f]) }
        }
        return Array(byID.values) + alone
    }

    /// The other copies that share `path`'s blocks.
    public func clones(of path: String) -> Int {
        guard let file = files.first(where: { $0.path == path }), let id = file.cloneID else { return 0 }
        return files.filter { $0.device == file.device && $0.cloneID == id && $0.path != path }.count
    }

    /// What moving the copies in `going` frees, by path: a family's space is
    /// freed once all of it goes, and counted on its last copy in `going`.
    public func freed(going: Set<String>) -> [String: Int64] {
        var out: [String: Int64] = [:]
        for family in families {
            let leaving = family.filter { going.contains($0.path) }.map(\.path).sorted()
            guard !leaving.isEmpty else { continue }
            for p in leaving { out[p] = 0 }
            if leaving.count == family.count, let last = leaving.last { out[last] = bytes }
        }
        return out
    }
}

public struct DuplicateListing: Sendable {
    public var groups: [DuplicateGroup]
    /// Folders that are there but couldn't be read.
    public var unreadable: [String]
    /// Files that couldn't be read through, or changed while they were
    /// compared: whether they have copies isn't known.
    public var uncompared: Int
    /// Explicitly requested roots excluded by the library/project safety policy.
    public var excluded: [String]

    public init(groups: [DuplicateGroup], unreadable: [String] = [], uncompared: Int = 0, excluded: [String] = []) {
        self.groups = groups
        self.unreadable = unreadable
        self.uncompared = uncompared
        self.excluded = excluded
    }
}

/// How far a search for duplicates has come.
public struct DuplicateStep: Sendable, Equatable {
    public enum Phase: Sendable { case waiting, listing, comparing }

    public let phase: Phase
    /// Files looked at while listing; files compared of all to compare after.
    public let done: Int
    public let total: Int

    public init(phase: Phase, done: Int, total: Int) {
        self.phase = phase
        self.done = done
        self.total = total
    }
}

/// Finds files with the same content in the user's own folders. Files are
/// only read; nothing is changed.
///
/// A file can only equal another of the same length, so lengths are
/// compared first, then the start and end of each file, and only what still
/// matches is read whole and compared by SHA-256.
///
/// Left out on purpose: links (never followed), hidden files and folders,
/// packages such as apps and photo libraries, Git repositories and
/// dependency folders (their copies are meant to be there), cloud files
/// that aren't downloaded (reading them would fetch them), and files below
/// the minimum size. Several names of one file (hard links) count as one.
public enum DuplicateFinder {
    public static let standardMinimum: Int64 = 1_048_576
    /// How much of each end is compared before a file is read whole.
    static let sample = 64 * 1024
    static let chunk = 1 << 20

    /// Folders that are one thing, not a place to look inside.
    static let packages: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext", "xcodeproj", "xcworkspace", "playground", "xcarchive",
        "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle", "logicx", "band", "aplibrary",
        "sparsebundle", "rtfd", "pages", "numbers", "key", "lproj", "pkg", "mpkg", "download",
    ]
    /// Folders tools fill with copies on purpose.
    static let toolFolders: Set<String> = ["node_modules", "pods", "deriveddata", "bower_components", "__pycache__", "venv", "site-packages", "vendor"]

    /// Requested document folders, resolved without disk reads. Access may
    /// be granted after model initialization; missing folders are skipped by the walk.
    public static func standardRoots(home: String) -> [String] {
        ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"].map { home + "/" + $0 }
    }

    struct Found {
        let path: String
        let length: Int64
        let bytes: Int64
        let modified: Date
        let inode: UInt64
        var device: Int32 = 0
    }

    /// A file's last change with the nanoseconds the disk keeps, so a file
    /// rewritten within the same second doesn't pass for unchanged.
    static func changed(_ st: stat) -> Date {
        Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000)
    }

    public static func find(
        in roots: [String], minimum: Int64 = standardMinimum, progress: ScanProgress = ScanProgress(), workers: Int = 4,
        onStep: (@Sendable (DuplicateStep) -> Void)? = nil
    ) -> DuplicateListing {
        find(in: roots, minimum: minimum, progress: progress, workers: workers, onGroup: nil, onStep: onStep)
    }

    public static func find(
        in roots: [String], minimum: Int64 = standardMinimum, progress: ScanProgress = ScanProgress(), workers: Int = 4,
        onGroup: (@Sendable (DuplicateGroup) -> Void)?, onStep: (@Sendable (DuplicateStep) -> Void)?
    ) -> DuplicateListing {
        var unreadable: [String] = []
        var excluded: [String] = []
        var seen = Set<FileID>()
        var bySize: [Int64: [Found]] = [:]
        var looked = 0
        onStep?(DuplicateStep(phase: .listing, done: 0, total: 0))
        // A root inside another is walked once, as part of it.
        let outer = Trasher.outermost(roots.filter(Trasher.isPlainPath))
        for root in outer where !progress.isCancelled {
            guard !excludedRoot(root) else { excluded.append(root); continue }
            walk(root, minimum: minimum, progress: progress, seen: &seen, unreadable: &unreadable) { f in
                bySize[f.length, default: []].append(f)
                looked += 1
                if looked % 2_000 == 0 { onStep?(DuplicateStep(phase: .listing, done: looked, total: 0)) }
            }
            onStep?(DuplicateStep(phase: .listing, done: looked, total: 0))
        }
        guard !progress.isCancelled else { return DuplicateListing(groups: [], unreadable: unreadable.sorted(), excluded: excluded.sorted()) }
        let sameLength = bySize.values.filter { $0.count > 1 }
        let total = sameLength.reduce(0) { $0 + $1.count }
        onStep?(DuplicateStep(phase: .comparing, done: 0, total: total))
        let counter = Atomic<Int>(0)
        let missed = Atomic<Int>(0)
        let groups = Mutex<[DuplicateGroup]>([])
        let next = Atomic<Int>(0)
        DispatchQueue.concurrentPerform(iterations: max(1, min(workers, 8))) { _ in
            while !progress.isCancelled {
                let i = next.add(1, ordering: .relaxed).oldValue
                guard i < sameLength.count else { return }
                let made = compare(sameLength[i], progress: progress, missed: { missed.add(1, ordering: .relaxed) }, onGroup: onGroup) {
                    let done = counter.add(1, ordering: .relaxed).newValue
                    onStep?(DuplicateStep(phase: .comparing, done: min(done, total), total: total))
                }
                if !made.isEmpty { groups.withLock { $0 += made } }
            }
        }
        let sorted = groups.withLock { $0 }.sorted { $0.spare != $1.spare ? $0.spare > $1.spare : $0.digest < $1.digest }
        return DuplicateListing(groups: sorted, unreadable: unreadable.sorted(), uncompared: missed.load(ordering: .relaxed), excluded: excluded.sorted())
    }

    struct FileID: Hashable {
        let device: Int32
        let inode: UInt64
    }

    /// An explicitly chosen root must obey the same exclusions as a child.
    /// Choosing a subfolder mustn't bypass a library, dependency or repository boundary.
    private static func excludedRoot(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        if components.contains(where: {
            $0.hasPrefix(".") || packages.contains(($0 as NSString).pathExtension.lowercased()) || toolFolders.contains($0.lowercased())
        }) { return true }
        var directory = path
        while directory != "/", !directory.isEmpty {
            var st = stat()
            if lstat(directory + "/.git", &st) == 0 { return true }
            directory = (directory as NSString).deletingLastPathComponent
        }
        return false
    }

    /// Every file worth comparing under `root`, depth first, without
    /// following a link. `seen` holds the files met so far, so a second
    /// name of the same file is passed over.
    static func walk(
        _ root: String, minimum: Int64, progress: ScanProgress, seen: inout Set<FileID>, unreadable: inout [String],
        _ found: (Found) -> Void
    ) {
        var stack = [root]
        while let dir = stack.popLast(), !progress.isCancelled {
            var st = stat()
            guard lstat(dir, &st) == 0 else {
                if errno != ENOENT && errno != ENOTDIR { unreadable.append(dir) }
                continue
            }
            guard st.st_mode & S_IFMT == S_IFDIR else { unreadable.append(dir); continue }
            guard let opened = Trasher.openFolder(dir, creating: false) else {
                unreadable.append(dir)
                continue
            }
            guard let d = fdopendir(opened) else {
                close(opened)
                unreadable.append(dir)
                continue
            }
            defer { closedir(d) }
            let fd = dirfd(d)
            // A folder that's a Git repository holds copies that belong there.
            if fstatat(fd, ".git", &st, AT_SYMLINK_NOFOLLOW) == 0 { continue }
            while !progress.isCancelled {
                errno = 0
                guard let e = readdir(d) else {
                    if errno != 0 { unreadable.append(dir) }
                    break
                }
                let name = withUnsafePointer(to: &e.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
                }
                guard !name.hasPrefix(".") else { continue }
                guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
                    unreadable.append(dir + "/" + name)
                    continue
                }
                switch st.st_mode & S_IFMT {
                case S_IFDIR:
                    let ext = (name as NSString).pathExtension.lowercased()
                    if !packages.contains(ext), !toolFolders.contains(name.lowercased()) { stack.append(dir + "/" + name) }
                case S_IFREG:
                    // Not downloaded: its content is in the cloud, and reading it would fetch it.
                    guard st.st_size >= minimum, st.st_flags & UInt32(SF_DATALESS) == 0,
                        seen.insert(FileID(device: st.st_dev, inode: UInt64(st.st_ino))).inserted
                    else { continue }
                    found(Found(
                        path: dir + "/" + name, length: Int64(st.st_size), bytes: Int64(st.st_blocks) * 512,
                        modified: changed(st), inode: UInt64(st.st_ino), device: st.st_dev))
                default: continue
                }
            }
        }
    }

    /// The groups of identical files among files of one length. Files are
    /// first told apart by a 32-byte fingerprint of their two ends, so
    /// memory stays at that much a file however many share a length; the
    /// full SHA-256 decides. `counted` is called once a file is settled:
    /// unlike every other, or read whole.
    static func compare(
        _ files: [Found], progress: ScanProgress, missed: () -> Void = {}, onGroup: ((DuplicateGroup) -> Void)? = nil, counted: () -> Void
    ) -> [DuplicateGroup] {
        var bySample: [SHA256.Digest: [Found]] = [:]
        var buffer = [UInt8](repeating: 0, count: sample)
        for f in files {
            guard !progress.isCancelled else { return [] }
            guard let s = fingerprint(f, buffer: &buffer) else {
                missed()
                counted()
                continue
            }
            bySample[s, default: []].append(f)
        }
        for candidates in bySample.values where candidates.count == 1 { counted() }
        var out: [DuplicateGroup] = []
        // One bounded scratch buffer for the whole size group, allocated
        // only if full comparison is needed. Small files don't need 1 MiB each.
        var contents: [UInt8] = []
        for candidates in bySample.values where candidates.count > 1 {
            var byDigest: [String: [Found]] = [:]
            for f in candidates {
                guard !progress.isCancelled else { return [] }
                defer { counted() }
                if contents.isEmpty { contents = readBuffer(for: f) }
                guard let d = digest(f, progress: progress, buffer: &contents) else {
                    if !progress.isCancelled { missed() }
                    continue
                }
                byDigest[d, default: []].append(f)
            }
            for (d, same) in byDigest where same.count > 1 {
                let ordered = same.sorted { $0.modified != $1.modified ? $0.modified < $1.modified : $0.path < $1.path }
                let group = DuplicateGroup(
                    length: ordered[0].length, bytes: ordered.map(\.bytes).min() ?? 0, digest: d,
                    files: ordered.map {
                        DuplicateFile(path: $0.path, modified: $0.modified, inode: $0.inode, device: $0.device, cloneID: FileSpace.cloneID($0.path))
                    })
                out.append(group)
                onGroup?(group)
            }
        }
        return out
    }

    /// Opens a file to read, never through a link, and only while it is
    /// still the file that was listed: the same volume, file number, length
    /// and last change.
    private static func open(_ f: Found) -> Int32? {
        guard let parent = Trasher.openFolder((f.path as NSString).deletingLastPathComponent, creating: false) else { return nil }
        let fd = openat(parent, (f.path as NSString).lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        close(parent)
        guard fd >= 0 else { return nil }
        guard isListed(fd, f) else {
            close(fd)
            return nil
        }
        // Read once, front to back: no need to keep it in the file cache.
        _ = fcntl(fd, F_NOCACHE, 1)
        return fd
    }

    /// The open file is the one listed as `f`, as it was then.
    private static func isListed(_ fd: Int32, _ f: Found) -> Bool {
        var st = stat()
        return fstat(fd, &st) == 0 && st.st_mode & S_IFMT == S_IFREG && Int64(st.st_size) == f.length
            && UInt64(st.st_ino) == f.inode && st.st_dev == f.device && changed(st) == f.modified
    }

    /// A fingerprint of the first and last `sample` bytes; nil when the
    /// file can't be read or isn't the one listed any more.
    static func fingerprint(_ f: Found, buffer: inout [UInt8]) -> SHA256.Digest? {
        guard let fd = open(f) else { return nil }
        defer { close(fd) }
        var hash = SHA256()
        for offset in Set([0, max(0, f.length - Int64(sample))]).sorted() {
            let n = pread(fd, &buffer, sample, off_t(offset))
            guard n >= 0 else { return nil }
            buffer.withUnsafeBytes { hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<n])) }
        }
        return isListed(fd, f) ? hash.finalize() : nil
    }

    /// SHA-256 of the whole file; nil when it can't be read to its end,
    /// changed while it was read, or the search was stopped.
    static func digest(_ f: Found, progress: ScanProgress = ScanProgress()) -> String? {
        var buffer = readBuffer(for: f)
        return digest(f, progress: progress, buffer: &buffer)
    }

    private static func readBuffer(for file: Found) -> [UInt8] {
        [UInt8](repeating: 0, count: Int(max(1, min(Int64(chunk), file.length))))
    }

    private static func digest(_ f: Found, progress: ScanProgress, buffer: inout [UInt8]) -> String? {
        guard let fd = open(f) else { return nil }
        defer { close(fd) }
        var hash = SHA256()
        var read: Int64 = 0
        while read < f.length {
            guard !progress.isCancelled else { return nil }
            let n = Darwin.read(fd, &buffer, buffer.count)
            guard n > 0 else { return nil }
            buffer.withUnsafeBytes { hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<n])) }
            read += Int64(n)
        }
        // Rewritten while it was read: what was hashed isn't what's there.
        guard isListed(fd, f) else { return nil }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Whether the file at `path` is still the one that was compared: the
    /// same plain file, of that length, last changed when it was.
    public static func isUnchanged(_ file: DuplicateFile, length: Int64) -> Bool {
        var st = stat()
        return lstat(file.path, &st) == 0 && st.st_mode & S_IFMT == S_IFREG && Int64(st.st_size) == length
            && UInt64(st.st_ino) == file.inode && (file.device == 0 || st.st_dev == file.device) && changed(st) == file.modified
    }

    /// Checked again right before a copy goes to the Trash: it's unchanged,
    /// has no link on its way, and at least one copy that isn't going is
    /// still there and unchanged. A group never loses its last copy.
    public static func mayGo(_ path: String, of group: DuplicateGroup, going: Set<String>, home: String = Home.path) -> Bool {
        guard Trasher.isPlainPath(path), !Trasher.isProtected(path, home: home), Trasher.noLinksBetween(home, and: path),
            let file = group.files.first(where: { $0.path == path }), isUnchanged(file, length: group.length)
        else { return false }
        // The copy that stays must be reached the same way: no link on its way either.
        return group.files.contains {
            !going.contains($0.path) && isUnchanged($0, length: group.length)
                && (!$0.path.hasPrefix(home + "/") || Trasher.noLinksBetween(home, and: $0.path))
        }
    }
}
