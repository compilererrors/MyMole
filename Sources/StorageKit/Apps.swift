import Darwin
import Foundation
import Synchronization

// Installed apps and what they leave in the user's Library. Leftovers are
// matched by the app's exact bundle ID, or its exact name in the two places
// apps name folders after themselves and in the crash reports macOS names
// after it. Vendor folders shared by several apps
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
    /// Metadata is available, but the bundle's size hasn't been read yet.
    public var sizePending: Bool = false

    public init(path: String, name: String, bundleID: String?, version: String?, bytes: Int64, fromAppStore: Bool) {
        self.path = path
        self.name = name
        self.bundleID = bundleID
        self.version = version
        self.bytes = bytes
        self.fromAppStore = fromAppStore
    }

    public var id: String { path }

    private enum CodingKeys: String, CodingKey {
        case path, name, bundleID, version, bytes, fromAppStore, incomplete, sizePending
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        name = try c.decode(String.self, forKey: .name)
        bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        bytes = try c.decode(Int64.self, forKey: .bytes)
        fromAppStore = try c.decode(Bool.self, forKey: .fromAppStore)
        incomplete = try c.decodeIfPresent(Bool.self, forKey: .incomplete) ?? false
        sizePending = try c.decodeIfPresent(Bool.self, forKey: .sizePending) ?? false
    }

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

    /// How it's tied to the app.
    public var evidence: Evidence = .bundleID

    public enum Evidence: String, Sendable, Codable, CaseIterable {
        /// Named by the app's own bundle ID.
        case bundleID
        /// An app group the app's signature names.
        case group
        /// Named by the ID of a part the app carries: a helper, an extension.
        case helper
        /// By the app's name only, which no other installed app has. The
        /// weakest tie: never chosen for the user.
        case name
        /// A folder named after the app inside its maker's own folder
        /// ("Application Support/Google/Chrome" for Google Chrome).
        case vendorFolder
        /// The maker's, for all its apps (an updater, its launch job), offered
        /// only when this is the last of the maker's apps on the Mac. Never
        /// chosen for the user.
        case vendor
        /// What the deeper search found: the app's name inside a longer
        /// name, or a hidden folder in the home folder. Never chosen.
        case loose

        public var title: String {
            switch self {
            case .bundleID: "by its bundle ID"
            case .group: "an app group its signature names"
            case .helper: "by a part it carries"
            case .name: "by its name only"
            case .vendorFolder: "in its maker's folder, by its name"
            case .vendor: "its maker's, and no other app of the maker is left"
            case .loose: "by a looser match of its name; look before choosing"
            }
        }
    }

    /// Starts chosen: what's rebuilt or part of the app, tied by more than a name.
    public var chosenByDefault: Bool { kind.chosenByDefault && ![.name, .vendor, .loose].contains(evidence) }

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
        case "Caches", "Logs", "Saved Application State", "HTTPStorages", "WebKit", "Cookies", "Logs/DiagnosticReports",
            "Application Support/CrashReporter", AppLeftovers.recentDocuments:
            .rebuildable
        case "LaunchAgents", "Application Scripts": .appPart
        case "Preferences", "Preferences/ByHost": .settings
        case "Group Containers": .shared
        case "~/.cache": .rebuildable
        case "~/.config": .settings
        default: .data
        }
    }
}

public enum AppFinder {
    static let protectedIDs: Set<String> = ["com.apple.Safari", "com.apple.finder", "com.apple.systempreferences"]

    public static func defaultFolders(home: String = Home.path) -> [String] {
        #if SMOKE
        // The smoke and screenshot build's own copy can be kept to folders
        // of its run, so the Mac's real apps never show; shipping builds
        // have no such switch.
        if let list = ProcessInfo.processInfo.environment["MYMOLE_SMOKE_APPS"] {
            return list.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        }
        #endif
        // macOS's own apps too: they can't be removed, but their caches
        // and settings can be reset.
        return ["/Applications", home + "/Applications", systemApplications]
    }

