import Foundation

// MARK: - History

/// Each project's total over time, so the list can show what grew in the
/// last day, and the last result itself, so the pane shows something at once
/// while it rescans.
///
/// Samples are kept at least `sampleInterval` apart; only the newest one
/// moves with every scan. Relaunching ten times in an hour leaves one fixed
/// sample and one current one, not ten that push a day's history out.
public enum ProjectStore {
    public static let keep = 30
    public static let sampleInterval: TimeInterval = 6 * 3_600
    public static let growthWindow: TimeInterval = 24 * 3_600

    public struct Sample: Sendable, Codable, Hashable {
        public let date: Date
        public let bytes: Int64
    }

    /// 2: tied to the folders searched, footprints say when they're incomplete.
    static let formatVersion = 2

    public struct Saved: Sendable, Codable {
        public let version: Int
        public let roots: [String]
        public let date: Date
        public let footprints: [ProjectFootprint]
    }

    public static var defaultBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MyMole/Projects")
    }

    /// The last complete result for these `roots`; one from other folders
    /// or an older format is ignored.
    public static func loadLast(roots: [String], base: URL = defaultBase) -> Saved? {
        guard let d = try? Data(contentsOf: base.appending(path: "last.json")),
            let saved = try? JSONDecoder().decode(Saved.self, from: d),
            saved.version == formatVersion, saved.roots == roots
        else { return nil }
        return saved
    }

    /// None saved is no rules; a file that can't be read or parsed throws,
    /// so nothing is cleaned against, or saved over, rules that didn't load.
    public static func loadRules(base: URL = defaultBase) throws -> ProjectRules {
        guard let d = try readIfPresent(base.appending(path: "rules.json")) else { return ProjectRules() }
        return try JSONDecoder().decode(ProjectRules.self, from: d)
    }

    public static func saveRules(_ rules: ProjectRules, base: URL = defaultBase) throws {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try JSONEncoder().encode(rules).write(to: base.appending(path: "rules.json"), options: .atomic)
    }

    /// Changes the rules as they are on disk now, under the file's lock, so
    /// another window's rule isn't lost; returns what was saved. Rules that
    /// can't be read are never written over.
    public static func updateRules(base: URL = defaultBase, _ change: (inout ProjectRules) -> Void) throws -> ProjectRules {
        try FileLock.around(base.appending(path: "rules.json")) {
            var rules = try loadRules(base: base)
            change(&rules)
            try saveRules(rules, base: base)
            return rules
        }
    }

    public static func loadHistory(base: URL = defaultBase) -> [String: [Sample]] {
        guard let d = try? Data(contentsOf: base.appending(path: "history.json")) else { return [:] }
        return (try? JSONDecoder().decode([String: [Sample]].self, from: d)) ?? [:]
    }

    /// Saves a complete scan: as the last result, and as a sample per project.
    @discardableResult
    /// Saves a complete scan of `roots` as the last result, and adds each
    /// project's total to its history. A scan with unreadable parts adds to
    /// the history but doesn't replace the last complete result.
    public static func save(_ footprints: [ProjectFootprint], roots: [String], date: Date = Date(), base: URL = defaultBase)
        -> [String: [Sample]]
    {
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var history = loadHistory(base: base)
        for f in footprints {
            history[f.id] = adding(Sample(date: date, bytes: f.bytes), to: history[f.id, default: []])
        }
        let enc = JSONEncoder()
        if !footprints.contains(where: \.incomplete),
            let d = try? enc.encode(Saved(version: formatVersion, roots: roots, date: date, footprints: footprints))
        {
            try? d.write(to: base.appending(path: "last.json"), options: .atomic)
        }
        if let d = try? enc.encode(history) { try? d.write(to: base.appending(path: "history.json"), options: .atomic) }
        return history
    }

    /// The newest sample replaces the current one until the sample before
    /// it is `sampleInterval` old; then it's kept and a new current one starts.
    /// Adds a scan's total. The newest sample moves with every scan; it's
    /// kept for good only once it's `sampleInterval` after the last kept one,
    /// so kept samples are always at least that far apart.
    static func adding(_ sample: Sample, to samples: [Sample]) -> [Sample] {
        var out = samples
        if let moving = out.last, out.count >= 2,
            moving.date.timeIntervalSince(out[out.count - 2].date) < sampleInterval
        {
            out[out.count - 1] = sample
        } else {
            out.append(sample)
        }
        return Array(out.suffix(keep))
    }

    /// Change of a project's total against the newest sample at least
    /// `window` older than the current one, and when that sample was taken.
    public static func growth(_ samples: [Sample], window: TimeInterval = growthWindow)
        -> (bytes: Int64, since: Date)?
    {
        guard let now = samples.last,
            let base = samples.last(where: { now.date.timeIntervalSince($0.date) >= window })
        else { return nil }
        return (now.bytes - base.bytes, base.date)
    }
}
