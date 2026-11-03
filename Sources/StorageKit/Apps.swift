import Darwin
import Foundation
import Synchronization

// Installed apps and what they leave in the user's Library. Leftovers are
// matched by the app's exact bundle ID, or its exact name in the two places
// apps name folders after themselves. Vendor folders shared by several apps
// ("Google", "Microsoft") are never matched, nothing is offered when
// another copy of the same app is still installed, and data another
// installed app's longer bundle ID claims ("com.vendor.Editor.Pro" for
// "com.vendor.Editor") stays with that app.

/// An app bundle in an Applications folder.
public struct AppBundle: Sendable, Hashable, Codable, Identifiable {
    public let path: String
    public let name: String
    public let bundleID: String?
    public let version: String?
    public let bytes: Int64
    public let fromAppStore: Bool
    /// Part of the bundle couldn't be read, so its size is a lower bound.
    public var incomplete: Bool = false

    public init(path: String, name: String, bundleID: String?, version: String?, bytes: Int64, fromAppStore: Bool) {
        self.path = path
        self.name = name
        self.bundleID = bundleID
        self.version = version
        self.bytes = bytes
        self.fromAppStore = fromAppStore
    }

    public var id: String { path }

    /// Part of macOS: moving it would fail or break the system.
    public var isProtected: Bool {
        AppFinder.protectedIDs.contains(bundleID ?? "") || path.hasPrefix("/System/")
    }
}

/// One file or folder an app left behind.
public struct Leftover: Sendable, Hashable, Codable, Identifiable {
    public let path: String
    public let bytes: Int64
    /// The Library folder it's in ("Preferences", "Caches", …).
    public let place: String

    public init(path: String, bytes: Int64, place: String) {
        self.path = path
        self.bytes = bytes
        self.place = place
    }

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }

    /// What a leftover holds, which decides whether it starts chosen.
    public enum Kind: Int, Sendable, Comparable {
        /// Caches, logs and window states the app rebuilds. Chosen.
        case rebuildable
        /// Parts of the app itself, such as a login item. Chosen.
        case appPart
        /// Settings. Kept unless chosen: a reinstall would start over.
        case settings
        /// Documents and data the app made. Kept unless chosen.
        case data
        /// Data shared with the developer's other apps. Kept unless chosen.
        case shared

        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

        public var chosenByDefault: Bool { self == .rebuildable || self == .appPart }

        public var title: String {
            switch self {
            case .rebuildable: "Rebuilt"
            case .appPart: "App part"
            case .settings: "Settings"
            case .data: "Your data"
            case .shared: "Shared"
            }
        }
    }

    public var kind: Kind {
        switch place {
        case "Caches", "Logs", "Saved Application State", "HTTPStorages", "WebKit", "Cookies": .rebuildable
        case "LaunchAgents", "Application Scripts": .appPart
        case "Preferences", "Preferences/ByHost": .settings
        case "Group Containers": .shared
        default: .data
        }
    }
}

public enum AppFinder {
    static let protectedIDs: Set<String> = ["com.apple.Safari", "com.apple.finder", "com.apple.systempreferences"]

    public static func defaultFolders(home: String = Home.path) -> [String] {
        ["/Applications", home + "/Applications"]
    }

    /// Every app in `folders` and their direct subfolders ("Utilities"),
    /// largest first, measured a few at a time.
    public static func find(
        in folders: [String], progress: ScanProgress = ScanProgress(), workers: Int = 4
    ) -> [AppBundle] {
        list(in: folders, progress: progress, workers: workers).apps
    }

