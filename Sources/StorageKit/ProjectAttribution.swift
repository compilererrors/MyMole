import Darwin
import Foundation

// MARK: - Outside the project

/// Data outside the projects' folders, and the places that were there but
/// couldn't be read, so a result without them isn't taken as complete.
public struct OutsideData: Sendable {
    public var items: [String: [FootprintItem]]
    public var unreadable: [String]
}

public enum ProjectAttribution {
    /// Places that couldn't be read while attributing, in the order met.
    final class Misses {
        var paths: [String] = []

        /// The names in `dir`; none when it isn't there, and none noted as
        /// missed when it's there but can't be read.
        func names(_ dir: String) -> [String] {
            guard let names = DirectoryListing.names(dir) else {
                paths.append(dir)
                return []
            }
            return names
        }
    }

    /// Data outside the projects' folders, per project path.
    public static func items(
        for projects: [DevProject], home: String = Home.path, rules: ProjectRules = ProjectRules()
    ) -> [String: [FootprintItem]] {
        find(for: projects, home: home, rules: rules).items
    }

    /// Data outside the projects' folders, and what couldn't be read.
    public static func find(
        for projects: [DevProject], home: String = Home.path, rules: ProjectRules = ProjectRules()
    ) -> OutsideData {
        let misses = Misses()
        var out: [String: [FootprintItem]] = [:]
        func add(_ found: [String: [FootprintEntry]], id: String, category: FootprintCategory, title: String,
                 location: String, attribution: Attribution) {
            for (project, entries) in found where !entries.isEmpty {
                out[project, default: []].append(
                    FootprintItem(
                        id: id, category: category, title: title, location: location, attribution: attribution,
                        entries: entries))
            }
        }
        add(codexSessions(projects, home: home, misses: misses), id: "codex:sessions", category: .agentSessions,
            title: "Codex sessions", location: home + "/.codex", attribution: .recorded)
        add(claudeSessions(projects, home: home, misses: misses), id: "claude:projects", category: .agentSessions,
            title: "Claude Code sessions", location: home + "/.claude/projects", attribution: .recorded)
        add(derivedData(projects, home: home, misses: misses), id: "xcode:deriveddata", category: .build,
            title: "Xcode DerivedData", location: home + "/Library/Developer/Xcode/DerivedData", attribution: .recorded)
        for folder in libraryFolders {
            let location = home + "/Library/" + folder
            add(nameMatches(projects, in: location, misses: misses), id: "library:\(folder)", category: .appData,
                title: folder, location: location, attribution: .nameMatch)
        }
        // Folders the user tied to a project from outside it.
        let paths = Set(projects.map(\.path))
        var added: [String: [FootprintEntry]] = [:]
        for (path, project) in rules.cleanPaths where paths.contains(project) && !path.hasPrefix(project + "/") {
            if let entry = measure(path, misses: misses) { added[project, default: []].append(entry) }
        }
        add(added, id: "user:marked", category: .marked, title: "Added by you", location: home, attribution: .user)
        let items = rules.isEmpty ? out : out.mapValues { rules.applied(toOutside: $0, home: home) }.filter { !$0.value.isEmpty }
        return OutsideData(items: items, unreadable: misses.paths)
    }

    // MARK: Codex

    /// Each Codex session is a JSONL file whose first line records the
    /// folder it ran in (`"cwd"`).
    static func codexSessions(_ projects: [DevProject], home: String, misses: Misses = Misses()) -> [String: [FootprintEntry]] {
        var out: [String: [FootprintEntry]] = [:]
        for dir in ["sessions", "archived_sessions"] {
            let base = home + "/.codex/" + dir
            guard !misses.names(base).isEmpty, let e = FileManager.default.enumerator(atPath: base) else { continue }
            while let rel = e.nextObject() as? String {
                guard rel.hasSuffix(".jsonl") else { continue }
                let path = base + "/" + rel
                guard let cwd = codexCwd(path), let owner = ProjectFinder.owner(of: cwd, in: projects),
                    let entry = measure(path, misses: misses)
                else { continue }
                out[owner.path, default: []].append(entry)
            }
        }
        return out
    }

