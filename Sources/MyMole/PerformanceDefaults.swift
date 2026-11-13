import Foundation
import StorageKit

/// Every performance setting starts at Maximum, step 5 of the six-step
/// scale; step 3, Balanced, holds the limits of the builds before it. Earlier builds saved other defaults and numbered the steps
/// differently; once per Mac each version's step below brings their values
/// over. A value that still holds an old default goes to Maximum; anything
/// else was chosen and keeps its meaning. Each step runs once, so a choice
/// made after it is never undone.
enum PerformanceDefaults {
    static let versionKey = "performance.defaults.version"
    static let version = 4

    /// What each setting defaulted to before version 2.
    static let earlierDefaults: [(key: String, value: Int)] = [
        (PerformanceLevel.defaultsKey, 3),  // Balanced
        (ResultSize.defaultsKey, 1),  // Standard
        (Responsiveness.defaultsKey, 0),  // Automatic
    ]

    /// Version 4's six steps, from the numbers saved before it. A missing
    /// entry was the default of its day and goes to Maximum.
    static let renumbered: [(key: String, map: [Int: Int])] = [
        // Standard (the amounts before the setting, now Balanced), Large (8×), No limit.
        (ResultSize.defaultsKey, [1: ResultSize.balanced.rawValue, 2: ResultSize.maximum.rawValue, 3: ResultSize.hyperspeed.rawValue]),
        // Automatic, Lean, Balanced and Fast keep their meaning; the old Maximum was the default.
        (Responsiveness.defaultsKey, [0: Responsiveness.automatic.rawValue, 1: Responsiveness.gentle.rawValue,
                                      2: Responsiveness.balanced.rawValue, 3: Responsiveness.fast.rawValue]),
    ]

    static func migrate(_ defaults: UserDefaults = .standard) {
        let from = defaults.integer(forKey: versionKey)
        guard from < version else { return }
        if from < 2 {
            for (key, value) in earlierDefaults where defaults.object(forKey: key) != nil && defaults.integer(forKey: key) == value {
                defaults.removeObject(forKey: key)
            }
        }
        // Memory relief was always on before it became a setting, so no
        // saved value can be a choice: every Mac starts with it off.
        if from < 3 { defaults.removeObject(forKey: MemoryRelief.defaultsKey) }
        if from < 4 {
            for (key, map) in renumbered where defaults.object(forKey: key) != nil {
                if let value = map[defaults.integer(forKey: key)] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        defaults.set(version, forKey: versionKey)
    }
}
