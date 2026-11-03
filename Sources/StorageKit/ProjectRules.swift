import Foundation

/// The user's corrections to what MyMole finds: folders it missed that
/// should be cleaned, and folders or files it offers that must never be.
/// Keeping wins over cleaning, and both win over MyMole's own rules.
public struct ProjectRules: Sendable, Codable, Equatable {
    /// Folders to clean, each with the project it belongs to (it may live
    /// outside that project, like a cache in ~/Library).
    public var cleanPaths: [String: String] = [:]
    /// Folder names cleaned in every project.
    public var cleanNames: Set<String> = []
    /// Folders and files never offered for cleaning.
    public var keepPaths: Set<String> = []
    /// Names never offered for cleaning, in every project.
    public var keepNames: Set<String> = []

    public init() {}

    public var isEmpty: Bool { cleanPaths.isEmpty && cleanNames.isEmpty && keepPaths.isEmpty && keepNames.isEmpty }
    public var count: Int { cleanPaths.count + cleanNames.count + keepPaths.count + keepNames.count }

    public func keeps(_ path: String) -> Bool {
        keepPaths.contains(path) || keepNames.contains((path as NSString).lastPathComponent)
    }

    public func cleans(_ path: String) -> Bool {
        !keeps(path) && (cleanPaths[path] != nil || cleanNames.contains((path as NSString).lastPathComponent))
    }

    /// Kept itself, or inside a kept folder.
    public func protects(_ path: String) -> Bool {
        keeps(path) || keepPaths.contains { path.hasPrefix($0 + "/") }
    }

    /// Kept, inside something kept, or holding something kept, or a folder
    /// that can't be looked through for what it holds: may not go whole.
    public func guards(_ path: String) -> Bool {
        protects(path) || keptInside(path).map { !$0.isEmpty } ?? true
    }

    /// What may go to the Trash for `path`: the path itself or, when
    /// something kept is inside it, everything around what's kept. Nothing
    /// when that can't be told, such as a folder that can't be read through.
    public func trashPaths(for path: String) -> [String] {
        guard !protects(path), let kept = keptInside(path) else { return [] }
        return Self.split(path, around: kept)
    }

    /// Kept paths below `path`, or nil when a folder that might hold a kept
    /// name couldn't be read. Links aren't followed.
    func keptInside(_ path: String) -> Set<String>? {
        var found = Set(keepPaths.filter { $0.hasPrefix(path + "/") })
        guard !keepNames.isEmpty, Self.isRealFolder(path) else { return found }
        var stack = [path]
        while let dir = stack.popLast() {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
            for name in names {
                let p = dir + "/" + name
                if keepNames.contains(name) {
                    found.insert(p)
                } else if Self.isRealFolder(p) {
                    stack.append(p)
                }
            }
        }
        return found
    }

    static func split(_ path: String, around kept: Set<String>) -> [String] {
        if kept.contains(path) { return [] }
        guard kept.contains(where: { $0.hasPrefix(path + "/") }) else { return [path] }
        // Only a real folder can be opened up; a link would lead elsewhere.
        guard isRealFolder(path), let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }
        return names.sorted().flatMap { split(path + "/" + $0, around: kept) }
    }

    static func isRealFolder(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
    }

    /// Both sets of rules at once: kept by either is kept. For checking a
    /// run against what's on disk as well as what's in memory.
    public func merging(_ other: ProjectRules) -> ProjectRules {
        var r = self
        r.keepPaths.formUnion(other.keepPaths)
        r.keepNames.formUnion(other.keepNames)
        r.cleanPaths.merge(other.cleanPaths) { a, _ in a }
        r.cleanNames.formUnion(other.cleanNames)
        return r
    }

    /// Names that can't be made cleanable everywhere: they're the projects'
    /// own history and settings.
    static let neverCleanNames: Set<String> = [".git", ".svn", ".hg", ".docs", "Sources", "src", "Tests"]

    /// Whether `path` may be marked for cleaning as part of `project`: not
    /// the project itself or anything above it, not its history, not a
    /// protected location.
    public static func canClean(_ path: String, project: String, home: String = Home.path) -> Bool {
        let p = Trasher.lexical(path)
        if p == project || project.hasPrefix(p + "/") { return false }
        if (p as NSString).lastPathComponent == ".git" || p.contains("/.git/") { return false }
        return !Trasher.isProtected(p, home: home)
    }

    public static func canCleanEverywhere(name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !neverCleanNames.contains(name)
    }

    /// Splits outside items into what stays offered and what the user kept.
    func applied(toOutside items: [FootprintItem], home: String) -> [FootprintItem] {
        var out: [FootprintItem] = []
        var kept: [FootprintEntry] = []
        for var item in items {
            let (k, rest) = (item.entries.filter { keeps($0.path) }, item.entries.filter { !keeps($0.path) })
            kept += k
            item.entries = rest
            if !rest.isEmpty { out.append(item) }
        }
        if !kept.isEmpty {
            out.append(
                FootprintItem(
                    id: "outside:kept", category: .kept, title: "Kept by you", location: home,
                    attribution: .user, entries: kept))
        }
        return out
    }
}
