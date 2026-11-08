import Darwin
import Foundation

/// Discovery only. A vendor updater is not proof of exclusive ownership by an app.
public enum RelatedComponents {
    public enum Scope: Equatable, Sendable { case user, system }
    public enum Kind: Equatable, Sendable { case updater, backgroundJob }
    public struct Component: Identifiable, Equatable, Sendable {
        public let path: String
        public let scope: Scope
        public let kind: Kind
        public var id: String { path }
    }
    public struct Report: Sendable {
        public var components: [Component] = []
        public var unreadable: [String] = []
        public init() {}
    }

    public static func isChrome(_ app: AppBundle) -> Bool {
        guard let id = app.bundleID?.lowercased() else { return false }
        return id == "com.google.chrome" || id.hasPrefix("com.google.chrome.")
    }

    public static func find(for app: AppBundle, home: String = Home.path, systemBase: String = "") -> Report {
        guard !app.isProtected, app.bundleID?.lowercased().hasPrefix("com.google.") == true else { return Report() }
        var report = Report()
        let roots: [(String, Scope)] = [(home + "/Library", .user), (systemBase + "/Library", .system)]
        for (library, scope) in roots {
            for relative in ["Application Support/Google/GoogleUpdater", "Google/GoogleSoftwareUpdate"] {
                let path = library + "/" + relative
                switch inspect(relative, in: library, directory: true) {
                case .present: report.components.append(Component(path: path, scope: scope, kind: .updater))
                case .unreadable: report.unreadable.append(path)
                case .missing: break
                }
            }
            for folder in scope == .user ? ["LaunchAgents"] : ["LaunchAgents", "LaunchDaemons"] {
                let dir = library + "/" + folder
                switch inspect(folder, in: library, directory: true) {
                case .missing: continue
                case .unreadable:
                    report.unreadable.append(dir)
                    continue
                case .present: break
                }
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
                    report.unreadable.append(dir)
                    continue
                }
                for name in names.sorted() where updaterJob(name) {
                    let relative = folder + "/" + name
                    switch inspect(relative, in: library, directory: false) {
                    case .present: report.components.append(Component(path: dir + "/" + name, scope: scope, kind: .backgroundJob))
                    case .unreadable: report.unreadable.append(dir + "/" + name)
                    case .missing: break
                    }
                }
            }
        }
        report.components.sort { $0.path < $1.path }
        report.unreadable = Array(Set(report.unreadable)).sorted()
        return report
    }

    private static func updaterJob(_ name: String) -> Bool {
        let name = name.lowercased()
        return name.hasSuffix(".plist") && ["com.google.googleupdater.", "com.google.keystone."].contains(where: name.hasPrefix)
    }

    private enum Inspection { case present, missing, unreadable }

    /// Inspect only named locations. Do not follow a directory or leaf symlink.
    private static func inspect(_ relative: String, in root: String, directory: Bool) -> Inspection {
        var path = root
        let parts = [""] + relative.split(separator: "/").map(String.init)
        for (index, part) in parts.enumerated() {
            if !part.isEmpty { path += "/" + part }
            var st = stat()
            guard lstat(path, &st) == 0 else { return errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable }
            let expected = index < parts.count - 1 || directory ? S_IFDIR : S_IFREG
            guard st.st_mode & S_IFMT == expected else { return .unreadable }
        }
        return .present
    }
}