    /// The apps in `folders`, and the folders that couldn't be read. A
    /// folder that isn't there is simply empty.
    public static func list(
        in folders: [String], progress: ScanProgress = ScanProgress(), workers: Int = 4
    ) -> AppListing {
        var paths: [String] = []
        var unreadable: [String] = []
        func names(_ dir: String) -> [String] {
            guard let names = DirectoryListing.names(dir) else {
                unreadable.append(dir)
                return []
            }
            return names.filter { !$0.hasPrefix(".") }
        }
        for folder in folders {
            for name in names(folder) {
                let p = folder + "/" + name
                if name.hasSuffix(".app") {
                    paths.append(p)
                } else if isRealFolder(p) {
                    paths += names(p).filter { $0.hasSuffix(".app") }.map { p + "/" + $0 }
                }
            }
        }
        let all = paths
        let found = Mutex<[AppBundle]>([])
        let next = Atomic<Int>(0)
        DispatchQueue.concurrentPerform(iterations: max(1, workers)) { _ in
            while !progress.isCancelled {
                let i = next.add(1, ordering: .relaxed).oldValue
                guard i < all.count else { return }
                if let app = read(all[i]) { found.withLock { $0.append(app) } }
            }
        }
        let apps = found.withLock { $0 }.sorted {
            $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return AppListing(apps: apps, unreadable: unreadable)
    }

    static func contents(_ dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { !$0.hasPrefix(".") }
    }

    static func isRealFolder(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
    }

    /// An uninstaller the app ships, inside its bundle or beside it in its
    /// own vendor folder ("Adobe X/Uninstall X.app"). Such apps install
    /// parts outside the Library that only their uninstaller knows.
    public static func ownUninstaller(of app: AppBundle, folders: [String]) -> String? {
        let inside = ["Contents", "Contents/Resources", "Contents/SharedSupport", "Contents/Helpers", "Contents/Library"]
            .map { app.path + "/" + $0 }
        let parent = (app.path as NSString).deletingLastPathComponent
        let beside = folders.contains(parent) ? [] : [parent]
        for dir in inside + beside {
            if let name = contents(dir).sorted().first(where: { $0.hasSuffix(".app") && $0.lowercased().contains("uninstall") }),
                dir + "/" + name != app.path
            {
                return dir + "/" + name
            }
        }
        return nil
    }

    /// The bundle's identity from its Info.plist, and its size on disk.
    public static func read(_ path: String) -> AppBundle? {
        guard isRealFolder(path) else { return nil }
        let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist") as? [String: Any] ?? [:]
        let fallback = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? fallback
        let r = StorageScanner.scan(path: path, workers: 1)
        var app = AppBundle(
            path: path, name: name.isEmpty ? fallback : name, bundleID: info["CFBundleIdentifier"] as? String,
            version: (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String), bytes: r.root.size,
            fromAppStore: FileManager.default.fileExists(atPath: path + "/Contents/_MASReceipt/receipt"))
        app.incomplete = !r.deniedPaths.isEmpty || r.root.unreadable
        return app
    }
}

public enum AppLeftovers {
    /// Library folders searched, and how an entry there is tied to an app.
    enum Match { case exactID, idPrefix, idPlist, name, groupContainer }

    static let places: [(folder: String, matches: [Match])] = [
        ("Application Support", [.exactID, .name]),
        ("Caches", [.exactID]),
        ("Containers", [.exactID]),
        ("Group Containers", [.groupContainer]),
        ("Preferences", [.idPlist]),
        ("Preferences/ByHost", [.idPrefix]),
        ("Saved Application State", [.idPrefix]),
        ("Logs", [.exactID, .name]),
        ("HTTPStorages", [.exactID, .idPrefix]),
        ("WebKit", [.exactID]),
        ("Cookies", [.idPrefix]),
        ("LaunchAgents", [.idPrefix]),
        ("Application Scripts", [.exactID]),
    ]

    /// Names too generic to tie a folder to one app.
    static let genericNames: Set<String> = ["app", "apps", "data", "helper", "update", "updater", "installer", "setup"]

    /// What `app` left in `home`/Library. `installed` is every app found,
    /// so data another copy of the app still uses is never offered.
    /// `identity` adds what the app carries; leave it out to match by the
    /// app's own ID and name only.
    public static func find(
        for app: AppBundle, home: String = Home.path, installed: [AppBundle], identity: AppIdentity = AppIdentity()
    ) -> [Leftover] {
        guard let id = app.bundleID, isWellFormed(id), !app.isProtected else { return [] }
        if installed.contains(where: { $0.path != app.path && $0.bundleID == id }) { return [] }
        let lib = home + "/Library"
        var out: [Leftover] = []
        for place in places {
            let dir = lib + "/" + place.folder
            for entry in AppFinder.contents(dir)
            where belongs(entry, rules: place.matches, to: app, installed: installed, identity: identity) {
                let p = dir + "/" + entry
                if let m = measure(p) { out.append(Leftover(path: p, bytes: m, place: place.folder)) }
            }
        }
        return out.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
    }

