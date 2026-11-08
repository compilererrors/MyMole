import Darwin
import Foundation
import Synchronization

// Deep Clean on MyMole's own rules: caches, logs and tool downloads in the
// user's own Library and home folder, which apps and tools rebuild by
// themselves. Everything found is moved to the Trash, never deleted, and
// only what the user ticks. System locations that need admin rights are not
// part of it.

/// What a cleanup candidate is.
public enum CleanCategory: String, Sendable, Codable, CaseIterable, Comparable {
    case appCaches, containerCaches, logs, developerCaches, downloads, devices

    public static func < (a: Self, b: Self) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    public var title: String {
        switch self {
        case .appCaches: "App Caches"
        case .containerCaches: "Sandboxed App Caches"
        case .logs: "Logs & Crash Reports"
        case .developerCaches: "Developer Caches"
        case .downloads: "Downloaded Attachments"
        case .devices: "Simulators & Device Backups"
        }
    }

    public var note: String {
        switch self {
        case .appCaches: "Each app's cache folder. Apps rebuild them as needed."
        case .containerCaches: "Caches inside sandboxed apps' containers. Rebuilt the same way."
        case .logs: "Diagnostic logs and crash reports. Nothing reads them back."
        case .developerCaches: "Package managers' download caches and simulator caches. The next install is slower once."
        case .downloads: "Mail attachments you opened. The messages keep them."
        case .devices: "Simulators with what's installed in them, and iPhone and iPad backups. They hold data, so none is ever chosen for you."
        }
    }
}

extension CleanCandidate {
    /// What going costs, said the same way in the list, the check before a
    /// move and its result.
    public var consequence: String {
        switch (category, safety) {
        case (.appCaches, .safe), (.containerCaches, .safe):
            "The app builds it again as it needs it; it may start a little slower once."
        case (.appCaches, .review), (.containerCaches, .review):
            "May hold things the app downloads again, or a sign-in it asks for again."
        case (.logs, _):
            "Nothing builds old logs again; they're only read to look into a problem."
        case (.developerCaches, _):
            "The tool downloads it again when a project needs it; the next install or build is slower once."
        case (.downloads, _):
            "The messages keep their attachments; Mail fetches one again when it's opened."
        case (.devices, _):
            "Holds data: a simulator's apps and content, or a device backup. It's gone for good once the Trash is emptied."
        }
    }
}

/// How sure MyMole is that removing a candidate costs nothing.
public enum CleanSafety: Int, Sendable, Codable, Comparable {
    /// Rebuilt automatically. Chosen by default.
    case safe
    /// Usually fine, but may cost a download or a sign-in. Not chosen by default.
    case review

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var label: String { self == .safe ? "Safe" : "Review" }
}

public struct CleanCandidate: Sendable, Hashable, Codable, Identifiable {
    public let path: String
    public let bytes: Int64
    public let modified: Date
    public let category: CleanCategory
    public let safety: CleanSafety
    /// The bundle ID or tool the data belongs to, when the folder says so.
    public let owner: String?
    public let reason: String
    /// The folder stays and only what's inside goes, for folders tools and
    /// sandboxed apps expect to find in place.
    public let contentsOnly: Bool
    /// Part of it couldn't be read, so its size is a lower bound.
    public var incomplete: Bool = false
    /// What it's called when its folder is named by an ID: a simulator's
    /// or a backed-up device's own name.
    public var title: String?

    public init(
        path: String, bytes: Int64, modified: Date, category: CleanCategory, safety: CleanSafety, owner: String?,
        reason: String, contentsOnly: Bool = false
    ) {
        self.contentsOnly = contentsOnly
        self.path = path
        self.bytes = bytes
        self.modified = modified
        self.category = category
        self.safety = safety
        self.owner = owner
        self.reason = reason
    }

    public var id: String { path }
    public var name: String { title ?? (path as NSString).lastPathComponent }
}

/// The places Deep Clean looks, as MyMole's own rules.
public enum CleanRules {
    public enum Mode: Sendable {
        /// Each item inside the folder is a candidate.
        case children
        /// The folder itself is one candidate.
        case whole
    }

