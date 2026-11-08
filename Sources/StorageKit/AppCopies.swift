import Darwin
import Foundation

public struct AppCopy: Sendable, Equatable, Identifiable {
    public enum Source: String, Sendable, Hashable { case applications, registered, indexed, folder }
    public enum BuildHint: Sendable, Equatable { case buildFolder, developmentLabel }
    public let app: AppBundle
    public let build: String?
    public let modified: Date
    public let hint: BuildHint?
    public let integrations: AppIntegrations.Report
    public var sources: Set<Source>
    private let device: Int32
    private let inode: UInt64
    struct FileIdentity: Hashable { let device: Int32; let inode: UInt64 }
    var fileIdentity: FileIdentity { FileIdentity(device: device, inode: inode) }
    public var id: String { app.path }

    public func isCurrent() -> Bool {
        var st = stat()
        return lstat(app.path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR && st.st_dev == device && st.st_ino == inode
            && AppIdentity.bundleInfo(atPath: app.path)?["CFBundleIdentifier"] as? String == app.bundleID
    }

    public static func read(_ path: String, source: Source, progress: ScanProgress = ScanProgress()) -> AppCopy? {
        guard !progress.isCancelled, isStandalonePath(path) else { return nil }
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { return nil }
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard isStandalonePath(canonical),
              let info = AppIdentity.bundleInfo(atPath: canonical), let id = info["CFBundleIdentifier"] as? String,
              AppLeftovers.isWellFormed(id) else { return nil }
        let fallback = ((canonical as NSString).lastPathComponent as NSString).deletingPathExtension
        let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? fallback
        var app = AppBundle(path: canonical, name: name.isEmpty ? fallback : name, bundleID: id,
                            version: info["CFBundleShortVersionString"] as? String, bytes: 0, fromAppStore: false)
        app.sizePending = true
        let parts = Set(canonical.lowercased().split(separator: "/").map(String.init))
        let buildFolder = !parts.isDisjoint(with: [".build", "deriveddata", "debug", "release", "local-test", "build", "builds"])
        let markers: Set<String> = ["qa", "test", "tests", "debug", "dev", "development", "nightly", "staging", "beta", "preview"]
        let labels = Set((name + " " + id).lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let copy = AppCopy(app: app, build: info["CFBundleVersion"] as? String,
                           modified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)),
                           hint: buildFolder ? .buildFolder : (!labels.isDisjoint(with: markers) ? .developmentLabel : nil),
                           integrations: AppIntegrations.read(canonical, info: info, progress: progress), sources: [source], device: st.st_dev, inode: st.st_ino)
        return copy.isCurrent() && !progress.isCancelled ? copy : nil
    }

    static func isStandalonePath(_ path: String) -> Bool {
        Trasher.isPlainPath(path) && path.lowercased().hasSuffix(".app") && !path.contains("/.Trash/") && !path.contains("/.Trashes/")
        && !path.split(separator: "/").dropLast().contains(where: { part in
            ["app", "appex", "xpc", "framework"].contains((String(part) as NSString).pathExtension.lowercased())
        })
    }
}

/// Metadata-only discovery. Matching IDs mean copies/versions, never byte-identical files.
public enum AppCopies {
    public struct Report: Sendable {
        public var copies: [AppCopy] = []
        public var unreadable: [String] = []
        public var indexedUnavailable = false
        public var registrationUnavailable = false
        public var missingRegistered: [String] = []
        public var limited = false
        public var cancelled = false
        public init() {}
    }

    public static let maximumApps = 20_000
    static let indexQuery = "kMDItemContentType == \"com.apple.application-bundle\""

    /// Publish the small Applications inventory before looking through the system index.
    public static func inventory(
        in folders: [String], runner: CommandRunner, registered: (String) -> [String]?, progress: ScanProgress,
        onStep: (Report) -> Void = { _ in }
    ) -> Report {
        let inventory = AppFinder.inventory(in: folders, progress: progress)
        var report = Report()
        report.unreadable = inventory.unreadable
        append(inventory.apps.map(\.path), source: .applications, to: &report, progress: progress)
        onStep(report)
        let ids = Set(report.copies.compactMap { $0.app.bundleID }).sorted()
        var registeredPaths: [String] = []
        for id in ids where !progress.isCancelled {
            guard registeredPaths.count < maximumApps else { report.limited = true; break }
            if let paths = registered(id) {
                let room = maximumApps - registeredPaths.count
                if paths.count > room { report.limited = true }
                registeredPaths += paths.prefix(room)
            }
            else { report.registrationUnavailable = true }
        }
        append(registeredPaths, source: .registered, to: &report, progress: progress)
        onStep(report)
        if !progress.isCancelled {
            if runner.exists(AppSiblings.mdfind) {
                let (code, output) = runner.run(AppSiblings.mdfind, ["-0", indexQuery])
                if code == 0 {
                    append(output.split(separator: "\0").map(String.init), source: .indexed, to: &report, progress: progress)
                } else { report.indexedUnavailable = true }
            } else { report.indexedUnavailable = true }
        }
        report.cancelled = progress.isCancelled
        report.copies.sort { $0.app.path < $1.app.path }
        return report
    }