    /// The `cwd` of a Codex session, from the start of its file.
    static func codexCwd(_ path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: 64 * 1024) else { return nil }
        // Lossy: the read can end in the middle of a character.
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.range(of: "\"cwd\":\"") else { return nil }
        var value = ""
        var escaped = false
        for ch in text[start.upperBound...] {
            if escaped {
                value.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                return value.isEmpty ? nil : (value as NSString).standardizingPath
            } else {
                value.append(ch)
            }
        }
        return nil
    }

    // MARK: Claude Code

    /// Claude Code keeps one folder per working directory in
    /// `~/.claude/projects`, named after its path with every character other
    /// than a letter or digit turned into `-`. A worktree inside a project
    /// (`…-Brightpad--claude-worktrees-x`) belongs to that project.
    static func claudeSessions(_ projects: [DevProject], home: String, misses: Misses = Misses()) -> [String: [FootprintEntry]] {
        let base = home + "/.claude/projects"
        let encoded = projects.map { (claudeKey($0.path), $0.path) }.sorted { $0.0.count > $1.0.count }
        var out: [String: [FootprintEntry]] = [:]
        for name in misses.names(base) {
            guard let owner = encoded.first(where: { name == $0.0 || name.hasPrefix($0.0 + "-") })?.1 else { continue }
            // One entry per session, so old ones can go and recent ones stay.
            let dir = base + "/" + name
            for child in misses.names(dir) {
                if let entry = measure(dir + "/" + child, misses: misses) { out[owner, default: []].append(entry) }
            }
        }
        return out
    }

    static func claudeKey(_ path: String) -> String {
        String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    // MARK: Xcode

    /// Each DerivedData folder's info.plist names the workspace it builds.
    static func derivedData(_ projects: [DevProject], home: String, misses: Misses = Misses()) -> [String: [FootprintEntry]] {
        let base = home + "/Library/Developer/Xcode/DerivedData"
        var out: [String: [FootprintEntry]] = [:]
        for name in misses.names(base) where !name.hasPrefix(".") {
            let dir = base + "/" + name
            guard let plist = NSDictionary(contentsOfFile: dir + "/info.plist"),
                let workspace = plist["WorkspacePath"] as? String,
                let owner = ProjectFinder.owner(of: (workspace as NSString).standardizingPath, in: projects),
                let entry = measure(dir, misses: misses)
            else { continue }
            out[owner.path, default: []].append(entry)
        }
        return out
    }

    // MARK: ~/Library, by name

    static let libraryFolders = [
        "Containers", "Group Containers", "Caches", "Application Support", "Logs", "HTTPStorages", "WebKit",
        "Saved Application State", "Preferences",
    ]

    /// Names too common to tie anything to a project on their own.
    static let commonNames: Set<String> = [
        "apple", "google", "microsoft", "github", "gitlab", "azure", "amazon", "docker", "slack", "chrome",
        "firefox", "safari", "mozilla", "adobe", "jetbrains", "atom", "code", "vscode", "test", "tests", "demo",
        "example", "sample", "samples", "backup", "backups", "data", "config", "cache", "caches", "build",
        "local", "tools", "utils", "common", "shared", "core", "main", "master", "server", "client", "service",
        "services", "android", "macos", "swift", "java", "node", "python", "project", "projects", "workspace",
        "source", "sources", "apps", "addon", "plugin", "plugins", "group", "cert", "certs", "docs", "site",
        "home", "user", "users", "temp", "work", "notes", "mobile", "desktop", "web", "app", "api",
    ]

    /// The name a project is matched by in bundle IDs, if it's distinctive:
    /// letters and digits only, lowercased, at least four of them.
    static func nameKey(_ project: DevProject) -> String? {
        let key = String(project.name.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
        return key.count >= 4 && !commonNames.contains(key) ? key : nil
    }

    /// Items in `folder` whose name has the project's name as one of its
    /// parts: `com.quikzip.workflow.1f7e…` and `QuikZip` both belong to a
    /// project called QuikZip. Apple's own items are never matched.
    static func nameMatches(_ projects: [DevProject], in folder: String, misses: Misses = Misses()) -> [String: [FootprintEntry]] {
        var byKey: [String: String] = [:]
        var ambiguous = Set<String>()
        for p in projects {
            guard let k = nameKey(p) else { continue }
            if byKey[k] != nil { ambiguous.insert(k) }
            byKey[k] = p.path
        }
        for k in ambiguous { byKey[k] = nil }
        guard !byKey.isEmpty else { return [:] }

        var out: [String: [FootprintEntry]] = [:]
        for name in misses.names(folder) {
            let lower = name.lowercased()
            if lower.hasPrefix("com.apple.") || lower.hasPrefix("group.com.apple.") || lower.hasPrefix(".") { continue }
            let base = lower.hasSuffix(".plist") ? String(lower.dropLast(6)) : lower
            // Last part first: in `com.vendor.product` the product is the
            // more specific match when both are project names.
            var parts = base.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init).reversed()
                .map { $0 }
            parts.append(String(base.filter { $0.isLetter || $0.isNumber }))
            guard let owner = parts.lazy.compactMap({ byKey[$0] }).first, let entry = measure(folder + "/" + name, misses: misses)
            else { continue }
            out[owner, default: []].append(entry)
        }
        return out
    }

    // MARK: Measuring

    /// Size on disk and newest change of a file or folder (the folder's
    /// whole subtree, read with the disk map's scanner).
    static func measure(_ path: String, misses: Misses = Misses()) -> FootprintEntry? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
        switch st.st_mode & S_IFMT {
        case S_IFDIR:
            let r = StorageScanner.scan(path: path)
            if !r.deniedPaths.isEmpty || r.root.unreadable { misses.paths.append(path) }
            let latest = r.root.latestChange == .distantPast ? mtime : max(r.root.latestChange, mtime)
            return FootprintEntry(path: path, bytes: r.root.size, modified: latest, isDirectory: true, reclaim: r.root.reclaim)
        case S_IFREG:
            return FootprintEntry(path: path, bytes: Int64(st.st_blocks) * 512, modified: mtime, isDirectory: false, reclaim: Reclaim.file(at: path))
        default:
            return nil
        }
    }
}
