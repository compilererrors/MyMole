import Foundation

/// Everything the user keeps by path, read together, so Keep holds in
/// every pane that moves things: the disk map and Uninstall read both lists
/// through here, and Deep Clean and Projects each read the other's. A path
/// on Deep Clean's keep list, or kept by path in the project rules, is kept
/// wherever its removal starts; System Clean's list does the same for
/// system items. A rule by name ("keep everything named notes in every
/// project") is Projects' own: it says what Projects offers, and isn't
/// applied to what's moved from elsewhere.
///
/// The lists are read from disk when asked, so a gate that reads them as a
/// move runs sees a change made meanwhile. A list that can't be read throws,
/// which stops the move: nothing goes against a list that didn't load.
public struct UserProtections: Sendable {
    /// Deep Clean's keep list.
    public var keepList: URL
    /// Where the project rules are saved.
    public var projectBase: URL
    /// System Clean's keep list.
    public var systemKeepList: URL

    public init(keepList: URL, projectBase: URL, systemKeepList: URL) {
        self.keepList = keepList
        self.projectBase = projectBase
        self.systemKeepList = systemKeepList
    }

    /// Lists of the caller's own, under one folder.
    public init(root: URL) {
        self.init(
            keepList: root.appending(path: "DeepClean/keep.json"), projectBase: root.appending(path: "Projects"),
            systemKeepList: root.appending(path: "SystemClean/keep.json"))
    }

    /// The app's own lists.
    public static var live: UserProtections {
        UserProtections(
            keepList: CleanKeepList.defaultURL, projectBase: ProjectStore.defaultBase, systemKeepList: CleanKeepList.systemURL)
    }

    /// What's kept among the user's own files: kept itself, inside something
    /// kept, or holding something kept, so a folder never goes with a kept
    /// item inside it.
    public func read() throws -> @Sendable (String) -> Bool {
        let kept = try Self.kept(keepList: keepList, projectBase: projectBase)
        return { kept.protects($0) }
    }

    /// Deep Clean's keep list and the paths kept in the project rules, as
    /// one list. Deep Clean and Projects each read the other's through
    /// here, so what one keeps the other never moves.
    public static func kept(keepList: URL, projectBase: URL) throws -> CleanKeepList {
        let keep = try CleanKeepList.load(from: keepList)
        let rules = try ProjectStore.loadRules(base: projectBase)
        return CleanKeepList(paths: keep.paths.union(rules.keepPaths))
    }

    /// What's kept among system items, by the same rule.
    public func readSystem() throws -> @Sendable (String) -> Bool {
        let keep = try CleanKeepList.load(from: systemKeepList)
        return { keep.protects($0) }
    }
}
