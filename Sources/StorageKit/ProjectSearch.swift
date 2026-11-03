import Darwin
import Foundation

// Finding projects, sorting what's inside each, and the scan that puts it
// together with what lies outside them (ProjectAttribution.swift). The
// models are in Projects.swift, the rules in ProjectRules.swift.

// MARK: - Finding projects

public enum ProjectFinder {
    /// Files that make a folder a project.
    static let markerFiles: Set<String> = [
        ".git", "Package.swift", "package.json", "Cargo.toml", "go.mod", "pyproject.toml", "setup.py",
        "requirements.txt", "Pipfile", "pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle",
        "settings.gradle.kts", "Gemfile", "composer.json", "CMakeLists.txt", "Makefile", "pubspec.yaml", "mix.exs",
        "deno.json", "Podfile", "project.yml", "Tuist.swift",
    ]
    static let markerSuffixes = [".xcodeproj", ".xcworkspace", ".sln", ".csproj"]

    /// Never walked into while looking for projects.
    static let skipped: Set<String> = ["node_modules", "Library", "Applications", "Pods", "vendor"]

    /// The usual places for code under the home folder, those that exist.
    public static func defaultRoots(home: String = Home.path) -> [String] {
        ["Workspace", "Developer", "Projects", "Code", "code", "src", "dev", "Dev", "GitHub", "git", "repos", "Sites"]
            .map { home + "/" + $0 }
            .filter { p in
                var dir: ObjCBool = false
                return FileManager.default.fileExists(atPath: p, isDirectory: &dir) && dir.boolValue
            }
            // `code` and `Code` are one folder on a case-insensitive volume.
            .reduce(into: [String]()) { out, p in
                let real = (p as NSString).resolvingSymlinksInPath
                if !out.contains(where: { $0.lowercased() == real.lowercased() }) { out.append(p) }
            }
    }

    /// The project files among a folder's entries.
    static func markers(in names: [String]) -> [String] {
        names.filter { n in markerFiles.contains(n) || markerSuffixes.contains(where: n.hasSuffix) }.sorted()
    }

