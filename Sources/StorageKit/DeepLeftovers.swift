import Darwin
import Foundation

/// The deeper search for what an app left, which the user turns on: more
/// is found, and less surely the app's, so nothing it finds is chosen.
///
/// - The app's name, as letters and digits only and without a trailing
///   version ("Bartender 6" → "bartender"), inside a longer entry name in
///   the Library's app folders, and one level further down in Application
///   Support, Caches and Logs.
/// - A hidden folder in the home folder named after the app: `~/.name`,
///   `~/.config/name`, `~/.cache/name`, `~/.local/share/name`, `~/.local/state/name`.
///
/// Never Apple's, never an entry another installed app's name or ID is
/// also in, and a name too short to tell apart (under five letters) isn't
/// looked for.
public enum DeepLeftovers {
    /// Library folders looked through, and those also one level down.
    static let places = [
        "Application Support", "Caches", "Logs", "Preferences", "Containers", "HTTPStorages", "WebKit", "Saved Application State",
    ]
    static let nested: Set<String> = ["Application Support", "Caches", "Logs"]
    /// Hidden folders in the home folder, by where tools keep their own.
    static let homePlaces: [(folder: String, place: String)] = [
        ("", "Home"), (".config", "~/.config"), (".cache", "~/.cache"), (".local/share", "~/.local/share"),
        (".local/state", "~/.local/state"),
    ]

    /// "bartender" of "Bartender 6": letters and digits, lower case, no version.
    static func key(_ name: String) -> String {
        var k = name.lowercased().filter { $0.isLetter || $0.isNumber }
        while let last = k.last, last.isNumber { k.removeLast() }
        return k
    }

