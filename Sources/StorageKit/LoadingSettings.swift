import Foundation

/// How much MyMole loads ahead and keeps: the panes it gets ready at
/// launch, and how many disk-map scans each folder's history holds.
public enum LoadingSettings {
    public static let prefetchKey = "loading.prefetch"
    public static let historyKey = "loading.history"

    /// Scans kept per folder for the disk map's changes.
    public static let historyRange = 5...100
    public static let historyStandard = 30

    /// Whether the panes are scanned in the background at launch, so each
    /// opens with a fresh result.
    public static func prefetch(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: prefetchKey) as? Bool ?? true
    }

    public static func history(in defaults: UserDefaults = .standard) -> Int {
        let saved = defaults.integer(forKey: historyKey)
        return saved == 0 ? historyStandard : min(max(saved, historyRange.lowerBound), historyRange.upperBound)
    }
}