    public struct Target: Sendable {
        public let path: String
        public let mode: Mode
        public let category: CleanCategory
        public let safety: CleanSafety
        public let reason: String
        /// Tools here keep sign-in tokens beside their caches, so an item
        /// holding one is never offered.
        public var screensSecrets = false
        /// What the items are, when each says so in a file of its own.
        public var holds = Holds.plain
        /// What a whole target is called, when its own name says little ("Cache").
        public var title: String? = nil
    }

    public enum Holds: Sendable {
        case plain
        /// Simulator devices: a folder per device with its `device.plist`.
        case simulators
        /// iPhone and iPad backups: a folder per device with its `Info.plist`.
        case backups
    }

    /// Caches macOS uses for iCloud and accounts: rebuilt, but at the cost
    /// of syncing again, so they're offered unticked.
    static let syncedCaches = ["CloudKit", "com.apple.bird", "com.apple.iCloudHelper", "com.apple.akd", "FamilyCircle"]

    /// Never offered, even inside a target: these hold state, not cache.
    static let neverNames: Set<String> = [".DS_Store", "com.apple.containermanagerd", "com.apple.nsurlsessiond"]

    public static func targets(home: String) -> [Target] {
        let lib = home + "/Library"
        return [
            Target(path: lib + "/Caches", mode: .children, category: .appCaches, safety: .safe,
                   reason: "App cache. Rebuilt the next time the app needs it."),
            Target(path: lib + "/Logs", mode: .children, category: .logs, safety: .safe,
                   reason: "Logs and crash reports."),
            Target(path: home + "/.npm/_cacache", mode: .whole, category: .developerCaches, safety: .safe,
                   reason: "npm's download cache."),
            Target(path: home + "/.yarn/berry/cache", mode: .whole, category: .developerCaches, safety: .safe,
                   reason: "Yarn's download cache."),
            Target(path: home + "/.gradle/caches", mode: .whole, category: .developerCaches, safety: .safe,
                   reason: "Gradle's dependency and build cache."),
            Target(path: home + "/.cargo/registry/cache", mode: .whole, category: .developerCaches, safety: .safe,
                   reason: "Cargo's downloaded crates."),
            Target(path: home + "/go/pkg/mod/cache/download", mode: .whole, category: .developerCaches, safety: .review,
                   reason: "Go's module downloads. Offline builds need them."),
            Target(path: home + "/.pnpm-store", mode: .whole, category: .developerCaches, safety: .review,
                   reason: "pnpm's package store. Projects relink from it on the next install."),
            Target(path: home + "/.bun/install/cache", mode: .whole, category: .developerCaches, safety: .safe,
                   reason: "Bun's download cache."),
            Target(path: home + "/.m2/repository", mode: .whole, category: .developerCaches, safety: .review,
                   reason: "Maven's downloaded libraries. Fetched again on the next build, which needs the network."),
            Target(path: home + "/.nuget/packages", mode: .whole, category: .developerCaches, safety: .review,
                   reason: "NuGet's package cache. Fetched again on the next restore, which needs the network."),
            Target(path: lib + "/Developer/Xcode/UserData/Previews", mode: .whole, category: .developerCaches, safety: .safe,
                   reason: "Xcode's builds of SwiftUI previews. Rebuilt when a preview opens."),
            Target(path: home + "/.cache", mode: .children, category: .developerCaches, safety: .review,
                   reason: "A tool's cache. Some hold large downloads such as models.", screensSecrets: true),
            Target(path: lib + "/Developer/CoreSimulator/Caches", mode: .whole, category: .developerCaches, safety: .safe,
                   reason: "Simulator caches."),
            Target(path: lib + "/Developer/Xcode/iOS DeviceSupport", mode: .children, category: .developerCaches,
                   safety: .review, reason: "Debug symbols for one device's OS version. Copied again when that device connects."),
            Target(path: lib + "/Containers/com.apple.mail/Data/Library/Mail Downloads", mode: .whole, category: .downloads,
                   safety: .review, reason: "Attachments Mail saved when you opened them."),
            Target(path: lib + "/Developer/CoreSimulator/Devices", mode: .children, category: .devices, safety: .review,
                   reason: "A simulator that is shut down, with the apps and data in it. Xcode makes a new, empty one when you add it again.",
                   holds: .simulators),
            Target(path: lib + "/Application Support/MobileSync/Backup", mode: .children, category: .devices, safety: .review,
                   reason: "A backup of an iPhone or iPad. It's gone for good unless the device is backed up again.",
                   holds: .backups),
        ] + condaCaches(home: home) + appDataCaches(home: home)
    }