    /// A reverse-DNS bundle ID ("com.vendor.App"): two or more parts of
    /// letters, digits, hyphens and underscores. A looser one can't be told
    /// apart from ordinary folder names, so nothing is matched for it.
    public static func isWellFormed(_ id: String) -> Bool {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }

    /// Whether `entry` is `app`'s and no other installed app's: its name
    /// counts only when no other app shares it, and an entry another app's
    /// longer bundle ID also matches belongs to that app.
    static func belongs(
        _ entry: String, rules: [Match], to app: AppBundle, installed: [AppBundle], identity: AppIdentity = AppIdentity()
    ) -> Bool {
        guard let id = app.bundleID, isWellFormed(id) else { return false }
        let others = installed.filter { $0.path != app.path }
        let name = app.name
        let nameUsable = name.count >= 3 && !genericNames.contains(name.lowercased()) && !others.contains { $0.name == name }
        // An app group is matched exactly, by the name the signature gives it.
        if rules.contains(.groupContainer), identity.groups.contains(entry) { return true }
        // The app's own ID and name, then each helper's ID by the same rules.
        let idRules = rules.filter { $0 != .name }
        var matched: [String] = []
        if matches(entry, id: id, name: nameUsable ? name : nil, rules: rules) { matched.append(id) }
        for helper in identity.helperIDs where !others.contains(where: { $0.bundleID == helper }) {
            if matches(entry, id: helper, name: nil, rules: idRules) { matched.append(helper) }
        }
        guard !matched.isEmpty else { return false }
        // Another installed app whose ID extends a matched one claims the entry more closely.
        return !others.contains { other in
            guard let otherID = other.bundleID else { return false }
            return matched.contains { m in otherID.hasPrefix(m + ".") && matches(entry, id: otherID, name: nil, rules: rules) }
        }
    }

    static func matches(_ entry: String, id: String, name: String?, rules: [Match]) -> Bool {
        rules.contains { rule in
            switch rule {
            case .exactID: entry == id
            case .idPrefix: entry == id || entry.hasPrefix(id + ".")
            case .idPlist: entry == id + ".plist"
            case .name: name.map { entry == $0 } ?? false
            case .groupContainer:
                // "group.<id>" or "<TEAMID>.<id>", where a team ID is ten letters and digits.
                entry == "group." + id
                    || (entry.hasSuffix("." + id) && entry.dropLast(id.count + 1).count == 10
                        && entry.dropLast(id.count + 1).allSatisfy { $0.isLetter || $0.isNumber })
            }
        }
    }

    static func measure(_ path: String) -> Int64? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        switch st.st_mode & S_IFMT {
        case S_IFDIR: return StorageScanner.scan(path: path, workers: 1).root.size
        case S_IFREG: return Int64(st.st_blocks) * 512
        default: return nil
        }
    }

    /// Checked again right before a leftover goes to the Trash: still in one
    /// of the searched Library folders, still the app's and no other
    /// installed app's, with no link on the way or at the end.
    public static func isStillLeftover(
        _ path: String, of app: AppBundle, home: String = Home.path, installed: [AppBundle],
        identity: AppIdentity = AppIdentity()
    ) -> Bool {
        guard let id = app.bundleID, Trasher.isPlainPath(path),
            !installed.contains(where: { $0.path != app.path && $0.bundleID == id })
        else { return false }
        let lib = home + "/Library/"
        guard path.hasPrefix(lib), Trasher.noLinksBetween(home, and: path) else { return false }
        let folder = (String(path.dropFirst(lib.count)) as NSString).deletingLastPathComponent
        let entry = (path as NSString).lastPathComponent
        guard let place = places.first(where: { $0.folder == folder }),
            belongs(entry, rules: place.matches, to: app, installed: installed, identity: identity)
        else { return false }
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return st.st_mode & S_IFMT == S_IFDIR || st.st_mode & S_IFMT == S_IFREG
    }
}

/// Copies and editions of an app elsewhere on the Mac, found by Spotlight:
/// an app on another disk whose bundle ID starts with this one's
/// ("com.vendor.App.Pro") uses the same Library entries, so they're its too.
public enum AppSiblings {
    static let mdfind = "/usr/bin/mdfind"