    /// Where macOS's own apps are; shown only when asked for.
    public static let systemApplications = "/System/Applications"

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
        in folders: [String], progress: ScanProgress = ScanProgress(), workers: Int = 4,
        onStep: (@Sendable (AppListingStep) -> Void)? = nil
    ) -> AppListing {
        measure(inventory(in: folders, progress: progress), progress: progress, workers: workers, onStep: onStep)
    }

    /// Names and metadata only: cheap enough to run before waiting for a disk-walk slot.
    public static func inventory(in folders: [String], progress: ScanProgress = ScanProgress()) -> AppListing {
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
            guard !progress.isCancelled else { break }
            for name in names(folder) {
                guard !progress.isCancelled else { break }
                let p = folder + "/" + name
                if name.lowercased().hasSuffix(".app") {
                    paths.append(p)
                } else if isRealFolder(p) {
                    paths += names(p).filter { $0.hasSuffix(".app") }.map { p + "/" + $0 }
                }
            }
        }
        // Reading names and Info.plists never waits for a recursive size walk.
        var seen = Set<String>()
        let all = paths.filter { seen.insert($0).inserted }.compactMap { path -> AppBundle? in
            guard !progress.isCancelled else { return nil }
            return metadata(path)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return AppListing(apps: all, unreadable: unreadable, cancelled: progress.isCancelled)
    }

    /// The expensive stage, sharing the scan budget chosen by its caller.
    public static func measure(
        _ inventory: AppListing, progress: ScanProgress = ScanProgress(), workers: Int = 4,
        onStep: (@Sendable (AppListingStep) -> Void)? = nil
    ) -> AppListing {
        let all = inventory.apps
        onStep?(AppListingStep(apps: all, measured: 0))
        let found = Mutex((apps: all, measured: 0, sent: ContinuousClock.now))
        let next = Atomic<Int>(0)
        DispatchQueue.concurrentPerform(iterations: min(max(1, workers), max(1, all.count))) { _ in
            while !progress.isCancelled {
                let i = next.add(1, ordering: .relaxed).oldValue
                guard i < all.count else { return }
                let app = measured(all[i], progress: progress)
                let step = found.withLock { s -> AppListingStep? in
                    s.apps[i] = app
                    s.measured += 1
                    guard onStep != nil, ContinuousClock.now - s.sent >= .milliseconds(120) else { return nil }
                    s.sent = .now
                    return AppListingStep(apps: s.apps, measured: s.measured)
                }
                if let step { onStep?(step) }
            }
        }
        let apps = found.withLock { $0.apps }.sorted {
            $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return AppListing(apps: apps, unreadable: inventory.unreadable, cancelled: inventory.cancelled || progress.isCancelled)
    }

    /// The apps in `folders` and their direct subfolders, read from their
    /// Info.plist only, unmeasured: who's installed right now, quickly.
    /// Nil when a folder that's there couldn't be read, so nothing is
    /// taken for unclaimed on a partial list.
    public static func installedNow(in folders: [String]) -> [AppBundle]? {
        var out: [AppBundle] = []
        var seen = Set<String>()
        func names(_ dir: String) -> [String]? { DirectoryListing.names(dir) }
        func add(_ path: String) -> Bool {
            guard isRealFolder(path), Trasher.noLinksBetween(path, and: path + "/Contents"),
                  let app = metadata(path), let id = app.bundleID, AppLeftovers.isWellFormed(id) else { return false }
            var st = stat()
            guard lstat(path + "/Contents/Info.plist", &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return false }
            if seen.insert(path).inserted { out.append(app) }
            return true
        }
        for folder in folders {
            guard let top = names(folder) else { return nil }
            for name in top {
                let p = folder + "/" + name
                if name.lowercased().hasSuffix(".app") {
                    guard add(p) else { return nil }
                } else {
                    var st = stat()
                    guard lstat(p, &st) == 0, st.st_mode & S_IFMT != S_IFLNK else { return nil }
                    if st.st_mode & S_IFMT == S_IFDIR {
                        guard let inner = names(p) else { return nil }
                        for n in inner where n.lowercased().hasSuffix(".app") {
                            guard add(p + "/" + n) else { return nil }
                        }
                    }
                }
            }
        }
        return out
    }

    static func contents(_ dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { !$0.hasPrefix(".") }
    }

    static func isRealFolder(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
    }

    /// An uninstaller the app ships: inside its bundle, beside it in its
    /// own vendor folder ("Adobe X/Uninstall X.app"), or in its folder in
    /// one of `supportFolders` (Application Support in the home and system
    /// Library). Such apps install parts outside the Library that only their
    /// uninstaller knows.
    public static func ownUninstaller(of app: AppBundle, folders: [String], supportFolders: [String] = []) -> String? {
        let inside = ["Contents", "Contents/Resources", "Contents/SharedSupport", "Contents/Helpers", "Contents/Library"]
            .map { app.path + "/" + $0 }
        let parent = (app.path as NSString).deletingLastPathComponent
        let beside = folders.contains(parent) ? [] : [parent]
        for dir in inside + beside {
            if let found = uninstaller(in: dir, besides: app.path) { return found }
        }
        // A folder named after the app or its bundle ID is the app's own; one
        // named after the vendor is shared by its products, so there the
        // uninstaller must name the app.
        let own = Set([app.name, app.bundleID ?? ""].map { $0.lowercased() }.filter { !$0.isEmpty })
        let id = (app.bundleID ?? "").split(separator: ".")
        let vendor = id.count >= 3 ? id[1].lowercased() : nil
        for root in supportFolders {
            for entry in contents(root).sorted() {
                let name = entry.lowercased()
                let mustName: String? = own.contains(name) ? nil : name == vendor ? app.name.lowercased() : "-"
                guard mustName != "-", isRealFolder(root + "/" + entry) else { continue }
                let dir = root + "/" + entry
                for sub in [dir] + contents(dir).sorted().map({ dir + "/" + $0 }).filter(isRealFolder) {
                    if let found = uninstaller(in: sub, besides: app.path, naming: mustName) { return found }
                }
            }
        }
        return nil
    }

    /// The first uninstaller in `dir` other than the app itself, and only
    /// one whose name holds `naming` when given.
    static func uninstaller(in dir: String, besides app: String, naming: String? = nil) -> String? {
        contents(dir).sorted()
            .first { isUninstaller($0) && (naming.map($0.lowercased().contains) ?? true) && dir + "/" + $0 != app }
            .map { dir + "/" + $0 }
    }

    /// Named for removing something, in a form a person opens: an app, an
    /// installer package or a script ("Uninstall X.app", "X Remover.pkg",
    /// "uninstall.command").
    static func isUninstaller(_ name: String) -> Bool {
        let lower = name.lowercased()
        return [".app", ".pkg", ".command", ".tool"].contains(where: lower.hasSuffix)
            && ["uninst", "deinstall", "remover", "removal"].contains(where: lower.contains)
    }

    /// The bundle's identity from its Info.plist, and its size on disk.
    /// The inexpensive part of an app listing, without walking its contents.
    public static func metadata(_ path: String) -> AppBundle? {
        guard isRealFolder(path) else { return nil }
        let info = AppIdentity.bundleInfo(atPath: path) ?? [:]
        let fallback = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? fallback
        var app = AppBundle(
            path: path, name: name.isEmpty ? fallback : name, bundleID: info["CFBundleIdentifier"] as? String,
            version: (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String), bytes: 0,
            fromAppStore: FileManager.default.fileExists(atPath: path + "/Contents/_MASReceipt/receipt"))
        app.sizePending = true
        return app
    }

    public static func read(_ path: String, progress: ScanProgress = ScanProgress()) -> AppBundle? {
        metadata(path).map { measured($0, progress: progress) }
    }

    private static func measured(_ metadata: AppBundle, progress: ScanProgress) -> AppBundle {
        let r = StorageScanner.scan(path: metadata.path, progress: progress, workers: 1)
        var app = AppBundle(
            path: metadata.path, name: metadata.name, bundleID: metadata.bundleID, version: metadata.version,
            bytes: r.root.size, fromAppStore: metadata.fromAppStore)
        app.incomplete = r.cancelled || !r.deniedPaths.isEmpty || r.root.unreadable
        return app
    }
}