    /// Where the Conda family keeps the packages it downloads, in the
    /// installs it makes in the home folder. Only `pkgs`: environments,
    /// which hold what's installed, stay. Environments link their files
    /// from here, so emptying the Trash frees only what no environment uses.
    static let condaRoots = ["miniconda3", "anaconda3", "miniforge3", "mambaforge", "micromamba", ".conda", ".mamba"]

    static func condaCaches(home: String) -> [Target] {
        condaRoots.map {
            Target(path: home + "/" + $0 + "/pkgs", mode: .whole, category: .developerCaches, safety: .review,
                   reason: "Conda's downloaded packages. Fetched again when an environment needs one, which needs the network; environments keep what they use.")
        }
    }

    /// The folders apps built on Electron and browsers built on Chromium
    /// keep caches in, inside their own data rather than in Caches. Only
    /// these names, never the profile or data around them.
    static let appDataCacheNames = [
        "Cache", "Code Cache", "GPUCache", "CachedData", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
        "Service Worker/CacheStorage", "Service Worker/ScriptCache",
    ]

    /// Browsers built on Chromium: where their profiles are, and the name
    /// their process runs under.
    static let chromium: [(folder: String, process: String)] = [
        ("Google/Chrome", "Google Chrome"), ("BraveSoftware/Brave-Browser", "Brave Browser"),
        ("Microsoft Edge", "Microsoft Edge"), ("Arc/User Data", "Arc"), ("Vivaldi", "Vivaldi"),
    ]

    /// Every such cache that's there: in an app's folder in Application
    /// Support, and in each Chromium profile ("Default", "Profile 1"). Never
    /// ticked for the user: the app should be quit first.
    static func appDataCaches(home: String) -> [Target] {
        let support = home + "/Library/Application Support"
        var roots = (DirectoryListing.names(support) ?? [])
            .filter { !$0.hasPrefix(".") && !$0.hasPrefix("com.apple") && !CleanRules.neverNames.contains($0) }
            .map { support + "/" + $0 }
        for browser in chromium {
            let base = support + "/" + browser.folder
            for profile in DirectoryListing.names(base) ?? [] where profile == "Default" || profile.hasPrefix("Profile ") {
                roots.append(base + "/" + profile)
            }
        }
        return roots.flatMap { root in
            appDataCacheNames.map { root + "/" + $0 }.filter(CleanScanner.isRealFolder).map {
                Target(path: $0, mode: .whole, category: .appCaches, safety: .review,
                       reason: "Cache kept in the app's own data folder. The app rebuilds it; quit the app first.",
                       title: appDataTitle($0, home: home))
            }
        }
    }

    /// The process using a cache in an app's data folder: the browser, or
    /// the app the folder is named after.
    static func appDataTools(_ path: String, home: String) -> [String]? {
        let support = home + "/Library/Application Support/"
        guard path.hasPrefix(support), appDataCacheNames.contains(where: { path.hasSuffix("/" + $0) }) else { return nil }
        let rel = String(path.dropFirst(support.count))
        if let b = chromium.first(where: { rel.hasPrefix($0.folder + "/") }) { return [b.process] }
        return rel.split(separator: "/").first.map { [String($0)] }
    }

