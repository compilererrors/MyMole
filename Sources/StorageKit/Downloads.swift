import Darwin
import Foundation

/// Every file in the Downloads folder, small ones too, oldest first: for a
/// look through what piled up. Read only, and nothing is judged junk by
/// its age; packages and folders an app keeps whole count as one item.
public enum DownloadsReview {
    public struct Item: Sendable, Hashable, Identifiable {
        public let path: String
        public let bytes: Int64
        public let modified: Date
        public let kind: FileKind
        public let isFolder: Bool
        public var id: String { path }
        public var name: String { (path as NSString).lastPathComponent }
    }

    /// At most this many items are read.
    public static let limit = 20_000

    /// What's in `folder` down to `depth` levels: files, and packages
    /// (.app, .pkg bundles …) as one; oldest first. `truncated` when more
    /// were there than `limit`.
    public static func list(_ folder: String, depth: Int = 3, progress: ScanProgress = ScanProgress()) -> (items: [Item], truncated: Bool) {
        var out: [Item] = []
        var stack: [(String, Int)] = [(folder, 0)]
        var cut = false
        while let (dir, level) = stack.popLast(), !progress.isCancelled {
            for name in DirectoryListing.names(dir) ?? [] where !name.hasPrefix(".") {
                guard out.count < limit else {
                    cut = true
                    break
                }
                let path = dir + "/" + name
                var st = stat()
                guard lstat(path, &st) == 0 else { continue }
                let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
                switch st.st_mode & S_IFMT {
                case S_IFREG:
                    out.append(Item(path: path, bytes: Int64(st.st_blocks) * 512, modified: modified, kind: Classifier.kind(ofFile: name), isFolder: false))
                case S_IFDIR:
                    if DuplicateFinder.packages.contains((name as NSString).pathExtension.lowercased()) {
                        out.append(Item(path: path, bytes: AppLeftovers.measure(path) ?? 0, modified: modified, kind: Classifier.kind(ofFile: name), isFolder: true))
                    } else if level + 1 < depth {
                        stack.append((path, level + 1))
                    }
                default: continue
                }
            }
        }
        return (out.sorted { $0.modified != $1.modified ? $0.modified < $1.modified : $0.path < $1.path }, cut)
    }
}
