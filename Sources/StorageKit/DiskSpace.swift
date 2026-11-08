import Foundation

/// How the disk a map was made of is used beyond what the map holds: what
/// the volume says is used, what of its free space macOS may purge, and the
/// Time Machine snapshots kept on it. Read only; nothing here frees space.
public struct DiskSpace: Sendable, Equatable {
    public let total: Int64
    /// In use as Finder counts it: purgeable space counts as free.
    public let used: Int64
    /// Space macOS frees on its own when it's needed: caches it manages and
    /// local Time Machine snapshots.
    public let purgeable: Int64
    /// The local Time Machine snapshots, by name; nil when they couldn't be listed.
    public let snapshots: [String]?

    public init(total: Int64, used: Int64, purgeable: Int64, snapshots: [String]?) {
        self.total = total
        self.used = used
        self.purgeable = purgeable
        self.snapshots = snapshots
    }

    /// What's used on the disk but isn't in a map holding `mapped`: macOS,
    /// apps and other users outside it, folders it couldn't read.
    public func outside(mapped: Int64) -> Int64 { max(0, used - mapped) }

    static let tmutil = "/usr/bin/tmutil"

    /// The disk `path` is on, or nil when it can't be read.
    public static func read(volumeOf path: String, runner: CommandRunner = .processes(timeLimit: 10)) -> DiskSpace? {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ]
        guard let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys), let total = v.volumeTotalCapacity,
            total > 0, let free = v.volumeAvailableCapacity
        else { return nil }
        let available = v.volumeAvailableCapacityForImportantUsage ?? Int64(free)
        return DiskSpace(
            total: Int64(total), used: max(0, Int64(total) - available), purgeable: max(0, available - Int64(free)),
            snapshots: snapshots(of: path, runner: runner))
    }

    /// "com.apple.TimeMachine.2026-11-06-010203.local", one a line.
    static func snapshots(of path: String, runner: CommandRunner) -> [String]? {
        guard runner.exists(tmutil) else { return nil }
        let r = runner.run(tmutil, ["listlocalsnapshots", path])
        guard r.code == 0 else { return nil }
        return parseSnapshots(r.output)
    }

    static func parseSnapshots(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("com.apple.") && $0.hasSuffix(".local") }
    }
}