    /// "Slack · Code Cache", "Google Chrome Default · GPUCache".
    static func appDataTitle(_ path: String, home: String) -> String? {
        let support = home + "/Library/Application Support/"
        guard path.hasPrefix(support), let cache = appDataCacheNames.first(where: { path.hasSuffix("/" + $0) }) else { return nil }
        let owner = String(path.dropFirst(support.count).dropLast(cache.count + 1))
        if let b = chromium.first(where: { owner.hasPrefix($0.folder + "/") }) {
            return b.process + " " + owner.dropFirst(b.folder.count + 1) + " · " + cache
        }
        return owner + " · " + cache
    }


    /// A property list no bigger than a backup's own description gets.
    private static func plist(_ path: String) -> [String: Any]? {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= 32 << 20,
            let data = FileManager.default.contents(atPath: path)
        else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// A simulator's own description: its name and system, and whether it's shut down.
    static func simulator(_ path: String) -> (title: String, shutDown: Bool)? {
        guard let d = plist(path + "/device.plist"), let name = d["name"] as? String else { return nil }
        // "com.apple.CoreSimulator.SimRuntime.iOS-18-2" is iOS 18.2.
        let runtime = (d["runtime"] as? String)?.split(separator: ".").last.map { s -> String in
            let parts = s.split(separator: "-")
            return parts.count > 1 ? parts[0] + " " + parts.dropFirst().joined(separator: ".") : String(s)
        }
        // 1 is shut down; a device that's booting, booted or shutting down is in use.
        return (runtime.map { name + " · " + $0 } ?? name, (d["state"] as? Int) == 1)
    }

    /// The device a backup is of: "Device Name · iPhone 16".
    static func backup(_ path: String) -> String? {
        guard let d = plist(path + "/Info.plist") else { return nil }
        let parts = [d["Device Name"] as? String, d["Product Name"] as? String ?? d["Product Type"] as? String].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// What an item is called when its folder's name is an ID.
    static func title(of path: String, in t: Target) -> String? {
        switch t.holds {
        case .plain: nil
        case .simulators: simulator(path)?.title
        case .backups: backup(path).map { "Backup of " + $0 }
        }
    }

    /// Safety for one item of a target, raised for caches that resync.
    static func safety(of name: String, in target: Target) -> CleanSafety {
        if syncedCaches.contains(where: name.hasPrefix) { return .review }
        return target.safety
    }

    /// The tools that use a target, by the names `RunningTools` reports.
    /// Their cache is left alone while one of them runs.
    static func tools(for path: String, home: String) -> [String] {
        let lib = home + "/Library"
        switch path {
        case home + "/.npm/_cacache": return ["npm", "npm-cli", "npx", "npx-cli"]
        case home + "/.yarn/berry/cache": return ["yarn"]
        case home + "/.pnpm-store": return ["pnpm"]
        case home + "/.gradle/caches": return ["gradle", "GradleDaemon", "GradleWrapperMain"]
        case home + "/.cargo/registry/cache": return ["cargo"]
        case home + "/go/pkg/mod/cache/download": return ["go"]
        case home + "/.bun/install/cache": return ["bun"]
        case home + "/.m2/repository": return ["mvn", "mvnd"]
        case home + "/.nuget/packages": return ["dotnet"]
        case lib + "/Developer/Xcode/UserData/Previews": return ["Xcode"]
        case lib + "/Developer/CoreSimulator/Caches": return ["Simulator", "simctl"]
        case lib + "/Containers/com.apple.mail/Data/Library/Mail Downloads": return ["Mail"]
        case _ where condaRoots.contains(where: { path == home + "/" + $0 + "/pkgs" }): return ["conda", "mamba", "micromamba"]
        default:
            switch (path as NSString).deletingLastPathComponent {
            case lib + "/Developer/Xcode/iOS DeviceSupport": return ["Xcode"]
            case lib + "/Developer/CoreSimulator/Devices": return ["Simulator", "simctl"]
            default: return appDataTools(path, home: home) ?? []
            }
        }
    }

    /// Whether a tool that uses `path` is running. A process list that
    /// couldn't be read counts as every tool running.
    public static func inUse(_ path: String, home: String, running: Set<String>?) -> Bool {
        let tools = tools(for: path, home: home)
        guard !tools.isEmpty else { return false }
        guard let running else { return true }
        return tools.contains { t in running.contains(t) || running.contains { $0.hasPrefix(t + "-") } }
    }

    /// Names of files that hold sign-in tokens or keys.
    static let secretNames: Set<String> = [".netrc", ".npmrc", "auth.json", "hosts.yml", "id_rsa", "id_ecdsa", "id_ed25519"]
    static let secretWords = ["token", "credential", "secret", "password"]
    static let secretExtensions: Set<String> = ["pem", "key", "p12", "pfx", "keychain", "keychain-db"]

    static func isSecretName(_ name: String) -> Bool {
        let n = name.lowercased()
        return secretNames.contains(n) || secretWords.contains(where: n.contains)
            || secretExtensions.contains((n as NSString).pathExtension)
    }

    /// Whether `path` is, or holds, a file that looks like a token or key.
    /// What can't be looked through counts as holding one: a folder that
    /// can't be read, one nested deeper than `depth`, or more than `limit`
    /// entries in all.
    static func holdsSecrets(_ path: String, depth: Int = 8, limit: Int = 20_000) -> Bool {
        var budget = limit
        return holdsSecrets(path, depth: depth, budget: &budget)
    }

    private static func holdsSecrets(_ path: String, depth: Int, budget: inout Int) -> Bool {
        budget -= 1
        if budget < 0 || isSecretName((path as NSString).lastPathComponent) { return true }
        var st = stat()
        guard lstat(path, &st) == 0 else { return true }
        guard st.st_mode & S_IFMT == S_IFDIR else { return false }
        guard depth > 0, let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return true }
        return names.contains { holdsSecrets(path + "/" + $0, depth: depth - 1, budget: &budget) }
    }

    /// Whether an item of `t` may be offered at all.
    static func offers(_ path: String, in t: Target) -> Bool {
        guard !neverNames.contains((path as NSString).lastPathComponent), !(t.screensSecrets && holdsSecrets(path)) else { return false }
        switch t.holds {
        case .plain: return true
        // Only a device that says it's shut down: the set's own index file
        // and a device that's running are never offered.
        case .simulators: return simulator(path)?.shutDown == true
        case .backups: return isFolder(path)
        }
    }

    private static func isFolder(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
    }

    /// A bundle ID-looking folder name ("com.vendor.App"), as the owner.
    static func owner(of name: String) -> String? {
        let parts = name.split(separator: ".")
        return parts.count >= 3 && parts.allSatisfy({ !$0.isEmpty }) ? name : nil
    }
}

/// The user's own "never clean this" list for Deep Clean.
public struct CleanKeepList: Sendable, Codable, Equatable {
    public var paths: Set<String> = []

