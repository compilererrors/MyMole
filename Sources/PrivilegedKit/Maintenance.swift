import Darwin
import Foundation
import StorageKit

// MyMole's maintenance tasks. Each one is a fixed action with a fixed
// program and fixed arguments; nothing is built from user input. Tasks that
// need root run only in the privileged helper, the rest in the app itself.

public enum MaintenanceTask: String, CaseIterable, Codable, Sendable, Identifiable {
    case quickLook, launchServices, savedState, brokenPreferences, networkDSStore
    case flushDNS, periodic, spotlight, verifyDisk

    public enum Group: String, CaseIterable, Sendable {
        case finder = "Finder & Apps"
        case network = "Network"
        case system = "System"
    }

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .quickLook: "Quick Look Thumbnails"
        case .launchServices: "“Open With” Database"
        case .savedState: "Old Window States"
        case .brokenPreferences: "Broken Settings Files"
        case .networkDSStore: "No .DS_Store on Network Drives"
        case .flushDNS: "DNS Cache"
        case .periodic: "Housekeeping Scripts"
        case .spotlight: "Spotlight Index"
        case .verifyDisk: "Startup Disk Check"
        }
    }

    /// What it disturbs while it runs, and what can't be undone: so a task
    /// is run for its problem, not as a general speed-up.
    public var effect: String {
        switch self {
        case .quickLook: "Finder makes thumbnails again as you browse. Nothing to undo."
        case .launchServices: "An app may ask once which app opens a kind of file. Can't be undone; macOS keeps it up to date from then on."
        case .savedState: "Undo puts them back."
        case .brokenPreferences: "Undo puts them back."
        case .networkDSStore: "A Finder setting; Finder's folder views on those drives aren't remembered from then on."
        case .flushDNS: "Sites look up their address again on the next visit. Nothing to undo."
        case .periodic: "Runs a few minutes in the background. Trimmed logs can't be put back."
        case .spotlight: "Search misses files until the rebuild ends, which can take hours and keeps the disk busy. Can't be undone."
        case .verifyDisk: "Only reads; the disk is busier while it runs."
        }
    }

    public var explanation: String {
        switch self {
        case .quickLook: "Resets the thumbnail cache, for blank or outdated previews in Finder."
        case .launchServices: "Rebuilds the list of which app opens what. Fixes duplicate apps in “Open With”. Takes a minute."
        case .savedState: "Moves window states apps saved over 30 days ago to the Trash. Those apps open with fresh windows."
        case .brokenPreferences: "Moves settings files that can no longer be read to the Trash, so their apps start from defaults."
        case .networkDSStore: "Tells Finder not to leave .DS_Store files on network shares and USB drives. Changes a Finder setting."
        case .flushDNS: "Clears the DNS cache, for websites that won't load or still point to an old address."
        case .periodic: "Runs macOS's daily, weekly and monthly housekeeping scripts, which rotate and trim system logs."
        case .spotlight: "Erases and rebuilds the Spotlight index of the startup disk. Search is incomplete for a while."
        case .verifyDisk: "Checks the startup disk's file system for errors. Read-only; nothing is changed."
        }
    }

    public var symbol: String {
        switch self {
        case .quickLook: "photo.on.rectangle"
        case .launchServices: "arrow.up.forward.app"
        case .savedState: "macwindow.on.rectangle"
        case .brokenPreferences: "wrench.adjustable"
        case .networkDSStore: "externaldrive.badge.xmark"
        case .flushDNS: "globe"
        case .periodic: "calendar.badge.clock"
        case .spotlight: "magnifyingglass"
        case .verifyDisk: "internaldrive"
        }
    }

    public var group: Group {
        switch self {
        case .quickLook, .launchServices, .savedState, .brokenPreferences, .networkDSStore: .finder
        case .flushDNS: .network
        case .periodic, .spotlight, .verifyDisk: .system
        }
    }

    /// Runs as root, through the privileged helper.
    public var needsRoot: Bool {
        switch self {
        case .flushDNS, .periodic, .spotlight, .verifyDisk: true
        default: false
        }
    }

    /// Works inside the App Sandbox: only tasks that move the user's own
    /// files. The rest drive macOS's tools or need root.
    public var worksInSandbox: Bool { self == .savedState || self == .brokenPreferences }

    /// On unless the user turns it off. Slow, disruptive or setting-changing
    /// tasks start off.
    public var onByDefault: Bool {
        switch self {
        // Only what fixes something most Macs gather; DNS and the index are for a problem you have.
        case .quickLook, .savedState, .brokenPreferences, .verifyDisk: true
        default: false
        }
    }
}

