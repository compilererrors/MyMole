import Darwin
import Foundation

// Development projects and everything they leave on disk.
//
// A project's footprint is more than its folder. Build tools write output
// next to the code (`.build`, `target`, `node_modules`), coding agents keep
// transcripts per project in their home folders (`~/.codex`,
// `~/.claude/projects`), Xcode keeps DerivedData, and test builds of an app
// leave containers and caches under `~/Library`. MyMole finds projects,
// sorts what's inside each into rebuildable and kept parts, and attributes
// outside data back to the project it belongs to:
//
// • recorded — the tool stored the project's path with it (Codex sessions,
//   Claude Code's per-project folders, Xcode's DerivedData info.plist);
// • name match — a `~/Library` item whose bundle ID contains the project's
//   name. Weaker, so it's labelled as such and never chosen on its own.

/// A folder with a project file in it.
public struct DevProject: Sendable, Hashable, Codable, Identifiable {
    public let path: String
    /// The files that identify it ("Package.swift", ".git").
    public let markers: [String]

    public init(path: String, markers: [String]) {
        self.path = path
        self.markers = markers
    }

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }

    /// What the project is built with, from its project files, for display.
    public var kind: String {
        let known: [(String, String)] = [
            ("Package.swift", "Swift"), (".xcodeproj", "Xcode"), (".xcworkspace", "Xcode"), ("Cargo.toml", "Rust"),
            ("go.mod", "Go"), ("package.json", "Node"), ("pyproject.toml", "Python"), ("setup.py", "Python"),
            ("requirements.txt", "Python"), ("pom.xml", "Maven"), ("build.gradle", "Gradle"),
            ("build.gradle.kts", "Gradle"), ("settings.gradle", "Gradle"), ("settings.gradle.kts", "Gradle"),
            ("pubspec.yaml", "Flutter"), ("Gemfile", "Ruby"), ("composer.json", "PHP"), ("mix.exs", "Elixir"),
            ("CMakeLists.txt", "CMake"), (".sln", ".NET"), (".csproj", ".NET"), ("deno.json", "Deno"),
            ("Makefile", "Make"), (".git", "Git"),
        ]
        var out: [String] = []
        for (marker, label) in known where markers.contains(where: { $0 == marker || $0.hasSuffix(marker) }) {
            if !out.contains(label) { out.append(label) }
        }
        return out.prefix(2).joined(separator: " · ")
    }
}

/// What a part of a project's footprint is.
public enum FootprintCategory: String, CaseIterable, Sendable, Codable {
    case source, git, dependencies, build, caches, localData, worktrees, agentSessions, appData
    /// Chosen for cleaning by the user (a rule), not by MyMole.
    case marked
    /// Excluded from cleaning by the user.
    case kept

    public var title: String {
        switch self {
        case .source: "Source & other files"
        case .git: "Git history"
        case .dependencies: "Dependencies"
        case .build: "Build output"
        case .caches: "Caches"
        case .localData: "Local work files"
        case .worktrees: "Agent worktrees"
        case .agentSessions: "Agent sessions"
        case .appData: "App data"
        case .marked: "Blacklisted — cleanup suggestions"
        case .kept: "Whitelisted — excluded from cleanup"
        }
    }

    /// Why it can go (or why it's never offered), in one line.
    public var note: String {
        switch self {
        case .source: "Your code and files, by top-level folder. Right-click one MyMole should clean."
        case .git: "The repository's history. Never offered for removal."
        case .dependencies: "Reinstalled by the package manager (npm install, pod install, …)."
        case .build: "Rebuilt on the next build."
        case .caches: "Tools rebuild caches as needed."
        case .localData: "Scratch output, logs and test runs kept in the project. Check before removing."
        case .worktrees: "Extra checkouts made by coding agents. Push anything you need, then run git worktree prune."
        case .agentSessions: "Transcripts kept by Codex and Claude Code. Removing them only loses the chat history."
        case .appData: "Containers, caches and settings of builds of this app. Removing them resets that app's data."
        case .marked: "Folders you added as cleanup suggestions. Nothing is removed until you choose and confirm it."
        case .kept: "Excluded from cleanup, including everything inside. They stay even when a parent is chosen."
        }
    }

    public var symbol: String {
        switch self {
        case .source: "doc.text"
        case .git: "arrow.triangle.branch"
        case .dependencies: "shippingbox"
        case .build: "hammer"
        case .caches: "archivebox"
        case .localData: "tray.full"
        case .worktrees: "square.stack.3d.up"
        case .agentSessions: "bubble.left.and.text.bubble.right"
        case .appData: "app.badge"
        case .marked: "plus.circle"
        case .kept: "lock.shield"
        }
    }

    /// Source, history and what the user kept are shown for scale but never
    /// removed from here.
    public var removable: Bool { self != .source && self != .git && self != .kept }