    public init(paths: Set<String> = []) { self.paths = paths }

    /// Kept itself, inside something kept, or holding something kept: a
    /// parent folder can't go to the Trash with a kept item inside it.
    public func protects(_ path: String) -> Bool {
        paths.contains { k in path == k || path.hasPrefix(k + "/") || k.hasPrefix(path + "/") }
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MyMole/DeepClean/keep.json")
    }

    /// System Clean's own list: system items the user never wants removed.
    public static var systemURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MyMole/SystemClean/keep.json")
    }

    /// A missing file is an empty list; a file that can't be read or parsed
    /// throws, so nothing is cleaned against a list that didn't load.
    public static func load(from url: URL = defaultURL) throws -> CleanKeepList {
        guard let data = try readIfPresent(url) else { return CleanKeepList() }
        return try JSONDecoder().decode(CleanKeepList.self, from: data)
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    /// Changes the list as it is on disk now, under the file's lock, and
    /// returns what was saved. A list that can't be read is never written
    /// over, and nothing counts as changed unless it was saved.
    public static func update(at url: URL, _ change: (inout CleanKeepList) -> Void) throws -> CleanKeepList {
        let saved = try FileLock.around(url) {
            var list = try load(from: url)
            change(&list)
            try list.save(to: url)
            return list
        }
        KeepChanges.post(url)
        return saved
    }
}

/// The file's contents, or nil only when it doesn't exist. A folder on the
/// way that can't be searched throws instead of passing for a missing file.
func readIfPresent(_ url: URL) throws -> Data? {
    do {
        return try Data(contentsOf: url)
    } catch CocoaError.fileReadNoSuchFile {
        return nil
    }
}

/// What a Deep Clean scan found, and the places it couldn't read.
public struct CleanListing: Sendable {
    public var candidates: [CleanCandidate]
    public var unreadable: [String]

