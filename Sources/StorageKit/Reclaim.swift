import Darwin
import Foundation

/// Files cloned from one another on one volume (`FileSpace.Sharing.cloneID`).
public struct CloneFamily: Sendable, Hashable, Codable {
    public let device: Int32
    public let id: UInt64

    public init(device: Int32, id: UInt64) {
        self.device = device
        self.id = id
    }
}

/// Whole clones of one family counted so far, against the volume's count.
public struct CloneMembers: Sendable, Hashable, Codable {
    public internal(set) var count: Int
    /// Files the volume says hold the family's blocks.
    public let total: Int
    /// The blocks they share: one copy.
    public internal(set) var bytes: Int64
}

/// What removing a set of files frees, as opposed to what they occupy.
///
/// Each file counts the blocks it holds alone: its allocated size, or its
/// private size when the volume flags it as sharing blocks. Whole clones of
/// one another add their shared copy once every file the volume counts in
/// the family is in the set; until then they stay `open`, so sets can be
/// combined in any order. A file rewritten in part after cloning gets a
/// family of its own and counts only its private bytes, and the volume no
/// longer counts it in the old family: that family can complete while the
/// rewritten file still holds most of its copy.
public struct Reclaim: Sendable, Hashable, Codable {
    /// Families tracked per set; past this the smallest are dropped, which
    /// only ever lowers the estimate.
    static let openLimit = 4_096

    public private(set) var bytes: Int64
    public private(set) var open: [CloneFamily: CloneMembers]

    public init(bytes: Int64 = 0) {
        self.bytes = max(bytes, 0)
        self.open = [:]
    }

    init(bytes: Int64, open: [CloneFamily: CloneMembers]) {
        self.bytes = max(bytes, 0)
        self.open = open
    }

    /// A file of `allocated` bytes on `device`, as the volume reports its sharing.
    public static func file(allocated: Int64, device: Int32, sharing: FileSpace.Sharing?) -> Reclaim {
        let allocated = max(allocated, 0)
        // Without the sharing flag the private size means nothing: a
        // compressed file reports none and frees its allocated size.
        guard let sharing, let privateBytes = sharing.privateBytes else { return Reclaim(bytes: allocated) }
        let alone = min(privateBytes, allocated)
        var reclaim = Reclaim(bytes: alone)
        guard sharing.sharesAllBlocks, let id = sharing.cloneID, let count = sharing.cloneCount, count > 0 else { return reclaim }
        if count == 1 { return Reclaim(bytes: allocated) }
        reclaim.open[CloneFamily(device: device, id: id)] = CloneMembers(count: 1, total: Int(count), bytes: allocated - alone)
        return reclaim
    }

    /// The file at `path`, read now; nil when nothing is there. A folder
    /// reads as its own entry only: a tree needs a scan.
    public static func file(at path: String) -> Reclaim? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let allocated = Int64(st.st_blocks) * 512
        guard st.st_mode & S_IFMT == S_IFREG else { return Reclaim(bytes: allocated) }
        return file(allocated: allocated, device: st.st_dev, sharing: FileSpace.sharing(path))
    }

    /// The bytes that are shared, with `allocated` the space the set occupies.
    public func shared(of allocated: Int64) -> Int64 { max(0, allocated - bytes) }

    /// Adds another set, disjoint from this one. A family whose every
    /// counted member is now in the set frees its shared copy.
    public mutating func add(_ other: Reclaim) {
        bytes += other.bytes
        guard !other.open.isEmpty else { return }
        if open.isEmpty && other.open.count <= Self.openLimit {
            open = other.open
            closeComplete()
            return
        }
        for (family, members) in other.open {
            if var mine = open[family] {
                mine.count += members.count
                mine.bytes = max(mine.bytes, members.bytes)
                if mine.count >= mine.total {
                    bytes += mine.bytes
                    open[family] = nil
                } else {
                    open[family] = mine
                }
            } else if members.count >= members.total {
                bytes += members.bytes
            } else {
                open[family] = members
            }
        }
        trim()
    }

    public static func + (lhs: Reclaim, rhs: Reclaim) -> Reclaim {
        var sum = lhs
        sum.add(rhs)
        return sum
    }

    /// Takes away a set that was added, as when it is pruned from a tree.
    /// Families it closed stay counted: the result is an estimate until
    /// the place is read again.
    public mutating func subtract(_ other: Reclaim) {
        bytes = max(0, bytes - other.bytes)
    }

    private mutating func closeComplete() {
        for (family, members) in open where members.count >= members.total {
            bytes += members.bytes
            open[family] = nil
        }
    }

    private mutating func trim() {
        guard open.count > Self.openLimit else { return }
        let kept = open.sorted { $0.value.bytes > $1.value.bytes }.prefix(Self.openLimit)
        open = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }
}
