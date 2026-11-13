import Foundation
import StorageKit

/// The size of what a removal takes, as removal confirmations, notices and
/// totals show it. On APFS clones share blocks, so what a removal frees
/// (`Reclaim`) can be far less than what the items occupy; it is named
/// only when it differs noticeably.
enum Freeing {
    /// Below this difference, freeing reads as the size itself.
    static let noticeable: Int64 = 1_048_576

    /// The estimate differs from the size enough to say so.
    static func differs(_ size: Int64, frees: Int64?) -> Bool {
        guard let frees, frees < size else { return false }
        let gap = size - frees
        return gap >= noticeable && gap * 100 >= size
    }

    /// "4 GB", or "4 GB, frees about 1 GB" where clones keep most of it.
    static func phrase(_ size: Int64, frees: Int64?) -> String {
        guard differs(size, frees: frees), let frees else { return ByteSize.format(size) }
        return String(localized: "\(ByteSize.format(size)), frees about \(ByteSize.format(max(0, frees)))")
    }
}