    /// Explicitly selected roots include build outputs that Spotlight often skips.
    /// App bundles are leaves; dependency trees, links and other volumes aren't followed.
    public static func addingFolders(_ roots: [String], to base: Report, progress: ScanProgress, entryLimit: Int = 100_000) -> Report {
        var report = base
        var visited = Set<String>()
        var entries = 0
        var appPaths: [String] = []
        let ignored: Set<String> = [".git", ".svn", ".Trash", ".Trashes", "node_modules", "__pycache__"]
        for root in roots where !progress.isCancelled {
            var st = stat()
            guard Trasher.isPlainPath(root), lstat(root, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else {
                report.unreadable.append(root); continue
            }
            let canonical = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
            var pending = [(canonical, 0)]
            while let (path, depth) = pending.popLast(), !progress.isCancelled {
                guard visited.insert(path).inserted else { continue }
                guard Trasher.noLinksBetween(canonical, and: path) else { report.unreadable.append(path); continue }
                if path.lowercased().hasSuffix(".app") {
                    appPaths.append(path)
                    if appPaths.count >= 128 {
                        append(appPaths, source: .folder, to: &report, progress: progress)
                        appPaths.removeAll(keepingCapacity: true)
                    }
                    continue
                }
                guard depth < 24, entries < entryLimit, report.copies.count < maximumApps else { report.limited = true; continue }
                var children: [String] = []
                let outcome = DirectoryReader.read(path, isCancelled: { progress.isCancelled || entries >= entryLimit }) { entry in
                    entries += 1
                    guard entry.kind == .folder, entry.device == st.st_dev, !ignored.contains(entry.name),
                          !["framework", "bundle", "appex", "xpc"].contains((entry.name as NSString).pathExtension.lowercased()) else { return }
                    children.append(path + "/" + entry.name)
                }
                if entries >= entryLimit { report.limited = true }
                if outcome == .denied || outcome == .failed { report.unreadable.append(path) }
                pending += children.map { ($0, depth + 1) }
            }
        }
        append(appPaths, source: .folder, to: &report, progress: progress)
        report.unreadable = Array(Set(report.unreadable)).sorted()
        report.cancelled = progress.isCancelled
        report.copies.sort { $0.app.path < $1.app.path }
        return report
    }

    private static func append(_ paths: [String], source: AppCopy.Source, to report: inout Report, progress: ScanProgress) {
        var positions = Dictionary(uniqueKeysWithValues: report.copies.enumerated().map { ($0.element.id, $0.offset) })
        var identities = Dictionary(uniqueKeysWithValues: report.copies.enumerated().map { ($0.element.fileIdentity, $0.offset) })
        for path in paths.prefix(maximumApps) where !progress.isCancelled {
            guard AppCopy.isStandalonePath(path) else { continue }
            guard report.copies.count < maximumApps else { report.limited = true; break }
            if let index = positions[path] { report.copies[index].sources.insert(source); continue }
            guard let copy = AppCopy.read(path, source: source, progress: progress) else {
                // Stale index entries are not installed apps. A present, unreadable
                // bundle is reported so an empty result never claims completeness.
                var st = stat()
                let status = lstat(path, &st)
                if status != 0 {
                    if errno == ENOENT || errno == ENOTDIR {
                        if source == .registered { report.missingRegistered.append(path) }
                    } else { report.unreadable.append(path) }
                } else if st.st_mode & S_IFMT == S_IFDIR,
                        AppCopy.isStandalonePath(URL(fileURLWithPath: path).resolvingSymlinksInPath().path) {
                    report.unreadable.append(path)
                }
                continue
            }
            if let index = positions[copy.id] ?? identities[copy.fileIdentity] { report.copies[index].sources.insert(source) }
            else {
                positions[copy.id] = report.copies.count
                identities[copy.fileIdentity] = report.copies.count
                report.copies.append(copy)
            }
        }
        if paths.count > maximumApps { report.limited = true }
        report.unreadable = Array(Set(report.unreadable)).sorted()
        report.missingRegistered = Array(Set(report.missingRegistered)).sorted()
    }

    public static func counts(_ copies: [AppCopy]) -> [String: Int] {
        Dictionary(grouping: copies, by: { $0.app.bundleID!.lowercased() }).mapValues(\.count)
    }
}
