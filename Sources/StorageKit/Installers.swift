import Darwin
import Foundation

// Installers left behind once their app is in place: disk images, packages
// and Xcode archives in the folders downloads end up in. They're found by
// file type only; MyMole never guesses from names whether one is still
// wanted, so everything found is offered and nothing is chosen for the user.

/// One installer on disk.
public struct InstallerFile: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case diskImage, package, archive

        public var title: String {
            switch self {
            case .diskImage: "Disk Image"
            case .package: "Installer Package"
            case .archive: "Xcode Archive"
            }
        }
    }

    public let path: String
    public let bytes: Int64
    public let modified: Date
    public let kind: Kind
    /// Which file it was at the scan: a folder or not, its volume and its
    /// file number. A file put in its place since has another identity.
    public let isFolder: Bool
    public let device: UInt64
    public let inode: UInt64
    /// A package folder part of which couldn't be read.
    public var incomplete: Bool = false

    public init(
        path: String, bytes: Int64, modified: Date, kind: Kind, isFolder: Bool = false, device: UInt64 = 0,
        inode: UInt64 = 0
    ) {
        self.path = path
        self.bytes = bytes
        self.modified = modified
        self.kind = kind
        self.isFolder = isFolder
        self.device = device
        self.inode = inode
    }

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    public var folder: String { (path as NSString).deletingLastPathComponent }
}

/// A folder searched for installers, and how deep.
public struct InstallerLocation: Sendable, Hashable, Codable {
    public let path: String
    public let depth: Int

    public init(path: String, depth: Int) {
        self.path = Trasher.lexical(path)
        self.depth = depth
    }
}

/// What a search for installers found, and which folders it couldn't read.
public struct InstallerListing: Sendable {
    public var files: [InstallerFile]
    public var unreadable: [String]

    public init(files: [InstallerFile], unreadable: [String] = []) {
        self.files = files
        self.unreadable = unreadable
    }

    /// Every folder and every installer was read whole.
    public var isComplete: Bool { unreadable.isEmpty && !files.contains(where: \.incomplete) }
}

public enum InstallerFinder {
    static let kinds: [String: InstallerFile.Kind] = [
        "dmg": .diskImage, "pkg": .package, "mpkg": .package, "xip": .archive,
    ]

    /// Folders whose insides are never installers lying around: other
    /// tools' data, and version control.
    static let skipped: Set<String> = ["node_modules", "Library", ".git"]

    /// Where downloads and installers usually pile up. Homebrew keeps every
    /// cask's installer in its download cache after installing it.
    public static func defaultLocations(home: String = Home.path) -> [InstallerLocation] {
        [
            InstallerLocation(path: home + "/Downloads", depth: 3),
            InstallerLocation(path: home + "/Desktop", depth: 2),
            InstallerLocation(path: home + "/Documents", depth: 2),
            InstallerLocation(path: home + "/Library/Caches/Homebrew/downloads", depth: 1),
        ]
    }

    public static func kind(of path: String) -> InstallerFile.Kind? {
        kinds[(path as NSString).pathExtension.lowercased()]
    }

    /// Every installer in `locations`, largest first.
    public static func find(in locations: [InstallerLocation], progress: ScanProgress = ScanProgress())
        -> [InstallerFile]
    {
        list(in: locations, progress: progress).files
    }

    /// Every installer in `locations`, largest first, and the folders that
    /// couldn't be read. A cancelled scan returns what it found so far;
    /// check `progress.isCancelled`.
    public static func list(in locations: [InstallerLocation], progress: ScanProgress = ScanProgress()) -> InstallerListing {
        var found: [String: InstallerFile] = [:]
        var unreadable: [String] = []
        for loc in locations {
            walk(loc.path, depthLeft: loc.depth, progress: progress, add: { found[$0.path] = $0 }, denied: { unreadable.append($0) })
        }
        let files = found.values.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
        return InstallerListing(files: files, unreadable: unreadable)
    }

    private static func walk(
        _ dir: String, depthLeft: Int, progress: ScanProgress, add: (InstallerFile) -> Void, denied: (String) -> Void
    ) {
        guard depthLeft > 0, !progress.isCancelled else { return }
        guard let names = DirectoryListing.names(dir) else {
            denied(dir)
            return
        }
        for name in names where !name.hasPrefix(".") && !skipped.contains(name) {
            let path = dir + "/" + name
            var st = stat()
            guard lstat(path, &st) == 0 else { continue }
            let type = st.st_mode & S_IFMT
            if let kind = kind(of: path) {
                // Old-style packages are folders; they count as one installer.
                if type == S_IFREG || type == S_IFDIR, let file = measure(path, kind: kind, stat: st) { add(file) }
            } else if type == S_IFDIR, !isBundle(name) {
                walk(path, depthLeft: depthLeft - 1, progress: progress, add: add, denied: denied)
            }
        }
    }

