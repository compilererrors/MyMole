import AppKit
import StorageKit
import SwiftUI

/// The user's rules for Projects as the pane shows and changes them, and
/// the folders searched.
extension ProjectsModel {
    // MARK: Rules

    /// One rule, for the list where rules are reviewed and removed.
    enum Rule: Hashable, Identifiable {
        case cleanPath(String, project: String)
        case cleanName(String)
        case keepPath(String)
        case keepName(String)

        var id: Self { self }

        var title: String {
            switch self {
            case .cleanPath(let p, _): String(localized: "Blacklist: \((p as NSString).lastPathComponent)")
            case .cleanName(let n): String(localized: "Blacklist every folder named “\(n)”")
            case .keepPath(let p): String(localized: "Whitelist: \((p as NSString).lastPathComponent)")
            case .keepName(let n): String(localized: "Whitelist everything named “\(n)”")
            }
        }

        var path: String? {
            switch self {
            case .cleanPath(let p, _), .keepPath(let p): p
            default: nil
            }
        }

        var isKeep: Bool {
            switch self {
            case .keepPath, .keepName: true
            default: false
            }
        }
    }

    var ruleList: [Rule] {
        rules.keepNames.sorted().map(Rule.keepName) + rules.cleanNames.sorted().map(Rule.cleanName)
            + rules.keepPaths.sorted().map(Rule.keepPath)
            + rules.cleanPaths.sorted { $0.key < $1.key }.map { Rule.cleanPath($0.key, project: $0.value) }
    }

    /// Cleans a folder MyMole didn't offer, as part of `project`.
    func clean(_ paths: [String], in project: String) {
        let ok = paths.filter { ProjectRules.canClean($0, project: project) }
        guard !ok.isEmpty else { return }
        changeRules(project: project) { rules in
            for p in ok {
                rules.keepPaths.remove(p)
                rules.cleanPaths[p] = project
            }
        }
    }

    func cleanEverywhere(named name: String) {
        guard ProjectRules.canCleanEverywhere(name: name) else { return }
        changeRules(project: nil) { rules in
            rules.keepNames.remove(name)
            rules.cleanNames.insert(name)
        }
    }

    /// Never offers these again; they're shown as kept.
    func keep(_ paths: [String], in project: String) {
        // Unchosen even if the rule isn't saved: keeping is never undone by a failure.
        chosen.subtract(paths)
        changeRules(project: project) { rules in
            for p in paths {
                rules.cleanPaths[p] = nil
                rules.keepPaths.insert(p)
            }
        }
    }

    func keepEverywhere(named name: String) {
        changeRules(project: nil) { rules in
            rules.cleanNames.remove(name)
            rules.keepNames.insert(name)
        }
    }

    /// Undoes whatever rule made these kept or added, by path or by name.
    func forget(_ paths: [String], in project: String) {
        let names = Set(paths.map { ($0 as NSString).lastPathComponent })
        let byName = !names.isDisjoint(with: rules.keepNames.union(rules.cleanNames))
        chosen.subtract(paths)
        changeRules(project: byName ? nil : project) { rules in
            for p in paths {
                rules.keepPaths.remove(p)
                rules.cleanPaths[p] = nil
            }
            rules.keepNames.subtract(names)
            rules.cleanNames.subtract(names)
        }
    }

    func remove(_ rule: Rule) {
        switch rule {
        case .cleanPath(let p, let project):
            changeRules(project: project) { $0.cleanPaths[p] = nil }
        case .keepPath(let p):
            changeRules(project: footprints.first { p == $0.id || p.hasPrefix($0.id + "/") }?.id) { $0.keepPaths.remove(p) }
        case .cleanName(let n):
            changeRules(project: nil) { $0.cleanNames.remove(n) }
        case .keepName(let n):
            changeRules(project: nil) { $0.keepNames.remove(n) }
        }
    }

    /// Picks folders to clean as part of a project: inside it, or anywhere
    /// else MyMole didn't tie to it (a cache in ~/Library).
    func addFolderForCleanup(to project: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: project)
        panel.prompt = String(localized: "Clean")
        panel.message = String(localized: "Choose folders or files to clean as part of \((project as NSString).lastPathComponent).")
        guard panel.runModal() == .OK else { return }
        let picked = panel.urls.map { ($0.path as NSString).standardizingPath }
        let refused = picked.filter { !ProjectRules.canClean($0, project: project) }
        let accepted = picked.filter { ProjectRules.canClean($0, project: project) }
        if !accepted.isEmpty { requestRule(.blacklist(accepted, project: project)) }
        if !refused.isEmpty {
            show(Notice(text: String(localized: "\(refused.count) can't be cleaned: the project folder, its history or a protected place"), canUndo: false))
        }
    }

    // MARK: Folders

    func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add")
        panel.message = String(localized: "Choose folders that hold your projects.")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !roots.contains(url.path) { roots.append(url.path) }
        scan()
    }

    func removeRoot(_ root: String) {
        roots.removeAll { $0 == root }
        scan()
    }

    func resetRoots() {
        roots = ProjectFinder.defaultRoots()
        scan()
    }
}