    /// Recreated by tools without losing anything: what "Choose Rebuildable"
    /// picks. The rest is removable too, but only one by one, after a look.
    public var rebuildable: Bool { self == .dependencies || self == .build || self == .caches }
}

/// How an item was tied to its project.
public enum Attribution: String, Sendable, Codable {
    /// Inside the project folder.
    case inside
    /// A tool stored the project's path with it.
    case recorded
    /// Only the name matches: a bundle ID containing the project's name.
    case nameMatch
    /// Outside the project, tied to it by the user (a rule).
    case user
}

/// One file or folder of a footprint item.
public struct FootprintEntry: Sendable, Hashable, Codable {
    public let path: String
    public let bytes: Int64
    public let modified: Date
    /// Advisory presentation metadata from the existing scan, never removal authority.
    public let isDirectory: Bool?
    /// What moving it frees where clones share blocks; nil where it wasn't
    /// read, and `bytes` stands.
    public let reclaim: Reclaim?

    public init(path: String, bytes: Int64, modified: Date, isDirectory: Bool? = nil, reclaim: Reclaim? = nil) {
        self.path = path
        self.bytes = bytes
        self.modified = modified
        self.isDirectory = isDirectory
        self.reclaim = reclaim
    }

    /// What moving it alone frees.
    public var frees: Int64 { min(bytes, reclaim?.bytes ?? bytes) }
    /// What moving it frees, with the clone families it may complete.
    public var freeing: Reclaim { reclaim ?? Reclaim(bytes: bytes) }
}

/// A group of entries of one kind in one place: every `node_modules` of a
/// project, its Codex sessions, its containers in `~/Library/Containers`.
public struct FootprintItem: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let category: FootprintCategory
    /// Folder name inside the project ("node_modules"), or what the tool
    /// calls it outside ("Codex sessions").
    public let title: String
    /// The project, or the shared folder the entries live in.
    public let location: String
    public let attribution: Attribution
    /// Largest first.
    public internal(set) var entries: [FootprintEntry]

    public init(
        id: String, category: FootprintCategory, title: String, location: String, attribution: Attribution,
        entries: [FootprintEntry]
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.location = location
        self.attribution = attribution
        self.entries = entries.sorted { $0.bytes > $1.bytes }
    }

    public var bytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }
    public var latest: Date { entries.map(\.modified).max() ?? .distantPast }
    public var removable: Bool { category.removable }

    /// The entries last changed before `cutoff` (all of them when nil).
    public func entries(olderThan cutoff: Date?) -> [FootprintEntry] {
        guard let cutoff else { return entries }
        return entries.filter { $0.modified < cutoff }
    }
}

/// Everything one project takes, inside its folder and elsewhere.
public struct ProjectFootprint: Sendable, Hashable, Codable, Identifiable {
    public let project: DevProject
    public internal(set) var items: [FootprintItem]
    /// False until the project folder itself has been measured.
    public internal(set) var measured: Bool
    /// Part of the folder couldn't be read, so its sizes are a lower bound.
    public internal(set) var incomplete: Bool

    public init(project: DevProject, items: [FootprintItem], measured: Bool = true, incomplete: Bool = false) {
        self.project = project
        self.items = items.sorted { $0.bytes > $1.bytes }
        self.measured = measured
        self.incomplete = incomplete
    }

    public var id: String { project.path }
    public var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    /// What moving every removable entry frees: clones of files that stay
    /// free nothing, and clones of one another free one copy.
    public var removableReclaim: Reclaim { items.filter(\.removable).flatMap(\.entries).reduce(Reclaim()) { $0 + $1.freeing } }
    public var removableBytes: Int64 { removableReclaim.bytes }
    public var outsideBytes: Int64 { items.filter { $0.attribution != .inside }.reduce(0) { $0 + $1.bytes } }

    public func bytes(_ category: FootprintCategory) -> Int64 {
        items.filter { $0.category == category }.reduce(0) { $0 + $1.bytes }
    }

    /// The last time anything of the project changed. Git history is left
    /// out: an editor's background fetch isn't work on the project.
    public var lastActivity: Date {
        items.filter { $0.category != .git }.map(\.latest).max() ?? .distantPast
    }

    /// Drops entries that are gone (moved to the Trash).
    public mutating func remove(paths: Set<String>) {
        for i in items.indices { items[i].entries.removeAll { paths.contains($0.path) } }
        items.removeAll { $0.entries.isEmpty }
    }

    /// Puts back entries that were restored (undo).
    public mutating func restore(_ restored: [(item: FootprintItem, entry: FootprintEntry)]) {
        for (item, entry) in restored {
            if let i = items.firstIndex(where: { $0.id == item.id }) {
                if !items[i].entries.contains(entry) {
                    items[i].entries.append(entry)
                    items[i].entries.sort { $0.bytes > $1.bytes }
                }
            } else {
                var copy = item
                copy.entries = [entry]
                items.append(copy)
            }
        }
        items.sort { $0.bytes > $1.bytes }
    }
}
