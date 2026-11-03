import Foundation

/// How hard MyMole's scans may work, chosen in Settings. Lower levels walk
/// with fewer threads at a lower priority, which on Apple silicon keeps them
/// on the efficiency cores, and run the cleanup scans one at a time; scans
/// take longer and the Mac stays quiet. Each scan reads the level as it
/// starts, so a change applies from the next scan.
public enum PerformanceLevel: Int, CaseIterable, Sendable, Comparable {
    case gentle = 1
    case light
    case balanced
    case fast
    case full

    public static let defaultsKey = "performance.level"
    public static let standard = PerformanceLevel.balanced

    /// The level saved in Settings, or the standard one.
    public static func current(in defaults: UserDefaults = .standard) -> PerformanceLevel {
        PerformanceLevel(saved: defaults.integer(forKey: defaultsKey))
    }

    /// A saved value; anything unknown, or nothing saved (0), is the standard level.
    public init(saved: Int) {
        self = PerformanceLevel(rawValue: saved) ?? Self.standard
    }

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .gentle: "Gentle"
        case .light: "Light"
        case .balanced: "Balanced"
        case .fast: "Fast"
        case .full: "Full"
        }
    }

    public var detail: String {
        switch self {
        case .gentle: "Quietest. Two threads at the lowest priority, one scan at a time; scans take longest."
        case .light: "Few threads at low priority, one scan at a time."
        case .balanced: "Uses the cores without crowding the apps you work in."
        case .fast: "Twice as many threads as cores for scans you wait on."
        case .full: "Everything the Mac has, even for scans started ahead of time."
        }
    }

    /// Directory walkers for one scan. Reading folders mostly waits on the
    /// disk, so the upper levels go past the core count.
    public func workers(background: Bool, cores: Int = ProcessInfo.processInfo.activeProcessorCount) -> Int {
        let c = max(cores, 1)
        switch (self, background) {
        case (.gentle, false): return 2
        case (.gentle, true): return 1
        case (.light, false): return max(c / 2, 2)
        case (.light, true): return 2
        case (.balanced, false): return max(c, 4)
        case (.balanced, true): return max(c / 4, 2)
        case (.fast, false): return min(max(c * 2, 4), 24)
        case (.fast, true): return max(c / 2, 2)
        case (.full, false): return min(max(c * 3, 4), 48)
        case (.full, true): return max(c, 4)
        }
    }

    /// Threads for reading app bundles, which are many small folders.
    public func appWorkers(background: Bool) -> Int {
        min(workers(background: background), background ? 4 : 8)
    }

    public func priority(background: Bool) -> TaskPriority {
        switch self {
        case .gentle, .light: background ? .background : .utility
        case .balanced, .fast: background ? .utility : .userInitiated
        case .full: .userInitiated
        }
    }

    /// Whether the cleanup scans may run side by side.
    public var runsScansTogether: Bool { self >= .balanced }
}