    static func contents(_ path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    /// Projects under `roots`, up to `maxDepth` folders down. A project
    /// isn't searched for more projects: a monorepo's packages are its own.
    /// A root is a project itself only when nothing below it is (a stray
    /// Makefile in ~/Workspace mustn't swallow every project in it).
    public static func find(roots: [String], maxDepth: Int = 4) -> [DevProject] {
        var found: [DevProject] = []
        var seen = Set<String>()
        func walk(_ path: String, depth: Int) {
            let names = contents(path)
            let m = markers(in: names)
            if !m.isEmpty && depth > 0 {
                if seen.insert(path).inserted { found.append(DevProject(path: path, markers: m)) }
                return
            }
            guard depth < maxDepth else { return }
            if depth == 0 && !m.isEmpty {
                let before = found.count
                descend(path, names, depth)
                if found.count == before, seen.insert(path).inserted { found.append(DevProject(path: path, markers: m)) }
                return
            }
            descend(path, names, depth)
        }
        func descend(_ path: String, _ names: [String], _ depth: Int) {
            for n in names.sorted() where !n.hasPrefix(".") && !skipped.contains(n) && !n.hasSuffix(".app") {
                let child = path + "/" + n
                var st = stat()
                // Real folders only: symlinks could loop or leave the volume.
                guard lstat(child, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { continue }
                walk(child, depth: depth + 1)
            }
        }
        for root in roots { walk((root as NSString).standardizingPath, depth: 0) }
        return found
    }

    /// The project a path is in: the one with the longest matching path.
    static func owner(of path: String, in projects: [DevProject]) -> DevProject? {
        projects
            .filter { path == $0.path || path.hasPrefix($0.path + "/") }
            .max { $0.path.count < $1.path.count }
    }
}

// MARK: - Inside a project

public enum ProjectArtifacts {
    /// Folder names that are tool output wherever they appear.
    static let byName: [String: FootprintCategory] = [
        "node_modules": .dependencies, "Pods": .dependencies, ".venv": .dependencies, ".tox": .dependencies,
        "bower_components": .dependencies, ".pnpm-store": .dependencies, ".terraform": .dependencies,
        ".build": .build, "DerivedData": .build, ".next": .build, ".nuxt": .build, ".svelte-kit": .build,
        ".dart_tool": .build, ".gradle": .build, ".angular": .build, ".expo": .build, ".out": .build,
        "__pycache__": .caches, ".pytest_cache": .caches, ".mypy_cache": .caches, ".ruff_cache": .caches,
        ".cache": .caches, ".turbo": .caches, ".parcel-cache": .caches, ".nyc_output": .caches,
        ".sass-cache": .caches,
        ".local": .localData, ".tmp": .localData,
        ".worktrees": .worktrees,
    ]

    /// Names that are only output next to a project file, so a folder that
    /// happens to be called "build" or "out" isn't taken on its name alone.
    static let besideProjectFile: [String: FootprintCategory] = [
        "build": .build, "dist": .build, "out": .build, "target": .build, "coverage": .caches,
        "tmp": .localData, "logs": .localData, "venv": .dependencies,
    ]

    /// Folders under these names hold agents' extra checkouts.
    static let worktreeParents: Set<String> = [".claude", ".codex", ".cursor", ".conductor"]

    static func category(folder name: String, parentName: String, parentHasProjectFile: () -> Bool)
        -> FootprintCategory?
    {
        if name == ".git" { return .git }
        if name == "worktrees", worktreeParents.contains(parentName) { return .worktrees }
        if let c = byName[name] { return c }
        if let c = besideProjectFile[name], parentHasProjectFile() { return c }
        return nil
    }

    /// Sorts a scanned project tree into its parts. Every tool folder of the
    /// same name becomes one item (all `node_modules` together). Whatever is
    /// left is the project's own source, one entry per top-level folder (and
    /// one for the loose files), so a big folder MyMole doesn't know is easy
    /// to see and to mark for cleaning.
    public static func items(of root: Folder, project: DevProject, rules: ProjectRules = ProjectRules())
        -> [FootprintItem]
    {
        var groups: [String: (FootprintCategory, [FootprintEntry])] = [:]
        // Per top-level folder: bytes claimed by items below it, and the
        // newest change of what's left.
        var claimed: [String: Int64] = [:]
        var latest: [String: Date] = [:]
        var stack: [(Folder, String?)] = [(root, nil)]
        while let (folder, topPath) = stack.popLast() {
            var hasProjectFile: Bool?
            for sub in folder.subfolders {
                let top = topPath ?? sub.path
                let c: FootprintCategory? =
                    rules.keeps(sub.path) ? .kept
                    // Something kept inside: never offered whole; looked
                    // into instead, so only what's around the kept item shows.
                    : holdsKept(sub, rules: rules) ? nil
                    : rules.cleans(sub.path) ? .marked
                    : category(folder: sub.name, parentName: folder.name) {
                        if hasProjectFile == nil {
                            hasProjectFile = !ProjectFinder.markers(in: ProjectFinder.contents(folder.path)).isEmpty
                        }
                        return hasProjectFile!
                    }
                guard let c else {
                    latest[top] = max(latest[top] ?? .distantPast, sub.ownLatestChange)
                    stack.append((sub, top))
                    continue
                }
                let key =
                    switch c {
                    case .worktrees: "worktrees"
                    case .marked: "marked"
                    case .kept: "kept"
                    default: sub.name
                    }
                groups[key, default: (c, [])].1.append(
                    FootprintEntry(path: sub.path, bytes: sub.size, modified: sub.latestChange))
                claimed[top, default: 0] += sub.size
            }
        }
        var out = groups.map { key, value in
            FootprintItem(
                id: "inside:\(key)", category: value.0, title: title(key: key, category: value.0),
                location: project.path, attribution: .inside, entries: value.1)
        }
        var source: [FootprintEntry] = []
        if root.looseBytes > 0 {
            source.append(FootprintEntry(path: project.path, bytes: root.looseBytes, modified: root.ownLatestChange))
        }
        for sub in root.subfolders {
            // Nothing left once a top-level folder is an item of its own.
            let left = sub.size - (claimed[sub.path] ?? 0)
            guard left > 0 else { continue }
            source.append(FootprintEntry(path: sub.path, bytes: left, modified: latest[sub.path] ?? sub.ownLatestChange))
        }
        out.append(
            FootprintItem(
                id: "inside:source", category: .source, title: "Source & other files", location: project.path,
                attribution: .inside, entries: source))
        return out
    }

    /// Whether a kept path or name is somewhere inside `folder` as scanned.
    static func holdsKept(_ folder: Folder, rules: ProjectRules) -> Bool {
        if rules.keepPaths.contains(where: { $0.hasPrefix(folder.path + "/") }) { return true }
        guard !rules.keepNames.isEmpty else { return false }
        var stack = folder.subfolders
        while let f = stack.popLast() {
            if rules.keepNames.contains(f.name) || f.listedFiles.contains(where: { rules.keepNames.contains($0.name) }) {
                return true
            }
            stack += f.subfolders
        }
        return folder.listedFiles.contains { rules.keepNames.contains($0.name) }
    }

    static func title(key: String, category: FootprintCategory) -> String {
        switch category {
        case .worktrees: "Worktrees"
        case .marked: "Added by you"
        case .kept: "Kept by you"
        default: key
        }
    }
}

// MARK: - The whole scan

public enum ProjectScanner {
    /// Finds the projects under `roots`, attributes outside data to them,
    /// then measures each project folder. `onFound` gets every project with
    /// its outside data first, so a list can show before the slow part;
    /// `onProject` gets each one complete as it's measured. Stops early,
    /// leaving the rest unmeasured, when `progress` is cancelled.
    public static func scan(
        roots: [String], home: String = Home.path, rules: ProjectRules = ProjectRules(),
        progress: ScanProgress = ScanProgress(), workers: Int = StorageScanner.defaultWorkers,
        onFound: ([ProjectFootprint]) -> Void = { _ in }, onProject: (ProjectFootprint) -> Void = { _ in }
    ) -> [ProjectFootprint] {
        let projects = ProjectFinder.find(roots: roots)
        let outside = ProjectAttribution.find(for: projects, home: home, rules: rules)
        // A place outside that couldn't be read may hold any project's data.
        let missed = !outside.unreadable.isEmpty
        var results = projects.map {
            ProjectFootprint(project: $0, items: outside.items[$0.path] ?? [], measured: false, incomplete: missed)
        }
        onFound(results)
        for i in results.indices {
            if progress.isCancelled { break }
            results[i] = measure(results[i], rules: rules, progress: progress, workers: workers)
            if missed { results[i].incomplete = true }
            onProject(results[i])
        }
        return results
    }

    /// One project again, after its rules changed. `among` is every known
    /// project, since outside data is attributed against all of them.
    public static func rescan(
        _ project: DevProject, among projects: [DevProject], home: String = Home.path,
        rules: ProjectRules = ProjectRules()
    ) -> ProjectFootprint {
        let outside = ProjectAttribution.find(for: projects, home: home, rules: rules)
        var f = measure(ProjectFootprint(project: project, items: outside.items[project.path] ?? [], measured: false), rules: rules)
        if !outside.unreadable.isEmpty { f.incomplete = true }
        return f
    }

    /// Adds the project folder's own parts to a footprint.
    public static func measure(
        _ footprint: ProjectFootprint, rules: ProjectRules = ProjectRules(), progress: ScanProgress = ScanProgress(),
        workers: Int = StorageScanner.defaultWorkers
    ) -> ProjectFootprint {
        let r = StorageScanner.scan(path: footprint.project.path, progress: progress, workers: workers)
        if r.cancelled { return footprint }
        let inside = ProjectArtifacts.items(of: r.root, project: footprint.project, rules: rules)
        return ProjectFootprint(
            project: footprint.project, items: footprint.items.filter { $0.attribution != .inside } + inside,
            measured: true, incomplete: !r.deniedPaths.isEmpty || r.root.unreadable)
    }
}