/// What a check or a run found for one task.
public struct TaskReport: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        /// The run would do something.
        case willRun
        case nothingToDo
        case done
        case failed
        /// Can't run on this Mac.
        case unavailable
        /// Needs root, and the helper isn't available.
        case needsHelper
    }

    public let task: MaintenanceTask
    public let status: Status
    public let detail: String

    public init(_ task: MaintenanceTask, _ status: Status, _ detail: String = "") {
        self.task = task
        self.status = status
        self.detail = detail
    }
}

/// Checks and runs maintenance tasks. The app's engine refuses root tasks;
/// the helper's engine refuses everything else, as it has no user home.
public struct MaintenanceEngine: Sendable {
    public enum Role: Sendable { case user, root }

    static let qlmanage = "/usr/bin/qlmanage"
    static let lsregister =
        "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
    static let defaults = "/usr/bin/defaults"
    static let dscacheutil = "/usr/bin/dscacheutil"
    static let killall = "/usr/bin/killall"
    static let periodic = "/usr/sbin/periodic"
    static let mdutil = "/usr/bin/mdutil"
    static let diskutil = "/usr/sbin/diskutil"

    public static let savedStateAge: TimeInterval = 30 * 86_400
    /// A settings file must have been left alone this long before it counts
    /// as broken: an app may be halfway through writing it.
    public static let settledFor: TimeInterval = 10 * 60
    /// Finder's settings that keep .DS_Store files off shared drives.
    static let dsStoreKeys = ["DSDontWriteNetworkStores", "DSDontWriteUSBStores"]

    public let role: Role
    public let home: String
    public let runner: CommandRunner
    public let now: @Sendable () -> Date
    /// Where files go instead of being deleted; tests use their own folder.
    public let trash: @Sendable ([String], TrashGate) -> TrashOutcome
    /// Bundle IDs of the apps running now. Their window states and settings
    /// are never touched, whatever they look like.
    public let running: @Sendable () -> Set<String>
    /// What the user keeps (Deep Clean's keep list and the paths kept in
    /// Projects), read as a move runs. Only the user's tasks move files; the
    /// root ones never do, so they keep nothing.
    public let protections: @Sendable () throws -> @Sendable (String) -> Bool

    public init(
        role: Role, home: String = Home.path, runner: CommandRunner = .live,
        now: @escaping @Sendable () -> Date = { Date() },
        trash: @escaping @Sendable ([String], TrashGate) -> TrashOutcome = { Trasher.moveToTrash($0, through: $1) },
        running: @escaping @Sendable () -> Set<String> = { [] },
        protections: @escaping @Sendable () throws -> @Sendable (String) -> Bool = TrashGate.keepsNothing
    ) {
        self.protections = protections
        self.role = role
        self.home = home
        self.runner = runner
        self.now = now
        self.trash = trash
        self.running = running
    }

    func allowed(_ t: MaintenanceTask) -> Bool { t.needsRoot == (role == .root) }

    /// What a run would do, without changing anything.
    public func check(_ t: MaintenanceTask) -> TaskReport {
        guard allowed(t) else { return TaskReport(t, .needsHelper, "Needs the privileged helper.") }
        switch t {
        case .savedState:
            let n = oldSavedStates().count
            return n == 0 ? TaskReport(t, .nothingToDo, "No window states older than 30 days.")
                : TaskReport(t, .willRun, "\(n) old window state\(n == 1 ? "" : "s") to move to the Trash.")
        case .brokenPreferences:
            let n = brokenPreferences().count
            return n == 0 ? TaskReport(t, .nothingToDo, "Every settings file reads fine.")
                : TaskReport(t, .willRun, "\(n) unreadable settings file\(n == 1 ? "" : "s") to move to the Trash.")
        case .networkDSStore:
            let off = dsStoreKeysOff()
            if off.isEmpty { return TaskReport(t, .nothingToDo, "Already turned on.") }
            return TaskReport(t, .willRun, off.count == 2 ? "Finder still writes them." : off == ["DSDontWriteUSBStores"]
                ? "Finder still writes them on USB drives." : "Finder still writes them on network drives.")
        default:
            let exes = programs(t)
            guard exes.allSatisfy(runner.exists) else { return TaskReport(t, .unavailable, "Not available on this version of macOS.") }
            return TaskReport(t, .willRun)
        }
    }

    public func run(_ t: MaintenanceTask) -> TaskReport {
        guard allowed(t) else { return TaskReport(t, .needsHelper, "Needs the privileged helper.") }
        switch t {
        case .savedState:
            return moveToTrash(oldSavedStates(), t, what: "window state", still: isOldSavedState)
        case .brokenPreferences:
            return moveToTrash(brokenPreferences(), t, what: "settings file", still: isBrokenPreference)
        case .networkDSStore:
            let off = dsStoreKeysOff()
            guard !off.isEmpty else { return TaskReport(t, .nothingToDo, "Already turned on.") }
            for key in off {
                let r = runner.run(Self.defaults, ["write", "com.apple.desktopservices", key, "-bool", "true"])
                if r.code != 0 { return TaskReport(t, .failed, Self.lastLine(r.output) ?? "Exited with code \(r.code).") }
            }
            return TaskReport(t, .done)
        default:
            let pre = check(t)
            guard pre.status == .willRun else { return pre }
            for (exe, args) in commands(t) {
                let r = runner.run(exe, args)
                // killall exits 1 when the process isn't running, which is fine.
                if r.code != 0 && !(exe == Self.killall && r.code == 1) {
                    return TaskReport(t, .failed, Self.lastLine(r.output) ?? "Exited with code \(r.code).")
                }
            }
            return TaskReport(t, .done, t == .verifyDisk ? "No problems found." : "")
        }
    }