    public init(candidates: [CleanCandidate], unreadable: [String] = []) {
        self.candidates = candidates
        self.unreadable = unreadable
    }

    /// Every place and every candidate was read whole.
    public var isComplete: Bool { unreadable.isEmpty && !candidates.contains(where: \.incomplete) }
}

/// How far a Deep Clean scan has come: places measured of all it will
/// measure, and every candidate found so far, largest first.
public struct CleanScanStep: Sendable {
    public let done: Int
    public let total: Int
    public let found: [CleanCandidate]

    public var fraction: Double { Double(done) / Double(max(total, 1)) }
}

public enum CleanScanner {
    /// Every candidate under `home`, largest first. Caches of sandboxed apps
    /// are measured one container at a time, as walking every container
    /// whole would read all their data too. A cancelled scan returns what
    /// it measured so far; check `progress.isCancelled`.
    public static func scan(
        home: String = Home.path, progress: ScanProgress = ScanProgress(),
        workers: Int = StorageScanner.defaultWorkers
    ) -> [CleanCandidate] {
        list(home: home, progress: progress, workers: workers).candidates
    }

    /// Every candidate, and the places that couldn't be read even though
    /// they're there, so a result without them isn't taken as complete.
    public static func list(
        home: String = Home.path, progress: ScanProgress = ScanProgress(),
        workers: Int = StorageScanner.defaultWorkers, onStep: (@Sendable (CleanScanStep) -> Void)? = nil
    ) -> CleanListing {
        let targets = CleanRules.targets(home: home)
        let containers = containerIDs(home: home)
        let steps = StepCounter(total: targets.count + max(containers?.count ?? 0, 1), onStep: onStep)
        var unreadable: [String] = []
        for t in targets where !progress.isCancelled {
            steps.add(candidates(in: t, progress: progress, workers: workers, unreadable: &unreadable))
        }
        if !progress.isCancelled {
            if let containers {
                containerCaches(home: home, ids: containers, progress: progress, workers: workers, unreadable: &unreadable, steps: steps)
            } else {
                unreadable.append(home + "/Library/Containers")
                steps.add([])
            }
        }
        return CleanListing(candidates: steps.found, unreadable: unreadable.sorted())
    }

    /// Largest first, then by path.
    static func ordered(_ c: [CleanCandidate]) -> [CleanCandidate] {
        c.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
    }

    /// Counts the places measured and hands what's found so far to `onStep`,
    /// from whichever thread finished a place.
    final class StepCounter: Sendable {
        private struct State {
            var done = 0
            var found: [CleanCandidate] = []
        }

        let total: Int
        private let onStep: (@Sendable (CleanScanStep) -> Void)?
        private let state = Mutex(State())

        init(total: Int, onStep: (@Sendable (CleanScanStep) -> Void)?) {
            self.total = max(total, 1)
            self.onStep = onStep
        }

        func add(_ c: [CleanCandidate]) {
            let step = state.withLock { s -> CleanScanStep? in
                s.done += 1
                s.found += c
                return onStep == nil ? nil : CleanScanStep(done: min(s.done, total), total: total, found: CleanScanner.ordered(s.found))
            }
            if let step { onStep?(step) }
        }

        var found: [CleanCandidate] { CleanScanner.ordered(state.withLock { $0.found }) }
    }

