import Foundation

/// Quick access only: a pin never changes cleanup eligibility or protection.
@MainActor @Observable
final class PinnedItems {
    static let shared = PinnedItems(defaults: .standard)
    static let key = "navigation.pinnedPaths.v1"
    private let defaults: UserDefaults
    private(set) var paths: Set<String>

    init(defaults: UserDefaults) {
        self.defaults = defaults
        paths = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func contains(_ path: String) -> Bool { paths.contains(path) }
    func refresh() { paths = Set(defaults.stringArray(forKey: Self.key) ?? []) }

    func set(_ values: [String], pinned: Bool) {
        refresh()
        let safe = values.filter { $0.hasPrefix("/") && !$0.contains("\0") && ($0 as NSString).standardizingPath == $0 }
        if pinned { paths.formUnion(safe) } else { paths.subtract(safe) }
        defaults.set(paths.sorted(), forKey: Self.key)
    }
}