    func programs(_ t: MaintenanceTask) -> [String] { Array(Set(commands(t).map(\.0))) }

    func commands(_ t: MaintenanceTask) -> [(String, [String])] {
        switch t {
        case .quickLook: [(Self.qlmanage, ["-r", "cache"]), (Self.qlmanage, ["-r"])]
        case .launchServices: [(Self.lsregister, ["-kill", "-r", "-domain", "local", "-domain", "system", "-domain", "user"])]
        case .networkDSStore: [(Self.defaults, ["read", "com.apple.desktopservices"])]
        case .flushDNS: [(Self.dscacheutil, ["-flushcache"]), (Self.killall, ["-HUP", "mDNSResponder"])]
        case .periodic: [(Self.periodic, ["daily", "weekly", "monthly"])]
        case .spotlight: [(Self.mdutil, ["-E", "/"])]
        case .verifyDisk: [(Self.diskutil, ["verifyVolume", "/"])]
        case .savedState, .brokenPreferences: []
        }
    }

    static func lastLine(_ s: String) -> String? {
        s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
    }

    var savedStateFolder: String { home + "/Library/Saved Application State" }
    var preferencesFolder: String { home + "/Library/Preferences" }

    func oldSavedStates() -> [String] {
        entries(savedStateFolder).map { savedStateFolder + "/" + $0 }.filter(isOldSavedState)
    }

    /// Which of Finder's .DS_Store settings aren't on yet.
    func dsStoreKeysOff() -> [String] {
        Self.dsStoreKeys.filter { key in
            let r = runner.run(Self.defaults, ["read", "com.apple.desktopservices", key])
            return !(r.code == 0 && ["1", "true", "yes"].contains(r.output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()))
        }
    }

    /// The bundle ID a window state or settings file is named after.
    static func owner(of path: String, suffix: String) -> String {
        String((path as NSString).lastPathComponent.dropLast(suffix.count))
    }

    /// A window state folder right inside its folder whose app isn't running
    /// and where nothing inside has changed for long enough: an app can
    /// update the files without touching the folder's own date.
    @Sendable func isOldSavedState(_ path: String) -> Bool {
        guard (path as NSString).deletingLastPathComponent == savedStateFolder, path.hasSuffix(".savedState"),
            Trasher.noLinksBetween(home, and: path), !running().contains(Self.owner(of: path, suffix: ".savedState"))
        else { return false }
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { return false }
        let r = StorageScanner.scan(path: path, workers: 1)
        guard !r.cancelled, r.deniedPaths.isEmpty else { return false }
        let newest = max(Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)), r.root.latestChange)
        return newest < now().addingTimeInterval(-Self.savedStateAge)
    }

    func brokenPreferences() -> [String] {
        entries(preferencesFolder).map { preferencesFolder + "/" + $0 }.filter(isBrokenPreference)
    }

    /// A settings file right inside Preferences that exists but can't be
    /// parsed, left alone for a while, of an app that isn't running. Empty
    /// files count: apps can't read them either.
    @Sendable func isBrokenPreference(_ path: String) -> Bool {
        guard (path as NSString).deletingLastPathComponent == preferencesFolder, path.hasSuffix(".plist"),
            Trasher.noLinksBetween(home, and: path), !running().contains(Self.owner(of: path, suffix: ".plist"))
        else { return false }
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG,
            Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)) < now().addingTimeInterval(-Self.settledFor)
        else { return false }
        guard let data = FileManager.default.contents(atPath: path) else { return false }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) == nil
    }

    func entries(_ dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
    }

    func moveToTrash(_ paths: [String], _ t: MaintenanceTask, what: String, still: @escaping @Sendable (String) -> Bool) -> TaskReport {
        guard !paths.isEmpty else { return TaskReport(t, .nothingToDo) }
        let out = self.trash(paths, TrashGate(still: still, protections: protections))
        let n = out.moved.count
        if !out.failed.isEmpty {
            return TaskReport(t, .failed, "Moved \(n); \(out.failed.count) couldn't be moved.")
        }
        return TaskReport(t, .done, "Moved \(n) \(what)\(n == 1 ? "" : "s") to the Trash.")
    }
}
