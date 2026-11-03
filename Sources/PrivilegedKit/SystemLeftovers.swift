import Darwin
import Foundation
import StorageKit

/// What an app left outside your Library, in places only root may change:
/// its system-wide data and settings, its launchd jobs and privileged
/// helper, and the installer's record of it. The app finds them, the
/// helper checks every path against these rules again and removes them.
/// Only exact bundle IDs in the vendor's namespace are matched, never
/// names, and never Apple's.
public enum SystemLeftovers {
    public enum Kind: String, Codable, Sendable {
        case rebuildable, appPart, record, settings, data

        public var chosenByDefault: Bool { self == .rebuildable || self == .appPart || self == .record }

        public var title: String {
            switch self {
            case .rebuildable: "Rebuilt"
            case .appPart: "App part"
            case .record: "Installer record"
            case .settings: "Settings"
            case .data: "Data"
            }
        }
    }

    enum Rule { case exactID, idPlist, jobPlist, idOrPart, receipt }

    struct Place {
        let folder: String
        let rule: Rule
        let kind: Kind
    }

    /// Launch daemons come first: a job is stopped before its program goes.
    static let places: [Place] = [
        Place(folder: "/Library/LaunchDaemons", rule: .jobPlist, kind: .appPart),
        Place(folder: "/Library/LaunchAgents", rule: .jobPlist, kind: .appPart),
        Place(folder: "/Library/PrivilegedHelperTools", rule: .idOrPart, kind: .appPart),
        Place(folder: "/Library/Caches", rule: .exactID, kind: .rebuildable),
        Place(folder: "/Library/Logs", rule: .exactID, kind: .rebuildable),
        Place(folder: "/Library/Preferences", rule: .idPlist, kind: .settings),
        Place(folder: "/Library/Application Support", rule: .exactID, kind: .data),
        Place(folder: "/private/var/db/receipts", rule: .receipt, kind: .record),
    ]

    static let launchctl = "/bin/launchctl"

    /// An ID safe to match system-wide: three or more reverse-DNS parts,
    /// not Apple's.
    public static func isUsable(_ id: String) -> Bool {
        AppLeftovers.isWellFormed(id) && id.split(separator: ".").count >= 3 && !id.lowercased().hasPrefix("com.apple.")
    }

    static func matches(_ entry: String, id: String, rule: Rule) -> Bool {
        switch rule {
        case .exactID: entry == id
        case .idPlist: entry == id + ".plist"
        case .jobPlist: entry.hasSuffix(".plist") && (entry == id + ".plist" || entry.hasPrefix(id + "."))
        case .idOrPart: entry == id || entry.hasPrefix(id + ".")
        case .receipt:
            (entry.hasSuffix(".bom") || entry.hasSuffix(".plist"))
                && (entry.hasPrefix(id + ".") || entry == id + ".bom" || entry == id + ".plist")
        }
    }

    /// Every leftover of `ids` under `base` (empty: the real system), daemons first.
    public static func find(ids: [String], base: String = "") -> [SystemLeftover] {
        let usable = ids.filter(isUsable)
        guard !usable.isEmpty else { return [] }
        var out: [SystemLeftover] = []
        for place in places {
            let dir = base + place.folder
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
            where usable.contains(where: { matches(name, id: $0, rule: place.rule) }) {
                let path = dir + "/" + name
                guard let bytes = size(path) else { continue }
                out.append(SystemLeftover(path: path, bytes: bytes, place: place.folder, kind: place.kind))
            }
        }
        return out
    }

    /// Right inside one of the places, plainly written, a real file or
    /// folder, and named after one of `ids` by that place's rule.
    static func allowed(_ path: String, ids: [String], base: String = "") -> Place? {
        guard Trasher.isPlainPath(path) else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard let place = places.first(where: { base + $0.folder == parent }), name != Staging.containerName,
            ids.filter(isUsable).contains(where: { matches(name, id: $0, rule: place.rule) }),
            size(path) != nil
        else { return nil }
        return place
    }

