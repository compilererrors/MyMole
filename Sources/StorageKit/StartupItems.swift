import Darwin
import Foundation

/// A job launchd starts by itself: at login, at boot, or on a schedule. The
/// jobs an app registers from inside its own bundle aren't files in these
/// folders; macOS lists those in System Settings → Login Items.
public struct StartupItem: Sendable, Hashable, Identifiable {
    public enum Scope: String, Sendable, CaseIterable {
        /// The user's own agents, in ~/Library/LaunchAgents.
        case user
        /// Agents for every user, in /Library/LaunchAgents.
        case everyUser
        /// Daemons that run as root, in /Library/LaunchDaemons.
        case system

        public var title: String {
            switch self {
            case .user: "Your login agent"
            case .everyUser: "All users' agent"
            case .system: "System daemon"
            }
        }
    }

    /// The job's property list.
    public let path: String
    public let label: String
    /// What it runs, when the list says so.
    public let program: String?
    public let scope: Scope
    public let runsAtLoad: Bool
    public let keepsAlive: Bool
    public let scheduled: Bool
    /// Marked "Disabled" in its own list.
    public let disabled: Bool
    /// It names a program that isn't there any more.
    public let programMissing: Bool
    /// The app the program is inside, by the app's name.
    public let app: String?
    public let modified: Date
    public let bytes: Int64
    /// What kind of plug-in it is; nil for a launchd job.
    public var plugin: PluginKind? = nil

    public var id: String { path }
    public var name: String { label }

    /// "Starts at login · stays running": when it runs, in a few words.
    public var summary: String {
        if let plugin { return plugin.detail }
        var parts: [String] = []
        if disabled { parts.append("Turned off in its own file") }
        if runsAtLoad { parts.append(scope == .system ? "Starts at boot" : "Starts at login") }
        if keepsAlive { parts.append("stays running") }
        if scheduled { parts.append("runs on a schedule") }
        if parts.isEmpty { parts.append("Starts when something asks for it") }
        return parts.joined(separator: " · ")
    }
}

/// What a look through the launch folders found, and the folders that
/// are there but couldn't be read.
public struct StartupListing: Sendable {
    public var items: [StartupItem]
    public var unreadable: [String]
    /// Job lists that are there but couldn't be read as one: too big, or
    /// not a property list. They aren't shown as items.
    public var broken: [String]

    public init(items: [StartupItem], unreadable: [String] = [], broken: [String] = []) {
        self.items = items
        self.unreadable = unreadable
        self.broken = broken
    }
}

public enum StartupItems {
    /// A job's list is small; one past this isn't read.
    static let maxBytes = 1 << 20

    /// The folders launchd reads jobs from, outside the system's own.
    /// `root` stands in for "/" in tests.
    public static func folders(home: String, root: String = "") -> [(path: String, scope: StartupItem.Scope)] {
        [
            (home + "/Library/LaunchAgents", .user),
            (root + "/Library/LaunchAgents", .everyUser),
            (root + "/Library/LaunchDaemons", .system),
        ]
    }

    /// Every job in the launch folders, the user's own first, then by label.
    public static func list(home: String = Home.path, root: String = "") -> StartupListing {
        var items: [StartupItem] = []
        var unreadable: [String] = []
        var broken: [String] = []
        for (folder, scope) in folders(home: home, root: root) {
            var st = stat()
            // Not there is fine: most Macs have no agents of the user's own.
            guard lstat(folder, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { continue }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else {
                unreadable.append(folder)
                continue
            }
            for name in names where name.hasSuffix(".plist") {
                let path = folder + "/" + name
                if let item = read(path, scope: scope) {
                    items.append(item)
                } else if isPlainFile(path) {
                    // A link isn't followed and isn't a job; a plain file that doesn't read as one is said.
                    broken.append(path)
                }
            }
        }
        let order = StartupItem.Scope.allCases
        items.sort {
            $0.scope != $1.scope
                ? order.firstIndex(of: $0.scope)! < order.firstIndex(of: $1.scope)!
                : $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
        return StartupListing(items: items, unreadable: unreadable, broken: broken.sorted())
    }

    private static func isPlainFile(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFREG
    }

    /// One job from its list; nil for a link, a list too big to be one, or
    /// a file that isn't a property list.
    static func read(_ path: String, scope: StartupItem.Scope) -> StartupItem? {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= maxBytes,
            let data = FileManager.default.contents(atPath: path),
            let d = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return nil }
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let program = d["Program"] as? String ?? (d["ProgramArguments"] as? [String])?.first
        // KeepAlive is a yes or no, or the conditions under which it's kept alive.
        let keepsAlive = d["KeepAlive"] as? Bool ?? (d["KeepAlive"] is [String: Any])
        return StartupItem(
            path: path, label: d["Label"] as? String ?? name, program: program, scope: scope,
            runsAtLoad: d["RunAtLoad"] as? Bool ?? false, keepsAlive: keepsAlive,
            scheduled: d["StartInterval"] != nil || d["StartCalendarInterval"] != nil,
            disabled: d["Disabled"] as? Bool ?? false,
            programMissing: program.map(isMissing) ?? false, app: program.flatMap(app),
            modified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)), bytes: Int64(st.st_blocks) * 512)
    }

    /// A full path with nothing at it. A bare command name is looked up by
    /// launchd, so it isn't called missing.
    private static func isMissing(_ program: String) -> Bool {
        guard program.hasPrefix("/") else { return false }
        var st = stat()
        return stat(program, &st) != 0 && errno == ENOENT
    }

    /// "Example" for a program inside /Applications/Example.app.
    private static func app(_ program: String) -> String? {
        guard let end = program.range(of: ".app/") else { return nil }
        let bundle = program[..<end.lowerBound]
        return bundle.split(separator: "/").last.map(String.init)
    }

    /// Checked again right before a job's list goes to the Trash: still a
    /// plain file directly in the user's own LaunchAgents folder, with no
    /// link on the way. The folders that need an administrator are never
    /// touched.
    public static func isStillRemovable(_ path: String, home: String = Home.path) -> Bool {
        guard Trasher.isPlainPath(path), path.hasSuffix(".plist"),
            (path as NSString).deletingLastPathComponent == home + "/Library/LaunchAgents",
            !Trasher.isProtected(path, home: home), Trasher.noLinksBetween(home, and: path)
        else { return false }
        var st = stat()
        return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFREG
    }
}