    /// An entry's name as letters and digits, without the ending a file has.
    static func letters(_ entry: String) -> String {
        let base = ["plist", "savedstate", "binarycookies", "log"].contains((entry as NSString).pathExtension.lowercased())
            ? (entry as NSString).deletingPathExtension : entry
        return base.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// What the app answers to: its name's key, five letters or more.
    static func key(of app: AppBundle) -> String? {
        let k = key(app.name)
        let shared: Set<String> = ["cache", "caches", "config", "configuration", "local", "shared", "state", "support", "library"]
        return k.count >= 5 && !AppLeftovers.genericNames.contains(k) && !shared.contains(k) ? k : nil
    }

    /// Whether `entry` holds the app's key and no other installed app's name or ID.
    static func matches(_ entry: String, app: AppBundle, key: String, installed: [AppBundle]) -> Bool {
        let l = letters(entry)
        let idName = (entry.hasPrefix(".") ? String(entry.dropFirst()) : entry).lowercased()
        guard l.contains(key), !idName.hasPrefix("com.apple."), !idName.hasPrefix("group.com.apple.") else {
            return false
        }
        return !installed.contains { other in
            guard other.path != app.path else { return false }
            if let k = Self.key(of: other), l.contains(k) { return true }
            if let id = other.bundleID?.lowercased(), id != app.bundleID?.lowercased(), idName.hasPrefix(id) { return true }
            return false
        }
    }

    static func libraryMatch(_ entry: String, app: AppBundle, installed: [AppBundle]) -> Bool {
        let name = entry.hasPrefix(".") ? String(entry.dropFirst()) : entry
        if let id = app.bundleID, name == id || name == id + ".plist" { return true }
        guard let key = key(of: app) else { return false }
        return matches(entry, app: app, key: key, installed: installed)
    }

    public static func find(for app: AppBundle, home: String = Home.path, installed: [AppBundle], progress: ScanProgress = ScanProgress()) -> [Leftover] {
        guard !app.isProtected, let id = app.bundleID, AppLeftovers.isWellFormed(id), !id.lowercased().hasPrefix("com.apple."),
            !installed.contains(where: { $0.path != app.path && $0.bundleID == id }) else { return [] }
        var out: [Leftover] = []
        func add(_ path: String, place: String) {
            guard !progress.isCancelled, isStill(path, of: app, home: home, installed: installed), let m = AppLeftovers.measure(path, progress: progress) else { return }
            var l = Leftover(path: path, bytes: m, place: place)
            l.evidence = .loose
            out.append(l)
        }
        let lib = home + "/Library"
        for place in places where !progress.isCancelled {
            let dir = lib + "/" + place
            guard AppFinder.isRealFolder(dir), Trasher.noLinksBetween(home, and: dir) else { continue }
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where !progress.isCancelled {
                let p = dir + "/" + entry
                if libraryMatch(entry, app: app, installed: installed) {
                    add(p, place: place)
                } else if nested.contains(place), AppFinder.isRealFolder(p), !entry.lowercased().hasPrefix("com.apple.") {
                    let entries = (try? FileManager.default.contentsOfDirectory(atPath: p)) ?? []
                    for inner in entries where !progress.isCancelled && libraryMatch(inner, app: app, installed: installed) {
                        add(p + "/" + inner, place: place)
                    }
                }
            }
        }
        for (folder, place) in homePlaces where !progress.isCancelled {
            let dir = folder.isEmpty ? home : home + "/" + folder
            // Check parents before listing them, so a linked .config is not traversed.
            guard AppFinder.isRealFolder(dir), Trasher.noLinksBetween(home, and: dir) else { continue }
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            for entry in entries where !progress.isCancelled && homeMatch(entry, hidden: folder.isEmpty, app: app, installed: installed) {
                add(dir + "/" + entry, place: place)
            }
        }
        return out
    }

    /// An exact ID works even for a short app name; names must be unambiguous.
    static func homeMatch(_ entry: String, hidden: Bool, app: AppBundle, installed: [AppBundle]) -> Bool {
        guard !hidden || entry.hasPrefix("."), let id = app.bundleID else { return false }
        let name = hidden ? String(entry.dropFirst()) : entry
        if name.lowercased() == id.lowercased() { return true }
        guard let key = key(of: app), Self.key(name) == key else { return false }
        return !installed.contains { $0.path != app.path && Self.key($0.name) == key }
    }

    /// Checked again right before a move: by the same rules, with no link on the way.
    public static func isStill(_ path: String, of app: AppBundle, home: String, installed: [AppBundle]) -> Bool {
        guard !app.isProtected, let id = app.bundleID, AppLeftovers.isWellFormed(id), !id.lowercased().hasPrefix("com.apple."),
            !installed.contains(where: { $0.path != app.path && $0.bundleID == id }),
            Trasher.isPlainPath(path), !Trasher.isProtected(path, home: home),
            path.hasPrefix(home + "/"), Trasher.noLinksBetween(home, and: path)
        else { return false }
        let rel = String(path.dropFirst(home.count + 1))
        let parts = rel.split(separator: "/").map(String.init)
        let entry = parts.last ?? ""
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR || st.st_mode & S_IFMT == S_IFREG else { return false }
        // ~/.name
        if parts.count == 1 { return homeMatch(entry, hidden: true, app: app, installed: installed) }
        // ~/.config/name and the like
        let folder = parts.dropLast().joined(separator: "/")
        if homePlaces.contains(where: { !$0.folder.isEmpty && $0.folder == folder }) {
            return homeMatch(entry, hidden: false, app: app, installed: installed)
        }
        guard parts.first == "Library" else { return false }
        let inLib = parts.dropFirst().dropLast().joined(separator: "/")
        if places.contains(inLib) { return libraryMatch(entry, app: app, installed: installed) }
        // One level down: "<place>/<folder>/<entry>"
        let up = parts.dropFirst().dropLast().dropLast().joined(separator: "/")
        return nested.contains(up) && !parts[parts.count - 2].lowercased().hasPrefix("com.apple.")
            && libraryMatch(entry, app: app, installed: installed)
    }
}