public enum AppLeftovers {
    /// Library folders searched, and how an entry there is tied to an app.
    enum Match { case exactID, idPrefix, idPlist, name, groupContainer, report, recentList }

    /// Where macOS keeps each app's list of recent documents.
    static let recentDocuments =
        "Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments"
    /// Endings of the crash, hang and diagnostic reports macOS writes.
    static let reportEndings: Set<String> = ["ips", "crash", "diag", "hang", "spin", "plist"]

    static let places: [(folder: String, matches: [Match])] = [
        ("Application Support", [.exactID, .name]),
        ("Caches", [.exactID, .name]),
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
        ("Application Scripts", [.exactID, .groupContainer]),
        ("Logs/DiagnosticReports", [.report]),
        ("Application Support/CrashReporter", [.report]),
        (recentDocuments, [.recentList]),
    ]

    /// Names too generic to tie a folder to one app.
    static let genericNames: Set<String> = ["app", "apps", "data", "helper", "update", "updater", "installer", "setup"]

    /// What `app` left in `home`/Library. `installed` is every app found,
    /// so data another copy of the app still uses is never offered.
    /// `identity` adds what the app carries; leave it out to match by the
    /// app's own ID and name only. An app that's part of macOS has its
    /// caches, settings and parts found too, never its data, for a reset.
    /// `deep`: also what a looser match finds (`DeepLeftovers`), never chosen.
    public static func find(
        for app: AppBundle, home: String = Home.path, installed: [AppBundle], identity: AppIdentity = AppIdentity(),
        deep: Bool = false, progress: ScanProgress = ScanProgress()
    ) -> [Leftover] {
        guard let id = app.bundleID, isWellFormed(id) else { return [] }
        if installed.contains(where: { $0.path != app.path && $0.bundleID?.caseInsensitiveCompare(id) == .orderedSame }) { return [] }
        let lib = home + "/Library"
        var out: [Leftover] = []
        for place in places where !progress.isCancelled {
            let dir = lib + "/" + place.folder
            guard Trasher.noLinksBetween(home, and: dir) else { continue }
            for entry in AppFinder.contents(dir) where !progress.isCancelled {
                guard let why = evidence(entry, rules: place.matches, to: app, installed: installed, identity: identity) else { continue }
                let p = dir + "/" + entry
                guard mayOffer(place.folder, of: app), Trasher.noLinksBetween(home, and: p) else { continue }
                if let m = measure(p, progress: progress) {
                    var l = Leftover(path: p, bytes: m, place: place.folder)
                    l.evidence = why
                    out.append(l)
                }
            }
        }
        if !app.isProtected && !progress.isCancelled && Trasher.noLinksBetween(home, and: lib) {
            out += vendorFolders(of: app, lib: lib, installed: installed, progress: progress)
            out += vendorShared(of: app, lib: lib, installed: installed, progress: progress)
            if deep && !progress.isCancelled {
                let known = Set(out.map(\.path))
                out += DeepLeftovers.find(for: app, home: home, installed: installed, progress: progress).filter { !known.contains($0.path) }
            }
        }
        out.removeAll { claimedByOtherApp($0.path, of: app, home: home, identity: identity) }
        // One leftover inside another goes with it.
        let paths = Set(out.map(\.path))
        out.removeAll { l in paths.contains { l.path.hasPrefix($0 + "/") } }
        return out.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
    }

