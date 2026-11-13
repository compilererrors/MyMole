import Foundation
import StorageKit

/// How much the interface keeps ready in memory, chosen in Settings, apart
/// from how hard scans work (`PerformanceLevel`) and how much a result
/// holds (`ResultSize`). Higher levels keep more drawn, measured and mapped
/// in memory and repaint running scans more often; lower ones read again
/// from disk and redraw when needed, so MyMole holds less while it waits.
/// Memory relief, when turned on, works the same at every level.
enum Responsiveness: Int, CaseIterable, Identifiable {
    case automatic = 0
    case gentle
    case light
    case balanced
    case fast
    case maximum
    case hyperspeed

    static let defaultsKey = "performance.responsiveness"
    /// Maximum until someone chooses otherwise; a lower level is for a Mac where the app feels slow.
    static let byDefault = Responsiveness.maximum

    var id: Int { rawValue }

    static func saved(in defaults: UserDefaults = .standard) -> Responsiveness {
        guard defaults.object(forKey: defaultsKey) != nil else { return byDefault }
        return Responsiveness(rawValue: defaults.integer(forKey: defaultsKey)) ?? byDefault
    }

    /// The level in effect: the saved one, or for Automatic the one that
    /// suits this Mac now.
    static func current(in defaults: UserDefaults = .standard) -> Responsiveness {
        saved(in: defaults).resolved()
    }

    /// Automatic: Gentle in Low Power Mode and on Macs with little memory,
    /// Fast on Macs with plenty, Balanced otherwise. Any other level is itself.
    func resolved(lowPower: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled,
                  memory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Responsiveness {
        guard self == .automatic else { return self }
        let gigabyte: UInt64 = 1 << 30
        if lowPower || memory <= 8 * gigabyte { return .gentle }
        return memory >= 32 * gigabyte ? .fast : .balanced
    }

    var title: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        case .gentle: String(localized: "Gentle")
        case .light: String(localized: "Light")
        case .balanced: String(localized: "Balanced")
        case .fast: String(localized: "Fast")
        case .maximum: String(localized: "Maximum")
        case .hyperspeed: String(localized: "Hyperspeed")
        }
    }

    var detail: String {
        switch self {
        case .automatic: String(localized: "Picks a level from this Mac's memory, and goes gentle in Low Power Mode.")
        case .gentle: String(localized: "Holds the least. The disk map is let go a while after you leave it and isn't prepared at launch; running scans repaint less often.")
        case .light: String(localized: "Keeps a few charts and icons ready, and repaints running scans about three times a second.")
        case .balanced: String(localized: "Keeps the disk map and recent charts ready, and repaints running scans five times a second.")
        case .fast: String(localized: "Keeps more charts, icons and text measurements ready, and repaints running scans more often.")
        case .maximum: String(localized: "Keeps the most within limits ready, repaints running scans most often, and reuses a result only minutes old at launch.")
        case .hyperspeed: String(localized: "No limits: keeps everything ready and prepares every pane afresh at each launch. Can use a lot of memory.")
        }
    }

    /// How often a running scan's counts and found files reach the screen.
    var publishInterval: Duration {
        switch resolved() {
        case .gentle: .milliseconds(400)
        case .light: .milliseconds(300)
        case .automatic, .balanced: .milliseconds(200)
        case .fast: .milliseconds(120)
        case .maximum, .hyperspeed: .milliseconds(60)
        }
    }

    /// App icons kept in memory; at Hyperspeed, all of them.
    var iconLimit: Int { scaled(1_000, 2_000, 4_000, 8_000, 16_000) }
    /// Measured name widths kept for file lists.
    var textWidthLimit: Int { scaled(2_048, 4_096, 8_192, 16_384, 32_768) }
    /// Symbol images kept for file lists.
    var symbolLimit: Int { scaled(256, 512, 1_024, 2_048, 4_096) }
    /// Laid-out charts kept per chart, so going back to a folder redraws at once.
    var chartLayoutLimit: Int { scaled(32, 64, 128, 256, 512) }

    /// How long a pane's last complete result counts as fresh at launch,
    /// for a pane whose usual window is `standard` (Balanced): four and two
    /// times as long below, half above, a sixth at Maximum, and never at
    /// Hyperspeed, which prepares every pane afresh at each launch.
    func freshWindow(_ standard: TimeInterval) -> TimeInterval? {
        switch resolved() {
        case .gentle: standard * 4
        case .light: standard * 2
        case .automatic, .balanced: standard
        case .fast: standard / 2
        case .maximum: standard / 6
        case .hyperspeed: nil
        }
    }
    /// Whether the disk map stays in memory once you've left the pane.
    var keepsMapAway: Bool { resolved() != .gentle }
    /// Whether launch prepares the disk map ahead of opening it.
    var prewarmsDiskMap: Bool { resolved() != .gentle }
    /// How long a gentle disk map is kept after leaving the pane.
    static let idleMapGrace: Duration = .seconds(120)

    /// Gentle to Maximum; Hyperspeed has no cap.
    private func scaled(_ gentle: Int, _ light: Int, _ balanced: Int, _ fast: Int, _ maximum: Int) -> Int {
        switch resolved() {
        case .gentle: gentle
        case .light: light
        case .automatic, .balanced: balanced
        case .fast: fast
        case .maximum: maximum
        case .hyperspeed: .max
        }
    }

    /// Hands the limits to the caches that hold them; at launch, when the
    /// setting changes and when Low Power Mode turns on or off.
    @MainActor static func apply(_ level: Responsiveness = .current()) {
        AppIcons.limit = level.iconLimit
        FileCellResources.setLimits(textWidths: level.textWidthLimit, symbols: level.symbolLimit)
        ChartLayouts.limit = level.chartLayoutLimit
    }
}

/// The last few laid-out charts of one map, newest last. Laid out again
/// whenever the map changes, so a stale layout is never drawn; a new map
/// lets go of every layout of the old one, which would otherwise keep its
/// folders alive.
@MainActor
final class LayoutMemo<Key: Hashable, Value> {
    var limit: Int { didSet { trim() } }
    private var values: [Key: Value] = [:]
    private var order: [Key] = []
    private var map: ObjectIdentifier?

    init(limit: Int) { self.limit = limit }

    var count: Int { values.count }

    func value(_ key: Key, map: ObjectIdentifier?) -> Value? {
        guard map == self.map, let value = values[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return value
    }

    func keep(_ value: Value, for key: Key, map: ObjectIdentifier?) {
        if map != self.map { removeAll() }
        self.map = map
        guard limit > 1 else { return }
        if values.updateValue(value, forKey: key) == nil { order.append(key) }
        trim()
    }

    func removeAll() {
        values = [:]
        order = []
        map = nil
    }

    private func trim() {
        while order.count > max(limit, 0) { values[order.removeFirst()] = nil }
    }
}

/// The chart layouts the disk map's views keep.
@MainActor
enum ChartLayouts {
    static let sunburst = LayoutMemo<SunburstChart.LayoutKey, [Arc]>(limit: Responsiveness.balanced.chartLayoutLimit)

    static var limit: Int {
        get { sunburst.limit }
        set { sunburst.limit = newValue }
    }

    static func removeAll() { sunburst.removeAll() }
}
