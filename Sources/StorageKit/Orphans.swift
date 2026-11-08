import Darwin
import Foundation

/// Something an app that's no longer on the Mac left in the user's Library.
public struct Orphan: Sendable, Hashable, Identifiable {
    public let leftover: Leftover
    /// The bundle ID the entry is named after.
    public let bundleID: String

    public var id: String { leftover.path }
    public var path: String { leftover.path }
    public var bytes: Int64 { leftover.bytes }
    public var kind: Leftover.Kind { leftover.kind }
}

/// Finds what removed apps left behind, the way Uninstall finds what an
/// installed app leaves, but by the names alone: an entry named after a
/// bundle ID that nothing on the Mac answers to any more.
///
/// Careful on purpose, since there's no app to tie an entry to:
/// - Only entries named exactly after a well-formed ID of three parts or
///   more, in folders where apps name entries that way. Names that merely
///   look like an app's aren't matched.
/// - Never Apple's (`com.apple.`), never an app group (named by team).
/// - An ID is still claimed when an installed app, a running process or
///   LaunchServices answers to it, and when any installed app shares its
///   vendor (`com.vendor`): vendors keep updaters, helpers and shared
///   settings under their own name, outside any one app.
/// - Settings and data are never chosen by default.
public enum Orphans {
    /// Library folders searched, and the ending an entry's name has there.
    static let places: [(folder: String, suffix: String)] = [
        ("Application Support", ""), ("Caches", ""), ("Containers", ""), ("Preferences", ".plist"),
        ("Saved Application State", ".savedState"), ("HTTPStorages", ""), ("WebKit", ""), ("Logs", ""),
        ("Application Scripts", ""), ("Cookies", ".binarycookies"),
    ]

    /// The bundle ID `entry` is named after, if it's named after one.
    static func bundleID(of entry: String, suffix: String) -> String? {
        guard suffix.isEmpty || entry.hasSuffix(suffix) else { return nil }
        let id = String(entry.dropLast(suffix.count))
        let parts = id.split(separator: ".")
        guard parts.count >= 3, AppLeftovers.isWellFormed(id) else { return nil }
        let lower = id.lowercased()
        guard !lower.hasPrefix("com.apple."), !lower.hasPrefix("group.") else { return nil }
        // A reverse-DNS name starts with a top-level domain, not a number.
        guard let first = parts.first, first.allSatisfy(\.isLetter) else { return nil }
        return id
    }

    /// "com.vendor" of "com.vendor.App".
    static func vendor(_ id: String) -> String {
        id.lowercased().split(separator: ".").prefix(2).joined(separator: ".")
    }

    /// Whether something on the Mac still answers to `id`.
    static func isClaimed(_ id: String, vendors: Set<String>, known: (String) -> Bool, running: Set<String>, claimedIDs: Set<String>) -> Bool {
        let lower = id.lowercased()
        if vendors.contains(vendor(id)) { return true }
        func claims(_ r: String) -> Bool {
            let r = r.lowercased()
            return r == lower || lower.hasPrefix(r + ".") || r.hasPrefix(lower + ".")
        }
        if running.contains(where: claims) || claimedIDs.contains(where: claims) { return true }
        return known(id)
    }

    /// The vendors of the installed apps.
    static func vendors(of installed: [AppBundle]) -> Set<String> {
        Set(installed.compactMap(\.bundleID).filter(AppLeftovers.isWellFormed).map(vendor))
    }

    /// Helpers may use another vendor's namespace. Unknown carried code
    /// cannot be treated as an empty set of owners.
    public static func claimedIDs(of installed: [AppBundle], readers: AppIdentity.Readers = .live) -> Set<String>? {
        var claimed = Set<String>()
        for app in installed {
            guard let id = app.bundleID, AppLeftovers.isWellFormed(id), let helpers = readers.carried(app.path) else { return nil }
            claimed.insert(id.lowercased())
            claimed.formUnion(helpers.map { $0.lowercased() })
        }
        return claimed
    }

    /// What removed apps left in `home`/Library, largest first. `installed`
    /// is every app listed; `known` asks LaunchServices about an ID;
    /// `running` holds the bundle IDs of the processes running now.
    public static func find(
        home: String = Home.path, installed: [AppBundle], known: (String) -> Bool, running: Set<String>,
        progress: ScanProgress = ScanProgress(), claimedIDs: Set<String>? = nil, readers: AppIdentity.Readers = .live
    ) -> [Orphan] {
        list(home: home, installed: installed, known: known, running: running, progress: progress, claimedIDs: claimedIDs, readers: readers).orphans
    }