    /// What every app still installed answers to: its bundle ID and the
    /// identities it carries, from /Applications (and one level of folders
    /// in it) and each user's Applications folder. Nil when /Applications
    /// can't be read: then ownership can't be checked and nothing goes.
    static func installedOwners(base: String) -> Set<String>? {
        guard let top = try? FileManager.default.contentsOfDirectory(atPath: base + "/Applications") else { return nil }
        var folders = [base + "/Applications"]
        folders += top.filter { !$0.hasSuffix(".app") && !$0.hasPrefix(".") }.map { base + "/Applications/" + $0 }
        for user in (try? FileManager.default.contentsOfDirectory(atPath: base + "/Users")) ?? [] where !user.hasPrefix(".") {
            let apps = base + "/Users/" + user + "/Applications"
            folders.append(apps)
            folders += ((try? FileManager.default.contentsOfDirectory(atPath: apps)) ?? [])
                .filter { !$0.hasSuffix(".app") && !$0.hasPrefix(".") }.map { apps + "/" + $0 }
        }
        var owners = Set<String>()
        for dir in folders {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".app") {
                let app = dir + "/" + name
                if let id = NSDictionary(contentsOfFile: app + "/Contents/Info.plist")?["CFBundleIdentifier"] as? String {
                    owners.insert(id)
                }
                owners.formUnion(AppIdentity.carried(atPath: app))
            }
        }
        return owners
    }

    /// The IDs a request may name: the app's own, and others in the app's
    /// vendor namespace. Anything else a client sends is ignored.
    static func requestable(appID: String, ids: [String]) -> [String] {
        guard isUsable(appID), let space = AppIdentity.namespace(of: appID) else { return [] }
        return Array(Set([appID] + ids.filter { isUsable($0) && $0.hasPrefix(space) })).sorted()
    }

    /// Removes what passes `allowed`, permanently. Nothing goes while the
    /// app itself is installed, and no entry that matches an app still
    /// installed, or something one carries, whatever the request says. A
    /// launch daemon's job is stopped first; one that can't be stopped stays.
    /// One removal runs at a time; each stages only its own entries.
    public static func remove(
        _ paths: [String], appID: String, ids: [String], base: String = "",
        runner: CommandRunner = .processes(timeLimit: 30)
    ) -> RemovalReport {
        Staging.lock.lock()
        defer { Staging.lock.unlock() }
        var report = RemovalReport()
        let all = requestable(appID: appID, ids: ids)
        guard !all.isEmpty, let owners = installedOwners(base: base), !owners.contains(appID) else {
            report.refused = paths
            return report
        }
        let order = Dictionary(uniqueKeysWithValues: places.enumerated().map { (base + $1.folder, $0) })
        let sorted = Set(paths).sorted {
            let a = order[($0 as NSString).deletingLastPathComponent] ?? .max
            let b = order[($1 as NSString).deletingLastPathComponent] ?? .max
            return a != b ? a < b : $0 < $1
        }
        var staging = Staging()
        defer { staging.finish() }
        for path in sorted {
            let name = (path as NSString).lastPathComponent
            guard let place = allowed(path, ids: all, base: base),
                !owners.contains(where: { matches(name, id: $0, rule: place.rule) })
            else {
                report.refused.append(path)
                continue
            }
            if place.folder == "/Library/LaunchDaemons", let label = label(path),
                all.contains(where: { label == $0 || label.hasPrefix($0 + ".") })
            {
                if let why = stop(label, runner: runner) {
                    report.failed[path] = why
                    continue
                }
            }
            removeStaged(path, staging: &staging, recheck: { size($0) != nil }, size: { size($0) ?? 0 }, report: &report)
        }
        return report
    }

    /// Stops a launch daemon. Nil when it's stopped or wasn't loaded; why
    /// it may still run otherwise.
    static func stop(_ label: String, runner: CommandRunner) -> String? {
        let r = runner.run(launchctl, ["bootout", "system/" + label])
        // 3: no such process; 113: no such service. Both mean not loaded.
        if r.code == 0 || r.code == 3 || r.code == 113 { return nil }
        if r.code == CommandRunner.timedOut { return "Its job didn't stop in time, so it stays." }
        return "Its job couldn't be stopped (launchctl \(r.code)), so it stays."
    }

    /// A launchd job's label, when it's a well-formed ID.
    static func label(_ plist: String) -> String? {
        guard let label = NSDictionary(contentsOfFile: plist)?["Label"] as? String, AppLeftovers.isWellFormed(label) else { return nil }
        return label
    }

    /// Size of a real file or folder, nil for anything else.
    static func size(_ path: String) -> Int64? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        switch st.st_mode & S_IFMT {
        case S_IFDIR: return StorageScanner.scan(path: path, workers: 2).root.size
        case S_IFREG: return Int64(st.st_blocks) * 512
        default: return nil
        }
    }
}

public struct SystemLeftover: Codable, Sendable, Hashable, Identifiable {
    public let path: String
    public let bytes: Int64
    public let place: String
    public let kind: SystemLeftovers.Kind

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }

    public init(path: String, bytes: Int64, place: String, kind: SystemLeftovers.Kind) {
        self.path = path
        self.bytes = bytes
        self.place = place
        self.kind = kind
    }
}