    static func candidates(in t: CleanRules.Target, progress: ScanProgress, workers: Int) -> [CleanCandidate] {
        var unreadable: [String] = []
        return candidates(in: t, progress: progress, workers: workers, unreadable: &unreadable)
    }

    static func candidates(in t: CleanRules.Target, progress: ScanProgress, workers: Int, unreadable: inout [String]) -> [CleanCandidate] {
        guard isRealFolder(t.path) else { return [] }
        let r = StorageScanner.scan(path: t.path, progress: progress, workers: workers)
        switch t.mode {
        case .whole:
            guard r.root.size > 0 else {
                if r.root.unreadable || !r.deniedPaths.isEmpty { unreadable.append(t.path) }
                return []
            }
            var c = CleanCandidate(
                path: t.path, bytes: r.root.size, modified: r.root.latestChange, category: t.category, safety: t.safety,
                owner: nil, reason: t.reason, contentsOnly: true)
            c.incomplete = !r.deniedPaths.isEmpty || r.root.unreadable
            c.title = t.title
            return [c]
        case .children:
            // Every entry, small files included: the tree only lists big
            // files one by one.
            let subfolders = Dictionary(r.root.subfolders.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            guard let names = DirectoryListing.names(t.path) else {
                unreadable.append(t.path)
                return []
            }
            return names.filter { CleanRules.offers(t.path + "/" + $0, in: t) }.compactMap { name in
                let path = t.path + "/" + name
                var bytes: Int64
                var modified: Date
                if let f = subfolders[name] {
                    bytes = f.size
                    modified = f.latestChange
                } else {
                    var st = stat()
                    guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
                    bytes = Int64(st.st_blocks) * 512
                    modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
                }
                guard bytes > 0 || subfolders[name]?.unreadable == true else { return nil }
                var c = CleanCandidate(
                    path: path, bytes: bytes, modified: modified, category: t.category,
                    safety: CleanRules.safety(of: name, in: t), owner: CleanRules.owner(of: name), reason: t.reason)
                c.incomplete = subfolders[name]?.unreadable == true || r.deniedPaths.contains { $0 == path || $0.hasPrefix(path + "/") }
                c.title = CleanRules.title(of: path, in: t)
                return c
            }
        }
    }

    static func containerCaches(home: String, progress: ScanProgress, workers: Int, unreadable: inout [String]) -> [CleanCandidate] {
        guard let ids = containerIDs(home: home) else {
            unreadable.append(home + "/Library/Containers")
            return []
        }
        let steps = StepCounter(total: ids.count, onStep: nil)
        containerCaches(home: home, ids: ids, progress: progress, workers: workers, unreadable: &unreadable, steps: steps)
        return steps.found
    }

    /// The app containers whose caches are looked at, nil when the folder
    /// holding them can't be read.
    static func containerIDs(home: String) -> [String]? {
        DirectoryListing.names(home + "/Library/Containers")?
            .filter { !$0.hasPrefix(".") && !CleanRules.neverNames.contains($0) }
            .sorted()
    }

    static func containerCaches(
        home: String, ids: [String], progress: ScanProgress, workers: Int, unreadable: inout [String], steps: StepCounter
    ) {
        let base = home + "/Library/Containers"
        let denied = Mutex<[String]>([])
        // Most are tiny; a few run at once, each with one walker.
        let next = Atomic<Int>(0)
        DispatchQueue.concurrentPerform(iterations: max(1, min(workers, 8))) { _ in
            while !progress.isCancelled {
                let i = next.add(1, ordering: .relaxed).oldValue
                guard i < ids.count else { return }
                let path = base + "/" + ids[i] + "/Data/Library/Caches"
                var c: CleanCandidate?
                defer { steps.add(c.map { [$0] } ?? []) }
                var st = stat()
                guard lstat(path, &st) == 0 else {
                    // Not there is fine; there but closed (another app's data) isn't seen.
                    if errno != ENOENT && errno != ENOTDIR { denied.withLock { $0.append(path) } }
                    continue
                }
                guard st.st_mode & S_IFMT == S_IFDIR else { continue }
                let r = StorageScanner.scan(path: path, progress: progress, workers: 1)
                guard r.root.size > 0 else {
                    if r.root.unreadable || !r.deniedPaths.isEmpty { denied.withLock { $0.append(path) } }
                    continue
                }
                var one = CleanCandidate(
                    path: path, bytes: r.root.size, modified: r.root.latestChange, category: .containerCaches,
                    safety: ids[i].hasPrefix("com.apple.") ? .review : .safe, owner: ids[i],
                    reason: ids[i].hasPrefix("com.apple.")
                        ? "Cache of one of Apple's apps. Rebuilt, though some resync first."
                        : "Cache inside the app's sandbox. Rebuilt the next time the app needs it.",
                    contentsOnly: true)
                one.incomplete = !r.deniedPaths.isEmpty || r.root.unreadable
                c = one
            }
        }
        unreadable += denied.withLock { $0 }
    }

    /// What actually goes to the Trash for a candidate: the item itself, or
    /// everything inside it. Kept items are left out.
    public static func trashPaths(for c: CleanCandidate, keep: CleanKeepList) -> [String] {
        guard c.contentsOnly else { return keep.protects(c.path) ? [] : [c.path] }
        // Emptied only while it's a real folder reached without a link: a
        // folder above it swapped for a link would list someone else's files.
        guard isRealFolder(c.path), Trasher.noLinksBetween(c.path, and: c.path) else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: c.path)) ?? []
        return names.sorted().map { c.path + "/" + $0 }.filter { !keep.protects($0) }
    }

