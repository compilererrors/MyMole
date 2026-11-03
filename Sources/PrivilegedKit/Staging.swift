import Darwin
import Foundation

/// Where one removal job parks entries before deleting them. Each job gets
/// its own folder inside a root's `.mymole-removing`, only this user may
/// enter it, and an entry's original place is written down before the
/// entry moves. A job only ever deletes what it staged itself: anything an
/// earlier job left behind stays, with its note, for a person to look at.
struct Staging {
    /// One removal at a time in this process: System Clean and system
    /// uninstall share the staging folders.
    static let lock = NSLock()

    static let containerName = ".mymole-removing"
    static let noteSuffix = ".origin"

    let job = UUID().uuidString
    private var folders: [String: String] = [:]

    /// This job's folder in `root`, created on first use. Nil when the
    /// container isn't a private folder of this user's, so nothing is moved
    /// where others could reach it.
    mutating func folder(in root: String) -> String? {
        if let f = folders[root] { return f }
        let container = root + "/" + Self.containerName
        if mkdir(container, 0o700) != 0 && errno != EEXIST { return nil }
        guard Self.isPrivateFolder(container) else { return nil }
        let dir = container + "/" + job
        guard mkdir(dir, 0o700) == 0, Self.isPrivateFolder(dir) else { return nil }
        folders[root] = dir
        return dir
    }

    static func isPrivateFolder(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR && st.st_uid == geteuid() && st.st_mode & 0o077 == 0
    }

    /// Moves `path` into `dir` after noting where it came from.
    func stage(_ path: String, in dir: String) -> Result<String, StagingError> {
        let name = UUID().uuidString
        let note = dir + "/" + name + Self.noteSuffix
        guard FileManager.default.createFile(atPath: note, contents: Data(path.utf8), attributes: [.posixPermissions: 0o600])
        else { return .failure(.message("Its removal couldn't be recorded, so it wasn't moved.")) }
        let staged = dir + "/" + name
        guard renamex_np(path, staged, UInt32(RENAME_EXCL)) == 0 else {
            let why = String(cString: strerror(errno))
            unlink(note)
            return .failure(.message(why))
        }
        return .success(staged)
    }

    /// The entry is gone; its note goes too.
    func done(_ staged: String) {
        unlink(staged + Self.noteSuffix)
    }

    /// After a removal stopped part-way: what's left goes back where it
    /// came from, unless something new is there already, which is never
    /// overwritten. Returns where the remainder is now.
    func putBack(_ staged: String, to original: String) -> String {
        if renamex_np(staged, original, UInt32(RENAME_EXCL)) == 0 {
            done(staged)
            return original
        }
        return staged
    }

    /// Removes this job's folders that ended up empty. A folder still
    /// holding something (a remainder and its note) stays.
    func finish() {
        for dir in folders.values {
            rmdir(dir)
            rmdir((dir as NSString).deletingLastPathComponent)
        }
    }
}

enum StagingError: Error {
    case message(String)

    var text: String {
        switch self {
        case .message(let s): s
        }
    }
}

/// Runs one staged, permanent removal of `path`: moved aside first, checked
/// again where it landed, deleted there. On a partial failure the remainder
/// is put back, or its place is reported so it can be found.
func removeStaged(
    _ path: String, staging: inout Staging, recheck: (String) -> Bool, size: (String) -> Int64,
    beforeDelete: (String) -> Void = { _ in }, report: inout RemovalReport
) {
    let parent = (path as NSString).deletingLastPathComponent
    guard let dir = staging.folder(in: parent) else {
        report.failed[path] = "No safe place to remove it from."
        return
    }
    let staged: String
    switch staging.stage(path, in: dir) {
    case .success(let s): staged = s
    case .failure(let e):
        report.failed[path] = e.text
        return
    }
    // What was moved is what gets checked and removed.
    guard recheck(staged) else {
        if staging.putBack(staged, to: path) == path {
            report.refused.append(path)
        } else {
            report.failed[path] = "It changed while being removed and is kept at \(staged)."
        }
        return
    }
    beforeDelete(staged)
    let bytes = size(staged)
    if SecureRemove.removeTree(staged) {
        staging.done(staged)
        report.removed.append(path)
        report.bytes += bytes
    } else {
        let left = staging.putBack(staged, to: path)
        report.failed[path] = left == path
            ? "Part of it couldn't be removed; what was left is back in place."
            : "Part of it couldn't be removed; what was left is kept at \(left)."
    }
}