    /// Apps and other bundles hold their own resources, not downloads.
    static func isBundle(_ name: String) -> Bool {
        ["app", "bundle", "framework", "photoslibrary", "musiclibrary", "xcarchive"]
            .contains((name as NSString).pathExtension.lowercased())
    }

    static func measure(_ path: String, kind: InstallerFile.Kind, stat st: stat) -> InstallerFile? {
        let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
        let dev = UInt64(UInt32(bitPattern: st.st_dev))
        if st.st_mode & S_IFMT == S_IFDIR {
            let r = StorageScanner.scan(path: path, workers: 1)
            var f = InstallerFile(
                path: path, bytes: r.root.size, modified: max(mtime, r.root.latestChange), kind: kind, isFolder: true,
                device: dev, inode: st.st_ino)
            f.incomplete = !r.deniedPaths.isEmpty || r.root.unreadable
            return f
        }
        return InstallerFile(
            path: path, bytes: Int64(st.st_blocks) * 512, modified: mtime, kind: kind, isFolder: false, device: dev,
            inode: st.st_ino)
    }

    /// Checked again right before an installer goes to the Trash: it must
    /// still be an installer inside one of the searched folders, with no
    /// link on the way or at the end.
    public static func isStillInstaller(_ path: String, in locations: [InstallerLocation]) -> Bool {
        let p = path
        guard Trasher.isPlainPath(p), kind(of: p) != nil,
            locations.contains(where: { p.hasPrefix($0.path + "/") && Trasher.noLinksBetween($0.path, and: p) })
        else { return false }
        var st = stat()
        guard lstat(p, &st) == 0 else { return false }
        let type = st.st_mode & S_IFMT
        return type == S_IFREG || type == S_IFDIR
    }

    /// The same check, and still the very file that was found: the same
    /// kind of entry, volume and file number, and the same size. A file or
    /// folder put in its place since the scan isn't moved, and neither is a
    /// package folder whose contents changed.
    public static func isStillInstaller(_ file: InstallerFile, in locations: [InstallerLocation]) -> Bool {
        guard isStillInstaller(file.path, in: locations) else { return false }
        var st = stat()
        guard lstat(file.path, &st) == 0 else { return false }
        let isFolder = st.st_mode & S_IFMT == S_IFDIR
        guard isFolder == file.isFolder, UInt64(UInt32(bitPattern: st.st_dev)) == file.device, st.st_ino == file.inode
        else { return false }
        if isFolder {
            let r = StorageScanner.scan(path: file.path, workers: 1)
            return !r.cancelled && r.deniedPaths.isEmpty && r.root.size == file.bytes
        }
        return Int64(st.st_blocks) * 512 == file.bytes
            && TimeInterval(st.st_mtimespec.tv_sec) == file.modified.timeIntervalSince1970
    }
}

/// The last complete installer scan, so the pane opens on it at once. A
/// result from other locations or an older format is ignored.
public enum InstallerStore {
    /// 3: files carry their identity and completeness; older results are scanned again.
    static let formatVersion = 3

    public struct Saved: Sendable, Codable {
        public let version: Int
        public let date: Date
        public let locations: [InstallerLocation]
        public let files: [InstallerFile]
    }

    public static var defaultBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MyMole/Installers")
    }

    public static func load(for locations: [InstallerLocation], base: URL = defaultBase) -> Saved? {
        guard let d = try? Data(contentsOf: base.appending(path: "last.json")),
            let saved = try? JSONDecoder().decode(Saved.self, from: d),
            saved.version == formatVersion, saved.locations == locations
        else { return nil }
        return saved
    }

    public static func save(
        _ listing: InstallerListing, locations: [InstallerLocation], date: Date = Date(), base: URL = defaultBase
    ) {
        // Only a scan that read everything replaces the saved one.
        guard listing.isComplete else { return }
        let saved = Saved(version: formatVersion, date: date, locations: locations, files: listing.files)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(saved) { try? d.write(to: base.appending(path: "last.json"), options: .atomic) }
    }
}