    static func isRealFolder(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
    }

    /// Checked again right before a candidate goes to the Trash: still
    /// where a rule puts it, with no link on the way or at the end. Keep
    /// rules are applied to each path by `trashPaths`.
    public static func isStillCandidate(_ path: String, home: String = Home.path) -> Bool {
        let p = path
        guard Trasher.isPlainPath(p), !Trasher.isProtected(p, home: home), Trasher.noLinksBetween(home, and: p) else { return false }
        var st = stat()
        guard lstat(p, &st) == 0, st.st_mode & S_IFMT == S_IFDIR || st.st_mode & S_IFMT == S_IFREG else { return false }
        let parent = (p as NSString).deletingLastPathComponent
        for t in CleanRules.targets(home: home) {
            switch t.mode {
            case .whole where p == t.path: return true
            case .children where parent == t.path: return CleanRules.offers(p, in: t)
            default: continue
            }
        }
        // A sandboxed app's cache: ~/Library/Containers/<id>/Data/Library/Caches.
        let containers = home + "/Library/Containers/"
        guard p.hasPrefix(containers), p.hasSuffix("/Data/Library/Caches") else { return false }
        let id = p.dropFirst(containers.count).dropLast("/Data/Library/Caches".count)
        return !id.isEmpty && !id.contains("/")
    }
}

/// The last complete Deep Clean scan, so the pane opens on it at once. Tied
/// to the home folder and the rules' format.
public enum CleanStore {
    /// 2: candidates say when part of them couldn't be read.
    static let formatVersion = 2

    public struct Saved: Sendable, Codable {
        public let version: Int
        public let home: String
        public let date: Date
        public let candidates: [CleanCandidate]
    }

    public static var defaultBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MyMole/DeepClean")
    }

    public static func load(home: String, base: URL = defaultBase) -> Saved? {
        guard let d = try? Data(contentsOf: base.appending(path: "last.json")),
            let saved = try? JSONDecoder().decode(Saved.self, from: d),
            saved.version == formatVersion, saved.home == home
        else { return nil }
        return saved
    }

    /// Only a scan that read everything replaces the saved one.
    public static func save(_ listing: CleanListing, home: String, date: Date = Date(), base: URL = defaultBase) {
        guard listing.isComplete else { return }
        let saved = Saved(version: formatVersion, home: home, date: date, candidates: listing.candidates)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(saved) { try? d.write(to: base.appending(path: "last.json"), options: .atomic) }
    }
}
