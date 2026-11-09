import Foundation

/// Folders the Disk Map doesn't scan, as the user chose: not walked, not
/// counted, and never compared in Changes. Apart from Keep, which only
/// stops a move, and from Browse's filter, which only hides rows.
enum DiskMapSkips {
    static let key = "diskMap.skip"

    static func paths(in defaults: UserDefaults = .standard) -> [String] {
        (defaults.stringArray(forKey: key) ?? []).filter { $0.hasPrefix("/") }.sorted()
    }

    static func add(_ path: String, in defaults: UserDefaults = .standard) {
        set(paths(in: defaults) + [path], in: defaults)
    }

    static func remove(_ path: String, in defaults: UserDefaults = .standard) {
        set(paths(in: defaults).filter { $0 != path }, in: defaults)
    }

    private static func set(_ list: [String], in defaults: UserDefaults) {
        defaults.set(Array(Set(list)).sorted(), forKey: key)
    }

    /// The ones inside `root`, full and relative to it.
    static func under(_ root: String, in defaults: UserDefaults = .standard) -> (full: Set<String>, relative: [String]) {
        let base = root == "/" ? "/" : root + "/"
        let inside = paths(in: defaults).filter { $0.hasPrefix(base) }
        return (Set(inside), inside.map { String($0.dropFirst(base.count)) })
    }
}

/// Browse filters the user saved, by a name made from what they filter.
struct SavedFilter: Codable, Hashable, Identifiable {
    var name: String
    var filter: BrowseFilter
    var id: String { name }

    static let key = "diskMap.savedFilters"

    static func all(in defaults: UserDefaults = .standard) -> [SavedFilter] {
        guard let d = defaults.data(forKey: key), let list = try? JSONDecoder().decode([SavedFilter].self, from: d) else { return [] }
        return list
    }

    static func save(_ list: [SavedFilter], in defaults: UserDefaults = .standard) {
        if let d = try? JSONEncoder().encode(list) { defaults.set(d, forKey: key) }
    }

    /// "“invoice” · Documents · Older than 1 Year".
    static func name(for f: BrowseFilter) -> String {
        var parts: [String] = []
        if !f.query.isEmpty { parts.append("“\(f.query)”") }
        if let k = f.kind { parts.append(k.title) }
        if f.date.isActive { parts.append(f.date.summary) }
        if f.wholeScan { parts.append(String(localized: "whole scan")) }
        return parts.joined(separator: " · ")
    }
}