    /// What `find` finds, and the searched folders that are there but
    /// couldn't be read: what's in them isn't listed.
    public static func list(
        home: String = Home.path, installed: [AppBundle], known: (String) -> Bool, running: Set<String>,
        progress: ScanProgress = ScanProgress(), claimedIDs: Set<String>? = nil, readers: AppIdentity.Readers = .live
    ) -> OrphanListing {
        guard let claimed = claimedIDs ?? Self.claimedIDs(of: installed, readers: readers) else {
            return OrphanListing(orphans: [], unreadable: [], unknownOwners: true)
        }
        let vendors = vendors(of: installed)
        let lib = home + "/Library"
        var out: [Orphan] = []
        var unreadable: [String] = []
        var knownIDs: [String: Bool] = [:]
        func registered(_ id: String) -> Bool {
            if let value = knownIDs[id] { return value }
            let value = known(id)
            knownIDs[id] = value
            return value
        }
        for place in places where !progress.isCancelled {
            let dir = lib + "/" + place.folder
            var st = stat()
            if lstat(dir, &st) != 0 && errno == ENOENT { continue }
            guard Trasher.noLinksBetween(home, and: dir), st.st_mode & S_IFMT == S_IFDIR else {
                unreadable.append(dir)
                continue
            }
            guard let names = DirectoryListing.names(dir) else {
                unreadable.append(dir)
                continue
            }
            entries: for entry in names where !entry.hasPrefix(".") && !progress.isCancelled {
                guard let id = bundleID(of: entry, suffix: place.suffix),
                    !isClaimed(id, vendors: vendors, known: registered, running: running, claimedIDs: claimed)
                else { continue }
                let path = dir + "/" + entry
                guard !Trasher.isProtected(path, home: home), Trasher.noLinksBetween(home, and: path), lstat(path, &st) == 0 else { continue }
                let bytes: Int64
                switch st.st_mode & S_IFMT {
                case S_IFDIR:
                    let result = StorageScanner.scan(path: path, progress: progress, workers: 1)
                    guard !result.cancelled else { break entries }
                    guard result.deniedPaths.isEmpty else { unreadable.append(path); continue }
                    bytes = result.root.size
                case S_IFREG: bytes = Int64(st.st_blocks) * 512
                default: continue
                }
                guard !progress.isCancelled else { break }
                out.append(Orphan(leftover: Leftover(path: path, bytes: bytes, place: place.folder), bundleID: id))
            }
        }
        return OrphanListing(
            orphans: out.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }, unreadable: unreadable, cancelled: progress.isCancelled)
    }

    /// Checked again right before an entry goes to the Trash: directly in
    /// one of the searched folders, with no link on the way, still named
    /// after an ID nothing answers to.
    public static func isStillOrphan(
        _ path: String, home: String = Home.path, installed: [AppBundle], known: (String) -> Bool, running: Set<String>, claimedIDs: Set<String>? = nil
    ) -> Bool {
        guard let claimed = claimedIDs ?? Self.claimedIDs(of: installed) else { return false }
        let lib = home + "/Library/"
        guard Trasher.isPlainPath(path), path.hasPrefix(lib), !Trasher.isProtected(path, home: home),
            Trasher.noLinksBetween(home, and: path)
        else { return false }
        let folder = (String(path.dropFirst(lib.count)) as NSString).deletingLastPathComponent
        let entry = (path as NSString).lastPathComponent
        guard let place = places.first(where: { $0.folder == folder }), let id = bundleID(of: entry, suffix: place.suffix),
            !isClaimed(id, vendors: vendors(of: installed), known: known, running: running, claimedIDs: claimed)
        else { return false }
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return st.st_mode & S_IFMT == S_IFDIR || st.st_mode & S_IFMT == S_IFREG
    }
}

/// What a search for removed apps' leftovers found.
public struct OrphanListing: Sendable {
    public var orphans: [Orphan]
    /// Searched folders that are there but couldn't be read.
    public var unreadable: [String]
    public var cancelled: Bool = false
    public var unknownOwners: Bool = false
}
