import Darwin
import Foundation

/// One nonrecursive read for an explicit choice of a folder's entire contents.
/// Hidden and small entries are included; links are never followed.
public enum FolderContents {
    public struct Item: Sendable, Hashable {
        public let path: String
        public let bytes: Int64
        public let isFolder: Bool
        private let device: Int32
        private let fileID: UInt64
        private let type: mode_t
        private let parentDevice: Int32
        private let parentID: UInt64

        public var isCurrent: Bool {
            guard let current = Trasher.identity(of: path),
                  let parent = Trasher.identity(of: (path as NSString).deletingLastPathComponent) else { return false }
            return current.device == device && current.inode == fileID && current.type == type
                && parent.type == S_IFDIR && parent.device == parentDevice && parent.inode == parentID
        }

        fileprivate init(path: String, bytes: Int64, identity: Trasher.Identity, parent: Trasher.Identity) {
            self.path = path
            self.bytes = bytes
            isFolder = identity.type == S_IFDIR
            device = identity.device
            fileID = identity.inode
            type = identity.type
            parentDevice = parent.device
            parentID = parent.inode
        }
    }

    /// Lightweight evidence before an accepted move waits for a scan or queue.
    public static func capture(_ path: String) -> Item? {
        guard let identity = Trasher.identity(of: path), [S_IFDIR, S_IFREG, S_IFLNK].contains(identity.type),
              let parent = Trasher.identity(of: (path as NSString).deletingLastPathComponent), parent.type == S_IFDIR else { return nil }
        return Item(path: path, bytes: 0, identity: identity, parent: parent)
    }

    /// Items read at the standard result size.
    public static let standardLimit = 100_000

    public static func read(_ path: String, progress: ScanProgress = ScanProgress(), limit: Int = standardLimit) -> [Item]? {
        var items: [Item] = []
        var truncated = false
        var unsupported = false
        guard let parent = Trasher.identity(of: path), parent.type == S_IFDIR else { return nil }
        let outcome = DirectoryReader.read(path, isCancelled: { progress.isCancelled || truncated }) { entry in
            guard items.count < limit else { truncated = true; return }
            guard entry.kind == .file || entry.kind == .folder || entry.kind == .symlink else { unsupported = true; return }
            let type: mode_t = entry.kind == .folder ? S_IFDIR : entry.kind == .symlink ? S_IFLNK : S_IFREG
            let identity = Trasher.Identity(type: type, device: entry.device, inode: entry.fileID)
            items.append(Item(path: (path == "/" ? "" : path) + "/" + entry.name, bytes: entry.allocated, identity: identity, parent: parent))
        }
        guard outcome == .ok, !truncated, !unsupported, !progress.isCancelled, Trasher.identity(of: path) == parent else { return nil }
        return items
    }
}