    /// Every app bundle Spotlight knows whose ID starts with `app`'s, other
    /// than `app` itself and anything in a Trash. Nil when Spotlight couldn't
    /// be asked, so nothing is offered on a guess.
    public static func find(for app: AppBundle, runner: CommandRunner) -> [AppBundle]? {
        guard let id = app.bundleID, AppLeftovers.isWellFormed(id), runner.exists(mdfind) else { return nil }
        // A well-formed ID holds no quote or wildcard, so it can't change the query.
        let query = "kMDItemContentType == \"com.apple.application-bundle\" && kMDItemCFBundleIdentifier == \"\(id)*\"c"
        let (code, output) = runner.run(mdfind, ["-0", query])
        guard code == 0 else { return nil }
        return output.split(separator: "\0").map(String.init)
            .filter { $0.hasPrefix("/") }
            .map(Trasher.lexical)
            .filter { $0 != app.path && !$0.contains("/.Trash/") && !$0.contains("/.Trashes/") }
            .map { path in
                // The bundle's own ID, not the index's; one that can't be read
                // counts as another copy of this app.
                let own = NSDictionary(contentsOfFile: path + "/Contents/Info.plist")?["CFBundleIdentifier"] as? String
                return AppBundle(
                    path: path, name: (path as NSString).lastPathComponent, bundleID: own ?? id, version: nil, bytes: 0,
                    fromAppStore: false)
            }
    }
}

/// Where an app is named in the user's shell or tool settings. MyMole only
/// points these out; the files are the user's to edit.
public struct AppMention: Sendable, Hashable {
    public let file: String
    public let line: Int

    public init(file: String, line: Int) {
        self.file = file
        self.line = line
    }
}

public enum AppMentions {
    /// Shell start-up files and the settings of tools that launch apps or
    /// MCP servers, relative to the home folder.
    static let files = [
        ".zshrc", ".zprofile", ".zshenv", ".bashrc", ".bash_profile", ".profile", ".config/fish/config.fish",
        ".gitconfig", ".claude.json", ".claude/settings.json", ".cursor/mcp.json", ".codeium/windsurf/mcp_config.json",
        ".config/zed/settings.json", "Library/Application Support/Claude/claude_desktop_config.json",
        "Library/Application Support/Code/User/settings.json",
    ]

    static let maxFileSize = 8 << 20

    /// Lines naming the app's bundle ("Editor.app") or its bundle ID. Only
    /// the file and line are kept: a line may hold a key or token.
    public static func find(for app: AppBundle, home: String = Home.path) -> [AppMention] {
        let bundle = (app.path as NSString).lastPathComponent
        let terms = [bundle] + (app.bundleID.map { AppLeftovers.isWellFormed($0) ? [$0] : [] } ?? [])
        var out: [AppMention] = []
        for rel in files {
            let path = home + "/" + rel
            var st = stat()
            guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= maxFileSize,
                let text = try? String(contentsOfFile: path, encoding: .utf8)
            else { continue }
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where terms.contains(where: line.contains) {
                out.append(AppMention(file: path, line: i + 1))
            }
        }
        return out
    }
}

/// The last complete app list, so the pane opens on it at once.
/// What a listing of apps found, and which folders it couldn't read.
public struct AppListing: Sendable {
    public var apps: [AppBundle]
    public var unreadable: [String]

    public init(apps: [AppBundle], unreadable: [String] = []) {
        self.apps = apps
        self.unreadable = unreadable
    }

    /// Every folder and every bundle was read whole.
    public var isComplete: Bool { unreadable.isEmpty && !apps.contains(where: \.incomplete) }
}

public enum AppStore {
    static let formatVersion = 2

    public struct Saved: Sendable, Codable {
        public let version: Int
        public let folders: [String]
        public let date: Date
        public let apps: [AppBundle]
    }

    public static var defaultBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MyMole/Apps")
    }

    public static func load(folders: [String], base: URL = defaultBase) -> Saved? {
        guard let d = try? Data(contentsOf: base.appending(path: "last.json")),
            let saved = try? JSONDecoder().decode(Saved.self, from: d),
            saved.version == formatVersion, saved.folders == folders
        else { return nil }
        return saved
    }

    /// Only a listing that read every folder and bundle replaces the saved one.
    public static func save(_ listing: AppListing, folders: [String], date: Date = Date(), base: URL = defaultBase) {
        guard listing.isComplete else { return }
        let saved = Saved(version: formatVersion, folders: folders, date: date, apps: listing.apps)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(saved) { try? d.write(to: base.appending(path: "last.json"), options: .atomic) }
    }
}
