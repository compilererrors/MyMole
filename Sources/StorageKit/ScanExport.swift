import Foundation

/// A finished scan written to a file of the user's choosing, to look at
/// again later or on another Mac, without the disk it was made of.
///
/// Format "mymole-scan", version 1, JSON: the scanned path, when, and the
/// folders breadth first (biggest first), each with its own small files'
/// count and bytes and its listed files (1 MB or more). At most
/// `entryLimit` entries, and files of at most `byteLimit` are opened. A
/// scan opened from a file is only looked at: it gives no access to the
/// paths it names, and nothing can be chosen or moved from it.
public struct ScanExport: Codable, Sendable {
    public static let format = "mymole-scan"
    public static let version = 1
    public static let entryLimit = 400_000
    public static let byteLimit = 256 << 20

    struct Item: Codable, Sendable {
        /// Name, the folder it's in (position in `items`; -1 for the root),
        /// size, last change (seconds since 1970) and kind (`FileKind` raw value).
        let n: String
        let p: Int32
        let s: Int64
        let m: Double
        let k: Int
        /// A folder: its own small files' count and bytes.
        let c: Int?
        let b: Int64?
    }

    public let format: String
    public let version: Int
    public let rootPath: String
    public let date: Date
    public let truncated: Bool
    let items: [Item]

    public init(of root: Folder, date: Date = .now, limit: Int = ScanExport.entryLimit) {
        format = Self.format
        version = Self.version
        rootPath = root.path
        self.date = date
        var items: [Item] = []
        var cut = false
        var queue: [(Folder, Int32)] = [(root, -1)]
        var head = 0
        while head < queue.count {
            let (f, parent) = queue[head]
            head += 1
            guard items.count < limit else {
                cut = true
                break
            }
            let here = Int32(items.count)
            items.append(Item(
                n: f.name, p: parent, s: f.size, m: f.ownLatestChange.timeIntervalSince1970, k: (f.inheritedKind ?? .other).rawValue,
                c: f.smallFileCount, b: f.smallFileBytes))
            for file in f.listedFiles {
                guard items.count < limit else {
                    cut = true
                    break
                }
                items.append(Item(n: file.name, p: here, s: file.size, m: file.modified.timeIntervalSince1970, k: file.kind.rawValue, c: nil, b: nil))
            }
            for sub in f.subfolders { queue.append((sub, here)) }
        }
        self.items = items
        truncated = cut
    }

    public func data() throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return try e.encode(self)
    }

    public enum Failure: Error, Equatable {
        case tooLarge, notAScan, newerVersion, damaged
    }

    /// Reads a file written by `data()`; anything else is refused.
    public static func read(_ data: Data) throws -> ScanExport {
        guard data.count <= byteLimit else { throw Failure.tooLarge }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        guard let s = try? d.decode(ScanExport.self, from: data), s.format == format else { throw Failure.notAScan }
        guard s.version <= version else { throw Failure.newerVersion }
        guard s.items.count <= entryLimit, let first = s.items.first, first.p == -1, s.rootPath.hasPrefix("/") else { throw Failure.damaged }
        // Every item in a folder that comes before it, and only in a folder.
        for (i, item) in s.items.enumerated().dropFirst() {
            guard item.p >= 0, Int(item.p) < i, s.items[Int(item.p)].c != nil, item.s >= 0,
                !item.n.isEmpty, !item.n.contains("/"), FileKind(rawValue: item.k) != nil
            else { throw Failure.damaged }
        }
        return s
    }

    /// The scan as a tree to look at, with its totals summed again.
    public func tree() -> Folder {
        let root = Folder(name: (rootPath as NSString).lastPathComponent, parent: nil, rootPath: rootPath)
        var folders: [Int: Folder] = [0: root]
        for (i, item) in items.enumerated() {
            let kind = FileKind(rawValue: item.k) ?? .other
            let modified = Date(timeIntervalSince1970: item.m)
            let folder: Folder
            if i == 0 {
                folder = root
            } else if item.c != nil, let parent = folders[Int(item.p)] {
                folder = Folder(name: item.n, parent: parent)
                parent.subfolders.append(folder)
                folders[i] = folder
            } else if let parent = folders[Int(item.p)] {
                parent.listedFiles.append(FileItem(name: item.n, size: item.s, modified: modified, kind: kind))
                parent.ownBytes[kind] += item.s
                parent.latestChange = max(parent.latestChange, modified)
                parent.ownLatestChange = parent.latestChange
                continue
            } else {
                continue
            }
            folder.smallFileCount = item.c ?? 0
            folder.smallFileBytes = item.b ?? 0
            folder.ownBytes[folder.inheritedKind ?? .other] += item.b ?? 0
            folder.latestChange = max(folder.latestChange, modified)
            folder.ownLatestChange = folder.latestChange
        }
        root.finish()
        return root
    }
}
