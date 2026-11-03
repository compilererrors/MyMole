import Darwin
import Foundation

/// Removal as root that a folder swapped mid-way can't redirect. Each
/// folder is opened once, without following a link, and everything inside
/// it is removed relative to that open folder, so renaming a folder or
/// putting a link in its place sends nothing elsewhere. Removal never
/// leaves the volume it started on.
enum SecureRemove {
    /// Deeper than any cache: a tree past this is left, not chased.
    static let maxDepth = 256

    /// Removes the file or folder at `path`. False when anything in it
    /// stayed; what could go is gone either way.
    static func removeTree(_ path: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        let fd = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return false }
        return remove(name, in: fd, device: st.st_dev, depth: 0)
    }

    private static func remove(_ name: String, in dir: Int32, device: dev_t, depth: Int) -> Bool {
        var st = stat()
        guard fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return errno == ENOENT }
        guard st.st_mode & S_IFMT == S_IFDIR else { return unlinkat(dir, name, 0) == 0 || errno == ENOENT }
        guard st.st_dev == device, depth < maxDepth else { return false }
        let fd = openat(dir, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        // The folder opened must be the one looked at, not one put there since.
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_ino == st.st_ino, opened.st_dev == st.st_dev else {
            close(fd)
            return false
        }
        var ok = true
        for child in entries(fd) { ok = remove(child, in: fd, device: device, depth: depth + 1) && ok }
        close(fd)
        return ok && (unlinkat(dir, name, AT_REMOVEDIR) == 0 || errno == ENOENT)
    }

    /// The names in an open folder, read before anything in it is removed.
    private static func entries(_ fd: Int32) -> [String] {
        let own = dup(fd)
        guard own >= 0, let dir = fdopendir(own) else { return [] }
        defer { closedir(dir) }
        var names: [String] = []
        while let e = readdir(dir) {
            let name = withUnsafePointer(to: &e.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }
}