    // MARK: The maker's folders

    /// Places where makers keep a folder of their own, with one inside for
    /// each of their apps.
    static let vendorPlaces = ["Application Support", "Caches", "Logs"]
    /// Places where a maker's own entries, for all its apps, are named by
    /// its ID ("com.google.keystone.agent.plist"): launch jobs and what's
    /// rebuilt. Settings and data named by the maker may be another of its
    /// apps', one on another disk, so they're left to that app.
    static let vendorIDPlaces = ["LaunchAgents", "Caches", "HTTPStorages"]

    /// "google" of "com.google.Chrome": the maker, in a bundle ID of three parts or more.
    static func company(of id: String) -> String? {
        let parts = id.split(separator: ".")
        guard parts.count >= 3, parts[1].count >= 3 else { return nil }
        let c = parts[1].lowercased()
        return ["apple", "github", "electron"].contains(c) ? nil : c
    }

    static func letters(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// Whether `folder` is the maker's own: "Google" for com.google.*.
    static func isVendorFolder(_ folder: String, of id: String) -> Bool {
        guard let c = company(of: id) else { return false }
        return letters(folder) == c
    }

    /// What the app's folder inside its maker's may be called: its name,
    /// and its name without the maker's ("Chrome" of "Google Chrome").
    static func productNames(_ app: AppBundle, inVendorFolder vendor: String) -> Set<String> {
        var names: Set<String> = [app.name.lowercased()]
        let prefix = vendor.lowercased() + " "
        if app.name.lowercased().hasPrefix(prefix) { names.insert(String(app.name.lowercased().dropFirst(prefix.count))) }
        return names.filter { $0.count >= 3 && !genericNames.contains($0) }
    }

    /// Whether `entry` in `vendor` folder is `app`'s, and no other installed app's.
    static func isAppsVendorEntry(_ entry: String, vendor: String, of app: AppBundle, installed: [AppBundle]) -> Bool {
        guard let id = app.bundleID, isVendorFolder(vendor, of: id),
            productNames(app, inVendorFolder: vendor).contains(entry.lowercased())
        else { return false }
        // Another installed app the folder's name could be: it stays.
        return !installed.contains { other in
            other.path != app.path && (other.bundleID == id || productNames(other, inVendorFolder: vendor).contains(entry.lowercased()))
        }
    }

    static func vendorFolders(of app: AppBundle, lib: String, installed: [AppBundle], progress: ScanProgress = ScanProgress()) -> [Leftover] {
        guard let id = app.bundleID else { return [] }
        var out: [Leftover] = []
        for place in vendorPlaces where !progress.isCancelled {
            guard Trasher.noLinksBetween(lib, and: lib + "/" + place) else { continue }
            for vendor in AppFinder.contents(lib + "/" + place) where isVendorFolder(vendor, of: id) {
                let dir = lib + "/" + place + "/" + vendor
                guard AppFinder.isRealFolder(dir), Trasher.noLinksBetween(lib, and: dir), !progress.isCancelled else { continue }
                for entry in AppFinder.contents(dir) where !progress.isCancelled && isAppsVendorEntry(entry, vendor: vendor, of: app, installed: installed) {
                    let p = dir + "/" + entry
                    if let m = measure(p, progress: progress) {
                        var l = Leftover(path: p, bytes: m, place: place)
                        l.evidence = .vendorFolder
                        out.append(l)
                    }
                }
            }
        }
        return out
    }

    /// The maker's own entries, for the last of its apps: named by the
    /// maker's ID and by no installed app's, or the maker's folder in the
    /// Library itself ("~/Library/Google", which holds Google's updater).
    static func vendorShared(of app: AppBundle, lib: String, installed: [AppBundle], progress: ScanProgress = ScanProgress()) -> [Leftover] {
        guard let id = app.bundleID, let company = company(of: id) else { return [] }
        let prefix = id.split(separator: ".").prefix(2).joined(separator: ".").lowercased() + "."
        let others = installed.filter { $0.path != app.path }
        // Another app of the maker is still here: what's shared is its too.
        guard !others.contains(where: { ($0.bundleID?.lowercased().hasPrefix(prefix)) ?? false }) else { return [] }
        let otherIDs = others.compactMap { $0.bundleID?.lowercased() }
        var out: [Leftover] = []
        for place in vendorIDPlaces where !progress.isCancelled {
            guard Trasher.noLinksBetween(lib, and: lib + "/" + place) else { continue }
            for entry in AppFinder.contents(lib + "/" + place) where !progress.isCancelled {
                let lower = entry.lowercased()
                guard lower.hasPrefix(prefix), !lower.hasPrefix(id.lowercased()),
                    !otherIDs.contains(where: { lower == $0 || lower.hasPrefix($0 + ".") })
                else { continue }
                let p = lib + "/" + place + "/" + entry
                if let m = measure(p, progress: progress) {
                    var l = Leftover(path: p, bytes: m, place: place)
                    l.evidence = .vendor
                    out.append(l)
                }
            }
        }
        for entry in AppFinder.contents(lib) where !progress.isCancelled && letters(entry) == company && AppFinder.isRealFolder(lib + "/" + entry) {
            let p = lib + "/" + entry
            if let m = measure(p, progress: progress) {
                var l = Leftover(path: p, bytes: m, place: "Library")
                l.evidence = .vendor
                out.append(l)
            }
        }
        return out
    }

    /// The same rules as `vendorFolders` and `vendorShared`, for a path
    /// checked again right before it moves.
    static func isStillVendorLeftover(folder: String, entry: String, of app: AppBundle, installed: [AppBundle]) -> Bool {
        guard !app.isProtected, let id = app.bundleID else { return false }
        let parts = folder.split(separator: "/").map(String.init)
        // "<place>/<Maker>/<App>"
        if parts.count >= 2, vendorPlaces.contains(parts.dropLast().joined(separator: "/")), let vendor = parts.last {
            return isAppsVendorEntry(entry, vendor: vendor, of: app, installed: installed)
        }
        guard let company = company(of: id) else { return false }
        let prefix = id.split(separator: ".").prefix(2).joined(separator: ".").lowercased() + "."
        let others = installed.filter { $0.path != app.path }
        guard !others.contains(where: { ($0.bundleID?.lowercased().hasPrefix(prefix)) ?? false }) else { return false }
        if folder.isEmpty { return letters(entry) == company }
        let lower = entry.lowercased()
        let otherIDs = others.compactMap { $0.bundleID?.lowercased() }
        return vendorIDPlaces.contains(folder) && lower.hasPrefix(prefix) && !lower.hasPrefix(id.lowercased())
            && !otherIDs.contains(where: { lower == $0 || lower.hasPrefix($0 + ".") })
    }

    /// What of a macOS app may go: what it rebuilds, its parts and its
    /// settings. Its data and what Apple's apps share stay, whatever is chosen.
    static func mayOffer(_ place: String, of app: AppBundle) -> Bool {
        guard app.isProtected else { return true }
        let kind = Leftover(path: "", bytes: 0, place: place).kind
        return kind != .data && kind != .shared
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
        evidence(entry, rules: rules, to: app, installed: installed, identity: identity) != nil
    }

    /// How `entry` is tied to `app` and no other installed app, or nil
    /// when it isn't: its name counts only when no other app shares it, and
    /// an entry another app's longer bundle ID also matches belongs to that app.
    static func evidence(
        _ entry: String, rules: [Match], to app: AppBundle, installed: [AppBundle], identity: AppIdentity = AppIdentity()
    ) -> Leftover.Evidence? {
        guard let id = app.bundleID, isWellFormed(id) else { return nil }
        let others = installed.filter { $0.path != app.path }
        let name = app.name
        let nameUsable = name.count >= 3 && !genericNames.contains(name.lowercased()) && !others.contains { $0.name == name }
        // An app group is matched exactly, by the name the signature gives it.
        if rules.contains(.groupContainer), identity.groups.contains(entry) { return .group }
        // The app's own ID and name, then each helper's ID by the same rules.
        let idRules = rules.filter { $0 != .name && $0 != .report }
        var matched: [String] = []
        var why: Leftover.Evidence?
        if matches(entry, id: id, name: nil, rules: rules) {
            matched.append(id)
            why = .bundleID
        } else if nameUsable, matches(entry, id: id, name: name, rules: rules) {
            matched.append(id)
            why = .name
        }
        for helper in identity.helperIDs where !others.contains(where: { $0.bundleID == helper }) {
            if matches(entry, id: helper, name: nil, rules: idRules) {
                matched.append(helper)
                if why == nil { why = .helper }
            }
        }
        guard let why, !matched.isEmpty else { return nil }
        // Another installed app whose ID extends a matched one claims the entry more closely.
        let claimed = others.contains { other in
            guard let otherID = other.bundleID else { return false }
            return matched.contains { m in otherID.hasPrefix(m + ".") && matches(entry, id: otherID, name: nil, rules: rules) }
        }
        return claimed ? nil : why
    }

    static func matches(_ entry: String, id: String, name: String?, rules: [Match]) -> Bool {
        rules.contains { rule in
            switch rule {
            case .exactID: entry == id
            case .idPrefix: entry == id || entry.hasPrefix(id + ".")
            case .idPlist: entry == id + ".plist"
            case .name: name.map { entry == $0 } ?? false
            case .report:
                // "<Name>-2026-11-06-101112.ips", "<Name>_<UUID>.plist": by the
                // app's name, which must be one only it has.
                name.map { n in
                    (entry.hasPrefix(n + "-") || entry.hasPrefix(n + "_"))
                        && reportEndings.contains((entry as NSString).pathExtension.lowercased())
                } ?? false
            case .recentList:
                // "com.vendor.app.sfl3": the ID in lower case.
                ["sfl", "sfl2", "sfl3"].contains { entry == id.lowercased() + "." + $0 }
            case .groupContainer:
                // "group.<id>" or "<TEAMID>.<id>", where a team ID is ten letters and digits.
                entry == "group." + id
                    || (entry.hasSuffix("." + id) && entry.dropLast(id.count + 1).count == 10
                        && entry.dropLast(id.count + 1).allSatisfy { $0.isLetter || $0.isNumber })
            }
        }
    }

    public static func measure(_ path: String, progress: ScanProgress = ScanProgress()) -> Int64? {
        guard !progress.isCancelled else { return nil }
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        switch st.st_mode & S_IFMT {
        case S_IFDIR:
            let result = StorageScanner.scan(path: path, progress: progress, workers: 1)
            return result.cancelled ? nil : result.root.size
        case S_IFREG: return Int64(st.st_blocks) * 512
        default: return nil
        }
    }

    /// Checked again right before a leftover goes to the Trash: still in one
    /// of the searched Library folders, still the app's and no other
    /// installed app's, with no link on the way or at the end.
    /// `deep`: the path was found by the deeper search, and is checked by its rules.
    public static func isStillLeftover(
        _ path: String, of app: AppBundle, home: String = Home.path, installed: [AppBundle],
        identity: AppIdentity = AppIdentity(), deep: Bool = false
    ) -> Bool {
        guard let id = app.bundleID, Trasher.isPlainPath(path), !claimedByOtherApp(path, of: app, home: home, identity: identity),
            !installed.contains(where: { $0.path != app.path && $0.bundleID?.caseInsensitiveCompare(id) == .orderedSame })
        else { return false }
        let lib = home + "/Library/"
        // What the deeper search offered, checked again by its own rules.
        if deep { return DeepLeftovers.isStill(path, of: app, home: home, installed: installed) }
        guard path.hasPrefix(lib), Trasher.noLinksBetween(home, and: path) else { return false }
        let folder = (String(path.dropFirst(lib.count)) as NSString).deletingLastPathComponent
        let entry = (path as NSString).lastPathComponent
        if isStillVendorLeftover(folder: folder, entry: entry, of: app, installed: installed) {
            var st = stat()
            return lstat(path, &st) == 0 && (st.st_mode & S_IFMT == S_IFDIR || st.st_mode & S_IFMT == S_IFREG)
        }
        guard let place = places.first(where: { $0.folder == folder }), mayOffer(place.folder, of: app),
            belongs(entry, rules: place.matches, to: app, installed: installed, identity: identity)
        else { return false }
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return st.st_mode & S_IFMT == S_IFDIR || st.st_mode & S_IFMT == S_IFREG
    }

    /// A vendor/name/deep fallback cannot override another app's helper ID.
    private static func claimedByOtherApp(_ path: String, of app: AppBundle, home: String, identity: AppIdentity) -> Bool {
        let leaf = (path as NSString).lastPathComponent.lowercased()
        let name = leaf.hasPrefix(".") ? String(leaf.dropFirst()) : leaf
        if identity.otherOwnerIDs.contains(where: { id in
            let id = id.lowercased()
            return name == id || [".", "-", "_"].contains { name.hasPrefix(id + $0) }
        }) { return true }
        if (path as NSString).deletingLastPathComponent == home + "/Library",
           let id = app.bundleID, let company = company(of: id), letters(leaf) == company,
           let space = AppIdentity.namespace(of: id)?.lowercased() {
            return identity.otherOwnerIDs.contains { $0.lowercased().hasPrefix(space) }
        }
        return false
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
                let own = AppIdentity.bundleInfo(atPath: path)?["CFBundleIdentifier"] as? String
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
    public var cancelled: Bool

    public init(apps: [AppBundle], unreadable: [String] = [], cancelled: Bool = false) {
        self.apps = apps
        self.unreadable = unreadable
        self.cancelled = cancelled
    }

    /// Every folder and every bundle was read whole.
    public var isComplete: Bool { !cancelled && unreadable.isEmpty && !apps.contains { $0.incomplete || $0.sizePending } }
}

/// A complete inventory first, then sizes filled in at a bounded rate.
public struct AppListingStep: Sendable {
    public let apps: [AppBundle]
    public let measured: Int

    public init(apps: [AppBundle], measured: Int) {
        self.apps = apps
        self.measured = measured
    }
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
